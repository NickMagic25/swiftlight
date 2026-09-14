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

    init() {
        settings.hdr = .off
        if let data = UserDefaults.standard.data(forKey: "mobile.defaultSettings"),
           let saved = try? JSONDecoder().decode(StreamSettings.self, from: data),
           let valid = try? saved.validated() {
            settings = valid
            settings.hdr = .off
        }
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
                model.client = newClient
                model.hostInfo = info
                model.apps = []
                model.addingComputer = false
                model.showingAddComputer = false
                try await model.loadLibrary(client: newClient, info: info, generation: generation)
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
        let valid = try draft.validated()
        let data = try JSONEncoder().encode(valid)
        UserDefaults.standard.set(data, forKey: "mobile.defaultSettings")
        settings = valid
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
                status = "Unable to connect"
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
