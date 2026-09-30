#if os(iOS)
import Combine
import Foundation
import SwiftlightCore
import SwiftlightHost


/// Main-actor host control. Retiring an operation prevents a cancelled request
/// from publishing into a new selection or after the app enters the background.
@MainActor final class MobileClientModel: ObservableObject {
    @Published private(set) var hosts: [SavedHost] = []
    @Published private(set) var selectedHostID: String?
    @Published private(set) var hostInfo: HostInfo?
    @Published private(set) var apps: [RemoteApp] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "Choose a computer"
    @Published var message: String?
    @Published var showingAddComputer = false
    @Published var showingPairing = false
    @Published private(set) var pairingPIN: String?
    @Published private(set) var settings = StreamSettings()
    @Published private(set) var statisticsPreferences = StreamStatisticsPreferences()
    @Published private(set) var showStatisticsByDefault = false
    @Published var remoteApplicationAction: RemoteApplicationAction?
    @Published private(set) var artworkLoadingAllowed = false

    let discovery = BonjourHostDiscovery()
    let artwork = AppArtworkStore()
    private(set) var client: HostClient?
    private let hostStore = SavedHostStore()
    private var controlTask: Task<Void, Never>?
    private var controlGeneration: UInt64 = 0
    private var foreground = false
    private var loaded = false
    private var addingComputer = false
    private var streaming = false

    var selectedHost: SavedHost? { hosts.first { $0.id == selectedHostID } }
    var libraryApps: [RemoteApp] { RemoteApplicationAction.library(apps: apps, host: hostInfo) }

    init() {
        settings.hdr = .off
        if let data = UserDefaults.standard.data(forKey: "mobile.defaultSettings"),
           let saved = try? JSONDecoder().decode(StreamSettings.self, from: data),
           let valid = try? saved.validated() {
            settings = valid
            // Preserve an explicit HDR choice while keeping older mobile
            // settings that predate this field on their SDR default.
            if let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any], values["hdr"] == nil {
                settings.hdr = .off
            }
        }
        if let data = UserDefaults.standard.data(forKey: "mobile.statisticsPreferences"),
           let saved = try? JSONDecoder().decode(StreamStatisticsPreferences.self, from: data) {
            statisticsPreferences = saved
        }
        showStatisticsByDefault = UserDefaults.standard.bool(forKey: "mobile.showStatisticsByDefault")
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            discovery.start()
            if !loaded {
                perform { model, generation in
                    let saved = try await model.hostStore.load()
                    guard model.isCurrent(generation) else { return }
                    model.hosts = saved
                    model.loaded = true
                }
            } else if client != nil, !showingPairing {
                refresh()
            }
        } else {
            discovery.stop()
            cancelOperation()
            showingPairing = false
            pairingPIN = nil
        }
        updateArtworkLoading()
    }

    func selectHost(id: String?) {
        guard id != selectedHostID else { return }
        cancelOperation()
        artwork.cancel(clear: true)
        selectedHostID = id
        hostInfo = nil
        apps = []
        message = nil
        guard let host = selectedHost else {
            client = nil
            status = "Choose a computer"
            return
        }
        client = HostClient(address: host.address, hostID: host.id)
        refresh()
    }

    func addComputer(_ input: String) {
        do {
            let address = try HostAddress(input)
            let newClient = HostClient(address: address)
            status = "Connecting…"
            perform(addingComputer: true) { model, generation in
                let info = try await newClient.serverInfo()
                guard model.isCurrent(generation) else { return }
                let saved = SavedHost(info: info, address: address)
                try await model.hostStore.upsert(saved)
                let hosts = try await model.hostStore.load()
                guard model.isCurrent(generation) else { return }
                model.hosts = hosts
                model.artwork.cancel(clear: true)
                model.selectedHostID = saved.id
                // Bind future control operations to the authenticated host ID,
                // including the fresh checks before any confirmed remote quit.
                let savedClient = HostClient(address: address, hostID: saved.id)
                model.client = savedClient
                model.hostInfo = info
                model.apps = []
                model.addingComputer = false
                model.showingAddComputer = false
                try await model.loadLibrary(client: savedClient, info: info, generation: generation)
            }
        } catch {
            message = Self.displayMessage(error)
        }
    }

    func refresh() {
        guard let client else { return }
        status = "Connecting…"
        perform { model, generation in
            let info = try await client.serverInfo()
            guard model.isCurrent(generation) else { return }
            model.hostInfo = info
            try await model.loadLibrary(client: client, info: info, generation: generation)
        }
    }

    func beginPairing() {
        guard let client, hostInfo?.isPaired == false, !busy else { return }
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        pairingPIN = pin
        showingPairing = true
        status = "Waiting for pairing…"
        perform { model, generation in
            let info = try await client.pair(pin: pin, clientName: "Swiftlight Mobile")
            guard model.isCurrent(generation) else { return }
            model.hostInfo = info
            model.showingPairing = false
            model.pairingPIN = nil
            try await model.loadLibrary(client: client, info: info, generation: generation)
        }
    }

    func cancelPairing() {
        guard showingPairing || pairingPIN != nil else { return }
        cancelOperation()
        showingPairing = false
        pairingPIN = nil
        status = "Pair this computer to open its library"
    }

    func saveSettings(_ draft: StreamSettings) throws {
        try saveSettings(draft, statistics: statisticsPreferences, showStatisticsByDefault: showStatisticsByDefault)
    }

    func saveSettings(_ draft: StreamSettings, statistics: StreamStatisticsPreferences,
                      showStatisticsByDefault: Bool) throws {
        let valid = try draft.validated()
        let data = try JSONEncoder().encode(valid)
        let statisticsData = try JSONEncoder().encode(statistics)
        // Validate and encode the entire draft before committing any preference.
        UserDefaults.standard.set(data, forKey: "mobile.defaultSettings")
        UserDefaults.standard.set(statisticsData, forKey: "mobile.statisticsPreferences")
        UserDefaults.standard.set(showStatisticsByDefault, forKey: "mobile.showStatisticsByDefault")
        settings = valid
        statisticsPreferences = statistics
        self.showStatisticsByDefault = showStatisticsByDefault
    }

    func prepareLaunch(_ app: RemoteApp, quitting expectedAppID: Int? = nil,
                       onPrepared: @escaping @MainActor (RemoteApp, HostClient, HostInfo) -> Void) {
        guard let client, let hostID = selectedHostID, !busy, !streaming, foreground else { return }
        status = expectedAppID == nil ? "Checking session…" : "Quitting remote application…"
        perform { model, generation in
            do {
                // HostClient authenticates fresh server info and revalidates the
                // confirmed app ID immediately before issuing a remote cancel.
                let info = try await client.prepareApplication(app.id, quitting: expectedAppID)
                guard model.isCurrent(generation), model.selectedHostID == hostID else { return }
                guard info.id == hostID else { throw HostError.identityChanged }
                model.hostInfo = info
                model.status = "Connecting stream…"
                model.busy = false
                onPrepared(app, client, info)
            } catch let conflict as RunningApplicationConflict {
                guard model.isCurrent(generation), model.selectedHostID == hostID else { return }
                guard conflict.hostInfo.id == hostID else { throw HostError.identityChanged }
                model.presentRunningApplicationConflict(conflict, nextApp: app, hostID: hostID)
            } catch where HostControlFailurePolicy.permitsQuitRefusalRefresh(error, confirmedQuit: expectedAppID != nil) {
                try await model.refreshAfterQuitRefusal(client: client, hostID: hostID, generation: generation)
            }
        }
    }

    func requestQuitRemoteApplication(_ app: RemoteApp) {
        guard !busy, !streaming, foreground, hostInfo?.isPaired == true,
              hostInfo?.currentAppID == app.id else { return }
        requestRemoteAction(runningAppID: app.id)
    }

    func confirmRemoteApplicationAction(_ action: RemoteApplicationAction,
                                        onPrepared: @escaping @MainActor (RemoteApp, HostClient, HostInfo) -> Void) {
        remoteApplicationAction = nil
        guard action.hostID == selectedHostID, action.controlGeneration == controlGeneration,
              !busy, !streaming, foreground else { return }
        if let nextApp = action.nextApp {
            prepareLaunch(nextApp, quitting: action.runningApp.id, onPrepared: onPrepared)
        } else {
            quitRemoteApplication(expectedAppID: action.runningApp.id)
        }
    }

    func presentRunningApplicationConflict(_ conflict: RunningApplicationConflict, nextApp: RemoteApp,
                                           hostID: String) {
        guard foreground, selectedHostID == hostID, conflict.hostInfo.id == hostID else { return }
        hostInfo = conflict.hostInfo
        status = "Another application is running"
        message = nil
        requestRemoteAction(runningAppID: conflict.hostInfo.currentAppID, nextApp: nextApp)
    }

    private func requestRemoteAction(runningAppID: Int, nextApp: RemoteApp? = nil) {
        guard let hostID = selectedHostID, runningAppID > 0 else { return }
        let running = apps.first { $0.id == runningAppID } ?? RemoteApp(id: runningAppID, name: "Running application")
        remoteApplicationAction = RemoteApplicationAction(hostID: hostID, controlGeneration: controlGeneration,
                                                                runningApp: running, nextApp: nextApp)
    }

    private func quitRemoteApplication(expectedAppID: Int) {
        guard let client, let hostID = selectedHostID else { return }
        status = "Quitting remote application…"
        perform { model, generation in
            do {
                try await client.quitApplication(expectedAppID: expectedAppID)
            } catch let conflict as RunningApplicationConflict {
                guard model.isCurrent(generation), model.selectedHostID == hostID else { return }
                guard conflict.hostInfo.id == hostID else { throw HostError.identityChanged }
                model.hostInfo = conflict.hostInfo
                model.status = "The running application changed"
                model.requestRemoteAction(runningAppID: conflict.hostInfo.currentAppID)
                return
            } catch where HostControlFailurePolicy.permitsQuitRefusalRefresh(error, confirmedQuit: true) {
                try await model.refreshAfterQuitRefusal(client: client, hostID: hostID, generation: generation)
                return
            }
            guard model.isCurrent(generation), model.selectedHostID == hostID else { return }
            let info = try await client.serverInfo()
            guard model.isCurrent(generation), model.selectedHostID == hostID else { return }
            guard info.id == hostID else { throw HostError.identityChanged }
            model.hostInfo = info
            try await model.loadLibrary(client: client, info: info, generation: generation)
        }
    }

    private func refreshAfterQuitRefusal(client: HostClient, hostID: String, generation: UInt64) async throws {
        guard isCurrent(generation), selectedHostID == hostID else { return }
        // /cancel can be refused while the authenticated library remains usable.
        // Verify both host trust and library access again instead of treating
        // that refusal as lost pairing. Recovery failures still reach perform's
        // clearing path; a refused quit must never continue into launch.
        let info = try await client.serverInfo()
        guard isCurrent(generation), selectedHostID == hostID else { return }
        guard info.id == hostID else { throw HostError.identityChanged }
        guard info.isPaired else { throw HostError.notPaired }
        hostInfo = info
        try await loadLibrary(client: client, info: info, generation: generation)
        guard isCurrent(generation), selectedHostID == hostID else { return }
        status = "Quit request was refused"
        message = Self.displayMessage(HostError.permissionDenied)
    }

    func setStreaming(_ active: Bool) {
        streaming = active
        updateArtworkLoading()
    }

    func loadArtwork(for app: RemoteApp) {
        guard artworkLoadingAllowed, let client, let selectedHostID else { return }
        artwork.load(apps: [app], using: client, hostID: selectedHostID)
    }

    private func updateArtworkLoading() {
        let allowed = foreground && !streaming && !busy && hostInfo?.isPaired == true && client != nil
        guard allowed != artworkLoadingAllowed else { return }
        artworkLoadingAllowed = allowed
        if allowed, let client, let selectedHostID {
            // Prime one small batch; newly visible cards request the rest.
            artwork.load(apps: Array(apps.prefix(12)), using: client, hostID: selectedHostID)
        } else {
            artwork.cancel()
        }
    }

    func dismissAddComputer() {
        if addingComputer { cancelOperation() }
        addingComputer = false
        showingAddComputer = false
        message = nil
        updateArtworkLoading()
    }

    private func loadLibrary(client: HostClient, info: HostInfo, generation: UInt64) async throws {
        guard info.isPaired else {
            apps = []
            artwork.cancel(clear: true)
            status = "Pair this computer to open its library"
            return
        }
        let library = try await client.apps()
        guard isCurrent(generation) else { return }
        apps = library.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        status = library.isEmpty ? "No applications available" : "Ready to stream"
    }

    private func perform(addingComputer isAddingComputer: Bool = false,
                         _ operation: @escaping @MainActor (MobileClientModel, UInt64) async throws -> Void) {
        cancelOperation()
        addingComputer = isAddingComputer
        let generation = controlGeneration
        busy = true
        message = nil
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(generation) {
                    busy = false
                    controlTask = nil
                    updateArtworkLoading()
                }
            }
            do { try await operation(self, generation) }
            catch {
                guard isCurrent(generation), !(error is CancellationError) else { return }
                message = Self.displayMessage(error)
                status = HostControlFailurePolicy.requiresTrustReview(error) ? "Trust needs review" : "Unable to connect"
                // Never leave artwork from a previously authenticated library
                // visible after host trust or permission validation fails.
                if !addingComputer {
                    apps = []
                    if hostInfo?.isPaired == true { hostInfo = nil }
                    artwork.cancel(clear: true)
                }
                if showingPairing {
                    pairingPIN = nil
                }
                addingComputer = false
            }
        }
    }

    private func cancelOperation() {
        controlGeneration &+= 1
        remoteApplicationAction = nil
        controlTask?.cancel()
        controlTask = nil
        busy = false
        addingComputer = false
        artworkLoadingAllowed = false
        artwork.cancel()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == controlGeneration && foreground && !Task.isCancelled
    }

    private static func displayMessage(_ error: any Error) -> String {
        if let hostError = error as? HostError { return hostError.localizedDescription }
        return "The computer could not be reached or saved. Check your network and try again."
    }
}

#endif
