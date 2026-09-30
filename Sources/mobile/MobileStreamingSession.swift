#if os(iOS)
import AVFoundation
import Combine
import Network
import SwiftlightCore
import SwiftlightHost
import SwiftlightTransport
import SwiftlightVideo
import UIKit

/// Main-actor owner for the single common-c session. Retire its generation before
/// cancellation; close admission, release inputs, join transport, then close video.
@MainActor final class MobileStreamingSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var hasVideo = false
    @Published private(set) var status = "Connecting"
    @Published var errorMessage: String?
    @Published private(set) var pipeline: StreamingPipeline?
    @Published private(set) var inputEnabled = false
    @Published private(set) var showingStatistics = false
    @Published private(set) var statisticsRows: [StreamStatisticRow] = []
    @Published private(set) var statisticsPreferences = StreamStatisticsPreferences()
    @Published private(set) var controlsVisible = false
    /// Current output capability/user preference, not a head-tracking state.
    @Published private(set) var spatialPlaybackAvailable: Bool?
    private(set) var statisticsSnapshot = StreamStatisticsSnapshot()
    private(set) var transport: StreamTransport?
    private(set) var settings = StreamSettings()
    private var state = SessionState()
    private var stoppingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var network: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var audioActive = false
    // Ephemeral route identity is used only to reject an unexpected output
    // switch. Do not persist it or include it in diagnostics.
    private var audioOutputPortIDs: Set<String> = []
    private var audioOutputChannelCount = 0
    private var display = DisplayGeometry.fallback
    private var hdrDisplay = MobileHDRDisplayCapabilities(potentialHeadroom: nil, currentHeadroom: nil,
                                                         systemToneMappingAvailable: false)
    private var sceneActive = true
    private var transportReady = false
    private var statisticsRequest: StreamRequest?
    private var statisticsSelection: CodecSelection?
    private var statisticsSampler = StreamStatisticsSampler()
    private var latencyCapture: MobileStreamDiagnostics?

    func updateDisplay(_ geometry: DisplayGeometry, _ hdr: MobileHDRDisplayCapabilities) {
        display = geometry; hdrDisplay = hdr
    }

    func start(client: HostClient, host: HostInfo, app: RemoteApp, settings: StreamSettings,
               statisticsPreferences: StreamStatisticsPreferences = .init(), showStatistics: Bool = false) async throws {
        await stoppingTask?.value
        try Task.checkCancellation()
        guard !isActive else { return }
        state.apply(.connect)
        let generation = state.generation
        latencyCapture = MobileStreamDiagnostics.makeIfEnabled(settings: settings)
        isActive = true; hasVideo = false; errorMessage = nil; status = "Connecting"; self.settings = settings
        resetStatisticsSamples()
        statisticsRequest = nil; statisticsSelection = nil
        self.statisticsPreferences = statisticsPreferences
        showingStatistics = showStatistics
        do {
            let info = try await client.serverInfo()
            try ensureCurrent(generation)
            guard info.id == host.id else { throw HostError.invalidResponse }
            guard info.currentAppID == 0 || info.currentAppID == app.id else {
                throw RunningApplicationConflict(hostInfo: info)
            }
            let preparation = try StreamConnectionPreparation(appID: app.id, settings: settings,
                display: display, host: info,
                device: .init(hevc: VideoCodec.hevc.hardwareCandidate, av1: VideoCodec.av1.hardwareCandidate,
                              hdr: hdrDisplay.supportsHDR))
            let request = preparation.request, selection = preparation.selection
            statisticsRequest = request; statisticsSelection = selection
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default)
            try audio.setSupportsMultichannelContent(settings.audioChannels != .stereo)
            try audio.setPreferredSampleRate(48_000)
            try audio.setPreferredIOBufferDuration(0.005)
            try audio.setActive(true); audioActive = true
            if settings.effectiveAudioOutput == .direct, audio.maximumOutputNumberOfChannels > 0 {
                let channels = min(settings.audioChannels.rawValue, audio.maximumOutputNumberOfChannels)
                if channels != audio.outputNumberOfChannels {
                    // This is a route preference, not a requirement. RemoteIO
                    // reads the actual output format and downmixes if necessary.
                    try? audio.setPreferredOutputNumberOfChannels(channels)
                }
            }
            audioOutputPortIDs = Set(audio.currentRoute.outputs.map(\.uid))
            audioOutputChannelCount = audio.outputNumberOfChannels
            refreshSpatialPlaybackAvailability()
            observeInterruptions(generation: generation)
            let response = try await client.launchOrResume(preparation.launchRequest)
            try ensureCurrent(generation)
            let address = await client.address
            try ensureCurrent(generation)
            let pipeline = StreamingPipeline(renderOptions: latencyCapture?.renderOptions ?? .init())
            let configuration = preparation.transportConfiguration(address: address.host,
                sessionURL: response.sessionURL, displayRefreshHz: display.refreshHz)
            let transport = try StreamTransport(configuration: configuration, callbacks: .init(
                setup: { pipeline.setup($0) }, video: { pipeline.receive($0) },
                event: { [weak self] event in
                    Task { @MainActor [weak self] in self?.handle(event, generation: generation) }
                }))
            self.transport = transport; self.pipeline = pipeline
            state.apply(.negotiated, generation: generation)
            UIApplication.shared.isIdleTimerDisabled = true
            monitor(generation: generation)
            try await transport.start()
            try ensureCurrent(generation)
            transportReady = true; updateInputAdmission()
        } catch {
            guard state.generation == generation else { throw CancellationError() }
            if !(error is CancellationError), !(error is RunningApplicationConflict) { errorMessage = error.localizedDescription }
            await disconnect()
            throw error
        }
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard state.generation == generation, isActive else { throw CancellationError() }
    }
    func releaseInputs() { transport?.releaseAllInputs() }
    func setSceneActive(_ active: Bool) { sceneActive = active; updateInputAdmission() }
    func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible && isActive && sceneActive
        updateInputAdmission()
    }
    func toggleStatistics() { setStatisticsVisible(!showingStatistics) }
    func setStatisticsVisible(_ visible: Bool) {
        let visible = visible && isActive
        guard visible != showingStatistics else { return }
        showingStatistics = visible
        // A fresh measured window after showing avoids carrying an old RTT/FPS
        // or held Simple sample across a period with no statistics polling.
        resetStatisticsSamples()
    }
    func setStatisticsPreferences(_ preferences: StreamStatisticsPreferences) {
        guard preferences != statisticsPreferences else { return }
        statisticsPreferences = preferences
        statisticsSampler.resetPresentationSample()
    }
    private func resetStatisticsSamples() {
        statisticsSampler = StreamStatisticsSampler()
        statisticsSnapshot = StreamStatisticsSnapshot()
        if !statisticsRows.isEmpty { statisticsRows = [] }
    }
    private func updateInputAdmission() {
        let enabled = sceneActive && !controlsVisible && isActive && transportReady && hasVideo
        guard enabled != inputEnabled else { return }
        inputEnabled = enabled
        transport?.releaseAllInputs()
        if enabled, let transport { ControllerHub.shared.start(transport: transport) }
        else { ControllerHub.shared.stop() }
    }
    func disconnect() async {
        if let stoppingTask { await stoppingTask.value; return }
        let capture = latencyCapture
        capture?.finish(pipeline: pipeline, transport: transport, request: statisticsRequest,
                        stream: statisticsSnapshot, statisticsOverlayVisible: showingStatistics,
                        controlsVisible: controlsVisible, inputEnabled: inputEnabled,
                        phase: state.phase.rawValue, statisticsPreferences: statisticsPreferences)
        latencyCapture = nil
        state.apply(.disconnect)
        isActive = false
        setStatisticsVisible(false)
        hasVideo = false
        transportReady = false; controlsVisible = false; updateInputAdmission()
        let pipeline = self.pipeline, transport = self.transport
        pipeline?.closeAdmission(); pipeline?.setFrameAvailableHandler(nil)
        transport?.releaseAllInputs(); transport?.cancelStart(); ControllerHub.shared.stop()
        monitorTask?.cancel(); monitorTask = nil; network?.cancel(); network = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        spatialPlaybackAvailable = nil
        audioOutputPortIDs = []; audioOutputChannelCount = 0
        self.pipeline = nil; self.transport = nil
        UIApplication.shared.isIdleTimerDisabled = false
        let task = Task {
            await transport?.stop()
            await Task.detached(priority: .userInitiated) { pipeline?.close() }.value
            if audioActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); audioActive = false }
            state.apply(.stopped)
            await capture?.waitForWrites()
            stoppingTask = nil
        }
        stoppingTask = task
        await task.value
    }
    private func fail(_ message: String, generation: UInt64) {
        guard state.generation == generation, isActive else { return }
        errorMessage = message
        Task {
            guard state.generation == generation, isActive else { return }
            await disconnect()
        }
    }
    private func handle(_ event: TransportEvent, generation: UInt64) {
        guard state.generation == generation, isActive else { return }
        switch event {
        case .started: status = "Waiting for video"
        case .stage: status = "Connecting"
        case .terminated(let code): fail("The host disconnected (\(code)).", generation: generation)
        case .failed(_, let code): fail("The streaming connection failed (\(code)).", generation: generation)
        case .audioFailure: fail("Audio output was interrupted. Reconnect to resume.", generation: generation)
        case .rumble(let index, let low, let high): ControllerHub.shared.rumble(index: Int(index), low: low, high: high)
        default: break
        }
    }
    private func observeInterruptions(generation: UInt64) {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification,
                     AVAudioSession.routeChangeNotification, AVAudioSession.spatialPlaybackCapabilitiesChangedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.interruptionNotification,
                   let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   raw != AVAudioSession.InterruptionType.began.rawValue { return }
                let routeReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let spatialEnabled = note.userInfo?[AVAudioSessionSpatialAudioEnabledKey] as? Bool
                Task { @MainActor [weak self] in
                    guard let self, self.state.generation == generation, self.isActive, self.audioActive else { return }
                    if name == AVAudioSession.spatialPlaybackCapabilitiesChangedNotification {
                        self.refreshSpatialPlaybackAvailability()
                        if let spatialEnabled { self.spatialPlaybackAvailable = spatialEnabled }
                    } else if name == AVAudioSession.routeChangeNotification {
                        self.audioRouteChanged(reason: routeReason, generation: generation)
                    } else {
                        self.fail("Audio output was interrupted. Reconnect to resume streaming.", generation: generation)
                    }
                }
            })
        }
    }
    private func refreshSpatialPlaybackAvailability() {
        guard audioActive else { spatialPlaybackAvailable = nil; return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        spatialPlaybackAvailable = outputs.isEmpty ? nil : outputs.contains { $0.isSpatialAudioEnabled }
    }
    private func audioRouteChanged(reason rawReason: UInt?, generation: UInt64) {
        let audio = AVAudioSession.sharedInstance()
        let outputs = Set(audio.currentRoute.outputs.map(\.uid))
        let sameOutput = !outputs.isEmpty && outputs == audioOutputPortIDs
        let sameChannelCount = audio.outputNumberOfChannels == audioOutputChannelCount
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        refreshSpatialPlaybackAvailability()
        if sameOutput, audio.category == .playback,
           reason == .categoryChange || reason == .routeConfigurationChange,
           sameChannelCount || settings.effectiveAudioOutput == .systemSpatial {
            // Our category/channel preferences and system spatial preference
            // changes can notify without replacing the output. The system
            // renderer handles its own configuration/flush notifications.
            // Direct must reconnect if its actual hardware channel count changes.
            audioOutputChannelCount = audio.outputNumberOfChannels
            return
        }
        // Explicit device/route loss must not redirect buffered game audio to a
        // new output unexpectedly. The user reconnects after a real route change.
        fail("The audio route changed. Reconnect to resume streaming.", generation: generation)
    }
    private func monitor(generation: UInt64) {
        let network = NWPathMonitor(); self.network = network
        network.pathUpdateHandler = { [weak self] path in
            guard path.status == .unsatisfied else { return }
            Task { @MainActor [weak self] in self?.fail("The network connection was lost. Reconnect when the host is reachable.", generation: generation) }
        }
        network.start(queue: DispatchQueue(label: "net.edrisil.swiftlight.mobile.network"))
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.state.generation == generation, self.isActive else { return }
                if self.pipeline?.error != nil { self.fail("The video stream could not be decoded or displayed. Check the host's HEVC or AV1 encoder.", generation: generation); return }
                if self.pipeline?.decodedFormat != nil, !self.hasVideo {
                    self.state.apply(.firstFrame, generation: generation); self.hasVideo = true; self.status = "Streaming"
                    self.updateInputAdmission()
                }
                if self.showingStatistics { self.refreshStatistics() }
                self.latencyCapture?.recordIfDue(pipeline: self.pipeline, transport: self.transport,
                    request: self.statisticsRequest, stream: self.statisticsSnapshot,
                    statisticsOverlayVisible: self.showingStatistics, controlsVisible: self.controlsVisible,
                    inputEnabled: self.inputEnabled, statisticsPreferences: self.statisticsPreferences)
            }
        }
    }

    /// The existing 250 ms monitor is the only statistics sampler. Hiding the
    /// panel stops this feature's snapshots/publication; native timing counters
    /// keep their existing bounded lifetime independently of panel visibility.
    private func refreshStatistics() {
        guard showingStatistics, let pipeline, let transport else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = statisticsSampler.sample(request: statisticsRequest, selection: statisticsSelection,
            negotiated: pipeline.streamDescription, decodedFormat: pipeline.decodedFormat,
            diagnostics: transport.diagnostics, decoder: pipeline.statistics, renderer: pipeline.renderStatistics,
            uptime: now)
        statisticsSnapshot = snapshot
        let rows = statisticsSampler.rows(for: snapshot, detail: statisticsPreferences.detail, uptime: now)
        if rows != statisticsRows { statisticsRows = rows }
    }

}

#endif
