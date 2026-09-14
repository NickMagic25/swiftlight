import AVFoundation
import Combine
import Network
import Security
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
    private(set) var transport: StreamTransport?
    private(set) var settings = StreamSettings()
    private var state = SessionState()
    private var stoppingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var network: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var audioActive = false
    private var display = DisplayGeometry.fallback
    private var sceneActive = true
    private var controlsVisible = false
    private var transportReady = false

    func updateDisplay(_ geometry: DisplayGeometry) { display = geometry }

    func start(client: HostClient, host: HostInfo, app: RemoteApp, settings: StreamSettings) async throws {
        await stoppingTask?.value
        try Task.checkCancellation()
        guard !isActive else { return }
        state.apply(.connect)
        let generation = state.generation
        isActive = true; hasVideo = false; errorMessage = nil; status = "Connecting"; self.settings = settings
        do {
            let info = try await client.serverInfo()
            try ensureCurrent(generation)
            guard info.id == host.id else { throw HostError.invalidResponse }
            guard info.currentAppID == 0 || info.currentAppID == app.id else {
                throw RunningApplicationConflict(hostInfo: info)
            }
            let request = try settings.request(display: display)
            // The mobile MVP uses the validated SDR linear output. Explicit HDR
            // requests fail through shared negotiation until device HDR acceptance.
            let selection = try CodecSelection.negotiate(preference: settings.codec, hdr: settings.hdr,
                host: .init(hevc: info.supportsHEVC, av1: info.supportsAV1, hdr: false),
                device: .init(hevc: VideoCodec.hevc.hardwareCandidate, av1: VideoCodec.av1.hardwareCandidate, hdr: false))
            var key = Data(count: 16)
            guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
                throw HostError.cryptoFailure
            }
            let keyID = UInt32.random(in: 0...UInt32.max)
            var launch = try StreamLaunchRequest(appID: app.id, width: request.size.width, height: request.size.height,
                fps: request.fps, inputKey: key, inputKeyID: keyID)
            launch.playAudioOnHost = settings.playAudioOnHost
            launch.controllerMask = info.permissions.map { $0 & 0x100 != 0 ? 1 : 0 } ?? 1
            launch.surroundAudioInfo = StreamTransport.surroundAudioInfo(for: settings.audioChannels)
            let query = StreamTransport.launchQueryParameters.trimmingCharacters(in: CharacterSet(charactersIn: "&?"))
            if !query.isEmpty {
                guard let items = URLComponents(string: "http://localhost/?" + query)?.queryItems else { throw HostError.invalidResponse }
                launch.additionalQuery = items
            }
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default)
            try audio.setPreferredSampleRate(48_000)
            try audio.setPreferredIOBufferDuration(0.005)
            try audio.setActive(true); audioActive = true
            observeInterruptions(generation: generation)
            let response = try await client.launchOrResume(launch)
            try ensureCurrent(generation)
            let address = await client.address
            try ensureCurrent(generation)
            let pipeline = StreamingPipeline()
            let configuration = TransportConfiguration(address: address.host, appVersion: info.appVersion,
                gfeVersion: info.gfeVersion, rtspURL: response.sessionURL, serverCodecSupport: info.codecSupport,
                width: request.size.width, height: request.size.height, fps: request.fps, bitrateKbps: request.bitrateKbps,
                supportedVideoFormats: selection.codec == .av1 ? 0x1000 : 0x100,
                inputKey: key, inputKeyID: keyID, permissions: info.permissions, displayRefreshHz: display.refreshHz,
                audioChannels: settings.audioChannels, audioOutput: settings.effectiveAudioOutput)
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
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
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
    func setControlsVisible(_ visible: Bool) { controlsVisible = visible; updateInputAdmission() }
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
        state.apply(.disconnect)
        isActive = false
        hasVideo = false
        transportReady = false; controlsVisible = false; updateInputAdmission()
        let pipeline = self.pipeline, transport = self.transport
        pipeline?.closeAdmission(); pipeline?.setFrameAvailableHandler(nil)
        transport?.releaseAllInputs(); transport?.cancelStart(); ControllerHub.shared.stop()
        monitorTask?.cancel(); monitorTask = nil; network?.cancel(); network = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        self.pipeline = nil; self.transport = nil
        UIApplication.shared.isIdleTimerDisabled = false
        let task = Task {
            await transport?.stop()
            await Task.detached(priority: .userInitiated) { pipeline?.close() }.value
            if audioActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); audioActive = false }
            state.apply(.stopped); stoppingTask = nil
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
                     AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Route loss must not leave buffered game audio playing through a
                // new output unexpectedly. Reconnect explicitly after any change.
                if name == AVAudioSession.interruptionNotification,
                   let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   raw != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor [weak self] in self?.fail("The audio route changed. Reconnect to resume streaming.", generation: generation) }
            })
        }
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
            }
        }
    }
}
