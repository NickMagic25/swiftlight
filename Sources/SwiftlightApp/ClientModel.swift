import AppKit
import Combine
import Security
import SwiftlightCore
import SwiftlightHost
import SwiftlightTransport
import SwiftlightVideo

@MainActor final class ClientModel: ObservableObject {
    @Published var hosts: [SavedHost] = []
    @Published var selectedHostID: String?
    @Published var hostInfo: HostInfo?
    @Published var hostStatus = "Choose a computer"
    @Published var apps: [RemoteApp] = []
    @Published var settings = StreamSettings()
    @Published var state = SessionState()
    @Published var busy = false
    @Published var message: String?
    @Published var pairingPIN: String?
    @Published var showingPairing = false
    @Published var activeApp: RemoteApp?
    @Published var streamDetail = ""
    @Published var decodedDetail = "Waiting for decoded output"
    @Published var diagnosticDetail = ""
    @Published var powerDetail = ""
    @Published var display = DisplayGeometry.fallback
    @Published var hdrHeadroom: Double = 1
    @Published var hardwareDetail = ""
    @Published var pipeline: StreamingPipeline?
    @Published var transport: StreamTransport?
    @Published var renderFailure: String?
    @Published var inputCaptured = false
    let discovery = BonjourHostDiscovery()
    let network = NetworkStatus()
    let streamWindow = StreamWindowController()
    private let hostStore = SavedHostStore()
    private var client: HostClient?
    private var controlTask: Task<Void, Never>?
    private var controlGeneration: UInt64 = 0
    private var connectionTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var timer: AnyCancellable?
    private var observers: [AnyCancellable] = []
    private var activity: NSObjectProtocol?
    private var profileHostID: String?
    private var suspendedApp: RemoteApp?
    private var suspendedHostID: String?
    private var intentGate = SessionIntentGate()
    private var quittingRemote = false
    var selectedHost: SavedHost? { hosts.first { $0.id == selectedHostID } }
    var isSessionActive: Bool { [.connecting, .negotiating, .streaming, .reconfiguring, .disconnecting].contains(state.phase) }
    init() {
        if let data = UserDefaults.standard.data(forKey: "defaultSettings"), let saved = try? JSONDecoder().decode(StreamSettings.self, from: data) { settings = saved }
        hardwareDetail = "Hardware candidates: HEVC \(VideoCodec.hevc.hardwareCandidate ? "available" : "unavailable"), AV1 \(VideoCodec.av1.hardwareCandidate ? "available" : "unavailable")"
        timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.updateStatistics() }
        network.$available.dropFirst().sink { [weak self] available in
            guard !available, let self, self.isSessionActive else { return }
            self.state.apply(.pathLost); self.message = self.state.error; self.teardown()
        }.store(in: &observers)
        // NSWorkspace notifications are emitted by its own notification center.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.message = "Mac woke from sleep. Choose Resume when your host is ready." }
        }.store(in: &observers)
        Task {
            do { hosts = try await hostStore.load() }
            catch { message = "Saved computers could not be loaded: \(error.localizedDescription)" }
        }
        discovery.start()
    }
    func saveSettings(asDefault: Bool = false) {
        do {
            let valid = try settings.validated(); let data = try JSONEncoder().encode(valid)
            if asDefault || selectedHostID == nil { UserDefaults.standard.set(data, forKey: "defaultSettings") }
            if let selectedHostID { UserDefaults.standard.set(data, forKey: "profile." + selectedHostID) }
            if state.phase == .streaming { message = "Settings saved. Reconnect to apply the new stream request." }
        } catch { message = error.localizedDescription }
    }
    func selectHost(_ host: SavedHost) {
        guard !isSessionActive, !quittingRemote, !busy else { return }
        intentGate.retire()
        selectedHostID = host.id; apps = []; hostInfo = nil; pairingPIN = nil
        client = HostClient(address: host.address, hostID: host.id)
        loadProfile(host.id)
        refreshHost()
    }
    private func loadProfile(_ hostID: String) {
        if profileHostID != hostID {
            profileHostID = hostID
            let data = UserDefaults.standard.data(forKey: "profile." + hostID) ?? UserDefaults.standard.data(forKey: "defaultSettings")
            settings = data.flatMap { try? JSONDecoder().decode(StreamSettings.self, from: $0) } ?? StreamSettings()
        }
    }
    private func beginControl() -> UInt64 {
        controlTask?.cancel(); controlGeneration &+= 1; busy = true
        return controlGeneration
    }
    private func finishControl(_ generation: UInt64) {
        guard generation == controlGeneration else { return }
        busy = false; pairingPIN = nil; controlTask = nil
    }
    private func ensureControl(_ generation: UInt64, selection: String? = nil) throws {
        try Task.checkCancellation()
        guard generation == controlGeneration, selection == nil || selection == selectedHostID else { throw CancellationError() }
    }
    private func applyHostInfo(_ info: HostInfo) {
        hostInfo = info
        hostStatus = info.isPaired ? (info.isStreaming ? "Paired · App running" : "Paired") : "Ready to pair"
    }
    private func controlFailed(_ error: Error, generation: UInt64) {
        guard generation == controlGeneration, !Task.isCancelled else { return }
        message = error.localizedDescription
        switch error {
        case HostError.connectionFailed, HostError.networkFailure, HostError.timeout:
            hostStatus = "Offline"; hostInfo = nil; apps = []
        case HostError.certificateChanged, HostError.identityChanged:
            hostStatus = "Trust needs review"; hostInfo = nil; apps = []
        case HostError.permissionDenied:
            hostStatus = hostInfo?.isPaired == true ? "Paired · Permission required" : "Permission required"; apps = []
        default:
            hostStatus = hostInfo?.isPaired == true ? "Paired" : "Ready to pair"
        }
    }
    func addHost(address rawAddress: String) {
        guard !isSessionActive, !quittingRemote else { return }
        intentGate.retire()
        let generation = beginControl(); hostStatus = "Checking address…"
        controlTask = Task {
            defer { finishControl(generation) }
            do {
                let address = try HostAddress(rawAddress)
                let hostClient = HostClient(address: address)
                let info = try await hostClient.serverInfo(); try ensureControl(generation)
                let saved = SavedHost(info: info, address: address)
                try await hostStore.upsert(saved); try ensureControl(generation)
                let savedHosts = try await hostStore.load(); try ensureControl(generation)
                hosts = savedHosts; selectedHostID = saved.id; client = hostClient; apps = []
                loadProfile(saved.id); applyHostInfo(info)
                if info.isPaired { try await loadApps(using: hostClient, selection: saved.id, generation: generation) }
                else { showingPairing = true }
            } catch is CancellationError {} catch { controlFailed(error, generation: generation) }
        }
    }
    func refreshHost() {
        guard let client, let selection = selectedHostID, !isSessionActive, !busy else { return }
        let generation = beginControl(); hostStatus = "Checking…"
        controlTask = Task {
            defer { finishControl(generation) }
            do {
                let info = try await client.serverInfo(); try ensureControl(generation, selection: selection)
                applyHostInfo(info)
                if info.isPaired { try await loadApps(using: client, selection: selection, generation: generation) }
                else { apps = [] }
            } catch is CancellationError {} catch { controlFailed(error, generation: generation) }
        }
    }
    private func loadApps(using client: HostClient, selection: String, generation: UInt64) async throws {
        let loadedApps = try await client.apps()
        try ensureControl(generation, selection: selection)
        apps = loadedApps; state.apply(.ready)
    }
    func beginPINPairing() {
        guard let client, let selection = selectedHostID, !busy, !isSessionActive else { return }
        let generation = beginControl(); hostStatus = "Pairing…"
        let pin = String(format: "%04d", Int.random(in: 0...9999)); pairingPIN = pin
        controlTask = Task {
            defer { finishControl(generation) }
            do {
                let info = try await client.pair(pin: pin); try ensureControl(generation, selection: selection)
                applyHostInfo(info); pairingPIN = nil; showingPairing = false
                try await loadApps(using: client, selection: selection, generation: generation)
            } catch is CancellationError {
                if generation == controlGeneration { hostStatus = "Pairing canceled" }
            } catch { controlFailed(error, generation: generation) }
        }
    }
    func pairApollo(link: String) {
        do { pairApollo(credential: try ApolloPairingCredential(link: link)) }
        catch { message = error.localizedDescription }
    }
    func pairApollo(credential: ApolloPairingCredential) {
        guard !busy, !isSessionActive else { return }
        let generation = beginControl(); hostStatus = "Pairing…"
        controlTask = Task {
            defer { finishControl(generation) }
            do {
                let hostClient = HostClient(address: credential.address)
                let info = try await hostClient.pair(credential: credential)
                try ensureControl(generation)
                let saved = SavedHost(info: info, address: credential.address)
                try await hostStore.upsert(saved); try ensureControl(generation)
                let savedHosts = try await hostStore.load(); try ensureControl(generation)
                hosts = savedHosts; selectedHostID = saved.id; client = hostClient; apps = []
                loadProfile(saved.id); applyHostInfo(info); showingPairing = false
                try await loadApps(using: hostClient, selection: saved.id, generation: generation)
            } catch is CancellationError {
                if generation == controlGeneration { hostStatus = "Pairing canceled" }
            } catch { controlFailed(error, generation: generation) }
        }
    }
    func cancelPairing() {
        controlTask?.cancel(); pairingPIN = nil; showingPairing = false
        if busy { hostStatus = "Canceling pairing…" }
    }
    func removeHost() {
        guard let host = selectedHost, !isSessionActive, !busy else { return }
        intentGate.retire()
        let hostClient = client ?? HostClient(address: host.address, hostID: host.id)
        let generation = beginControl()
        controlTask = Task {
            defer { finishControl(generation) }
            do {
                try await hostClient.forgetPairing(); try ensureControl(generation, selection: host.id)
                try await hostStore.remove(id: host.id); try ensureControl(generation, selection: host.id)
                let savedHosts = try await hostStore.load(); try ensureControl(generation, selection: host.id)
                hosts = savedHosts; selectedHostID = nil; hostInfo = nil; apps = []; client = nil; hostStatus = "Choose a computer"
            } catch is CancellationError {} catch { controlFailed(error, generation: generation) }
        }
    }
    func unpair() {
        guard let client, let selection = selectedHostID, !isSessionActive, !busy else { return }
        let generation = beginControl(); hostStatus = "Removing pairing…"
        controlTask = Task {
            defer { finishControl(generation) }
            do {
                try await client.unpair(); try ensureControl(generation, selection: selection)
                apps = []; hostInfo = nil; hostStatus = "Ready to pair"; showingPairing = true
                let info = try await client.serverInfo(); try ensureControl(generation, selection: selection); applyHostInfo(info)
            } catch is CancellationError {} catch { controlFailed(error, generation: generation) }
        }
    }
    func launch(_ app: RemoteApp) {
        guard let client, let host = selectedHost, !isSessionActive, !busy, !quittingRemote, stoppingTask == nil else { return }
        state.apply(.connect); let generation = state.generation
        activeApp = app; message = nil; renderFailure = nil; hostStatus = "Connecting stream…"
        connectionTask = Task {
            do {
                let launchDisplay = try await streamWindow.prepare(settings: settings)
                try ensureCurrent(generation)
                display = launchDisplay.0; hdrHeadroom = launchDisplay.1
                let info = try await client.serverInfo(); try ensureCurrent(generation)
                if info.currentAppID > 0 && info.currentAppID != app.id {
                    throw SettingsError.invalid("Another application is running on this host. Resume it or explicitly quit it before launching \(app.name).")
                }
                let request = try settings.request(display: display)
                let hostHDR = info.codecSupport & (settings.codec == .av1 ? 0x20000 : settings.codec == .hevc ? 0x200 : 0x20200) != 0
                let selection = try CodecSelection.negotiate(preference: settings.codec, hdr: settings.hdr,
                    host: .init(hevc: info.supportsHEVC, av1: info.supportsAV1, hdr: hostHDR,
                        hevcHDR: info.codecSupport & 0x200 != 0, av1HDR: info.codecSupport & 0x20000 != 0),
                    device: .init(hevc: VideoCodec.hevc.hardwareCandidate, av1: VideoCodec.av1.hardwareCandidate, hdr: hdrHeadroom > 1))
                let exactHDRSupported = info.codecSupport & (selection.codec == .av1 ? 0x20000 : 0x200) != 0
                guard !selection.hdr || exactHDRSupported else { throw SettingsError.invalid("Selected codec does not support HDR on this host. Choose another codec or disable HDR.") }
                var inputKey = Data(count: 16)
                let keyStatus = inputKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
                guard keyStatus == errSecSuccess else { throw HostError.cryptoFailure }
                let keyID = UInt32.random(in: 0...UInt32.max)
                var launchRequest = try StreamLaunchRequest(appID: app.id, width: request.size.width, height: request.size.height,
                    fps: request.fps, inputKey: inputKey, inputKeyID: keyID)
                launchRequest.hdr = selection.hdr
                launchRequest.controllerMask = info.permissions.map { $0 & 0x100 != 0 ? 1 : 0 } ?? 1
                let extensionQuery = StreamTransport.launchQueryParameters.trimmingCharacters(in: CharacterSet(charactersIn: "&?"))
                if !extensionQuery.isEmpty {
                    guard let queryItems = URLComponents(string: "http://localhost/?" + extensionQuery)?.queryItems else { throw HostError.invalidResponse }
                    launchRequest.additionalQuery = queryItems
                }
                let launchResponse = info.currentAppID == app.id ? try await client.resume(launchRequest) : try await client.launch(launchRequest)
                try ensureCurrent(generation)
                let pipeline = StreamingPipeline()
                let formats: UInt32 = selection.codec == .av1 ? (selection.hdr ? 0x2000 : 0x1000) : (selection.hdr ? 0x200 : 0x100)
                let config = TransportConfiguration(address: host.address.host, appVersion: info.appVersion, gfeVersion: info.gfeVersion,
                    rtspURL: launchResponse.sessionURL, serverCodecSupport: info.codecSupport, width: request.size.width,
                    height: request.size.height, fps: request.fps, bitrateKbps: request.bitrateKbps, supportedVideoFormats: formats,
                    inputKey: inputKey, inputKeyID: keyID, hdr: selection.hdr, permissions: info.permissions, displayRefreshHz: display.refreshHz)
                let transport = try StreamTransport(configuration: config, callbacks: .init(setup: { pipeline.setup($0) }, video: { pipeline.receive($0) },
                    event: { [weak self] event in Task { @MainActor [weak self] in self?.handle(event, generation: generation) } }))
                self.pipeline = pipeline; self.transport = transport
                streamDetail = "Requested \(request.size.width) × \(request.size.height) · \(request.fps) FPS · \(Double(request.bitrateKbps) / 1000) Mbps · \(selection.codec.rawValue.uppercased()) \(selection.hdr ? "HDR10" : "SDR")"
                state.apply(.negotiated, generation: generation)
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "Streaming a game")
                try await transport.start(); try ensureCurrent(generation)
            } catch is CancellationError {} catch {
                guard state.generation == generation else { return }
                state.apply(.failure(error.localizedDescription), generation: generation); message = error.localizedDescription; teardown()
            }
        }
    }
    private func ensureCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation(); guard state.generation == generation else { throw CancellationError() }
    }
    private func handle(_ event: TransportEvent, generation: UInt64) {
        guard generation == state.generation else { return }
        switch event {
        case .terminated(let code): state.apply(.failure("Host disconnected (\(code)).")); message = state.error; teardown()
        case .failed(let stage, let code): state.apply(.failure("Connection failed at \(stage) (\(code)).")); message = state.error; teardown()
        case .rumble(let controller, let low, let high): ControllerHub.shared.rumble(index: Int(controller), low: low, high: high)
        case .audioFailure(let code): message = "Audio output failed (\(code)). Check the selected output device."
        case .qualityPoor(let poor): if poor { message = "Network quality is poor. Try a lower bitrate." }
        default: break
        }
    }
    func disconnect() { intentGate.retire(); state.apply(.disconnect); teardown() }
    private func teardown() {
        guard stoppingTask == nil else { return }
        connectionTask?.cancel(); transport?.releaseAllInputs(); transport?.cancelStart()
        let oldTransport = transport, oldPipeline = pipeline
        oldPipeline?.closeAdmission(); transport = nil; pipeline = nil; inputCaptured = false
        streamWindow.endSession()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        stoppingTask = Task {
            await oldTransport?.stop()
            await Task.detached { oldPipeline?.close() }.value
            state.apply(.stopped); stoppingTask = nil
            if let hostInfo { applyHostInfo(hostInfo) }
        }
    }
    func reconnect() {
        guard let app = activeApp, let hostID = selectedHostID else { return }
        disconnect(); let ticket = intentGate.issue(hostID: hostID)
        Task {
            await stoppingTask?.value
            guard intentGate.accepts(ticket, selectedHostID: selectedHostID) else { return }
            launch(app)
        }
    }
    func suspend() {
        guard isSessionActive else { return }
        intentGate.retire(); suspendedApp = activeApp; suspendedHostID = selectedHostID
        state.apply(.suspend); teardown()
    }
    func resumeSuspended() {
        guard let app = suspendedApp, let hostID = suspendedHostID, hostID == selectedHostID else { return }
        let ticket = intentGate.issue(hostID: hostID)
        Task {
            await stoppingTask?.value
            guard intentGate.accepts(ticket, selectedHostID: selectedHostID) else { return }
            state.apply(.disconnect); state.apply(.stopped); launch(app)
        }
    }
    func quitRemoteApplication() {
        guard let client, let hostID = selectedHostID, !busy, !quittingRemote else { return }
        quittingRemote = true; disconnect(); let generation = beginControl()
        controlTask = Task {
            defer { quittingRemote = false; finishControl(generation) }
            await stoppingTask?.value
            do {
                try ensureControl(generation, selection: hostID)
                try await client.quitApplication()
                let info = try await client.serverInfo(); try ensureControl(generation, selection: hostID)
                applyHostInfo(info)
                if info.isPaired { try await loadApps(using: client, selection: hostID, generation: generation) }
            } catch is CancellationError {} catch { controlFailed(error, generation: generation) }
        }
    }
    func shutdown() async {
        controlTask?.cancel(); disconnect()
        await stoppingTask?.value
        await controlTask?.value
        discovery.stop()
    }
    private func updateStatistics() {
        if let error = pipeline?.error ?? pipeline?.statistics?.failureDescription ?? renderFailure, isSessionActive {
            message = error; state.apply(.failure(error)); teardown(); return
        }
        if let pipeline {
            let decoded = pipeline.decodedDetail
            if decodedDetail != decoded { decodedDetail = decoded }
            if state.phase == .negotiating, let stats = pipeline.statistics, stats.output > 0 {
                state.apply(.firstFrame); hostStatus = "Streaming"
            }
            if let diagnostics = transport?.diagnostics {
                let detail = "RTT \(diagnostics.rttMilliseconds.map(String.init) ?? "unavailable") ms · audio queue \(diagnostics.pendingAudioMilliseconds) ms · route \(diagnostics.interfaceName.isEmpty ? "unknown" : diagnostics.interfaceName)"
                if diagnosticDetail != detail { diagnosticDetail = detail }
            }
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "Normal temperature"; case .fair: thermal = "Warm"; case .serious: thermal = "High temperature"; case .critical: thermal = "Critical temperature"; @unknown default: thermal = "Unknown temperature" }
        let detail = thermal + (ProcessInfo.processInfo.isLowPowerModeEnabled ? " · Low Power Mode" : "")
        if powerDetail != detail { powerDetail = detail }
    }
}
