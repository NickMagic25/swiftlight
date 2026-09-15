#if os(iOS)
import SwiftUI
import SwiftlightHost

struct MobileContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: MobileClientModel
    @ObservedObject var session: MobileStreamingSession
    @State private var showingSettings = false
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var launchTask: Task<Void, Never>?
    @State private var launchGeneration: UInt64 = 0
    @State private var launchMessage: String?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            MobileComputerList(model: model)
                .navigationTitle("Computers")
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                            .accessibilityIdentifier("streamSettings")
                    }
                }
        } detail: {
            library
                .navigationTitle(model.selectedHost?.name ?? "Swiftlight")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.selectedHost != nil {
                            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                                .disabled(model.busy || session.isActive)
                        }
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                }
        }
        .background(MobileDisplayProbe(onChange: session.updateDisplay).allowsHitTesting(false).accessibilityHidden(true))
        .sheet(isPresented: $model.showingAddComputer, onDismiss: model.dismissAddComputer) {
            MobileAddComputerView(model: model)
                .presentationSizing(.form)
        }
        .sheet(isPresented: $model.showingPairing, onDismiss: model.cancelPairing) {
            MobilePairingView(model: model)
                .presentationSizing(.form)
        }
        .sheet(isPresented: $showingSettings) {
            MobileSettingsView(model: model)
                .presentationSizing(.form)
        }
        .fullScreenCover(isPresented: Binding(
            get: { session.isActive },
            set: { if !$0 { Task { await session.disconnect() } } }
        )) {
            MobileStreamScreen(session: session)
                .interactiveDismissDisabled()
        }
        .alert("Unable to continue", isPresented: Binding(
            get: { launchMessage != nil || (model.message != nil && !model.showingAddComputer && !model.showingPairing) },
            set: { if !$0 { launchMessage = nil; model.message = nil } }
        )) {
            Button("OK", role: .cancel) { launchMessage = nil; model.message = nil }
        } message: {
            Text(launchMessage ?? model.message ?? "")
        }
        .confirmationDialog(model.remoteApplicationAction?.title ?? "Quit Remote Application?",
                            isPresented: Binding(
                                get: { model.remoteApplicationAction != nil },
                                set: { if !$0 { model.remoteApplicationAction = nil } }),
                            titleVisibility: .visible, presenting: model.remoteApplicationAction) { action in
            Button(action.nextApp == nil ? "Quit Remote Application" : "Quit and Start", role: .destructive) {
                Task {
                    // A dismissed stream can still be joining its transport.
                    // Finish that local teardown before a confirmed host quit.
                    await session.disconnect()
                    model.confirmRemoteApplicationAction(action, onPrepared: startPrepared)
                }
            }
            Button("Cancel", role: .cancel) { model.remoteApplicationAction = nil }
        } message: { action in
            Text(action.message)
        }
        .task { model.setForeground(scenePhase == .active) }
        .onChange(of: model.selectedHostID) { _, selection in
            cancelLaunch()
            if selection != nil { preferredCompactColumn = .detail }
        }
        .onChange(of: session.isActive) { wasActive, isActive in
            model.setStreaming(isActive)
            if wasActive, !isActive, let error = session.errorMessage { launchMessage = error }
            if wasActive, !isActive, scenePhase == .active, launchTask == nil,
               session.errorMessage == nil, model.remoteApplicationAction == nil {
                // Disconnect is local; refresh to show the host app still running.
                model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.setSceneActive(true)
                model.setForeground(true)
            } else if phase == .background {
                session.setSceneActive(false)
                cancelLaunch()
                model.setForeground(false)
                Task { await session.disconnect() }
            } else {
                session.setSceneActive(false)
            }
        }
    }

    @ViewBuilder private var library: some View {
        if model.selectedHost == nil {
            ContentUnavailableView {
                Label("Your games, wherever you play", systemImage: "gamecontroller")
            } description: {
                Text("Choose a computer on your local network or add its address to get started.")
            } actions: {
                Button("Add Host") { model.showingAddComputer = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if model.busy && model.apps.isEmpty {
            ProgressView(model.status)
                .padding()
        } else if model.hostInfo?.isPaired == false {
            ContentUnavailableView {
                Label("Pair Your Computer", systemImage: "lock.shield")
            } description: {
                Text("Pair with \(model.selectedHost?.name ?? "your computer") to securely access its applications.")
            } actions: {
                Button("Pair Computer") { model.beginPairing() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if model.hostInfo == nil {
            ContentUnavailableView {
                Label("Computer Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } description: {
                Text("Check that your computer is awake and its streaming service is running.")
            } actions: {
                Button("Try Again") { model.refresh() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.libraryApps.isEmpty {
                        ContentUnavailableView("No Applications", systemImage: "gamecontroller", description: Text("Add applications in Sunshine or Apollo on your computer, then refresh."))
                    } else {
                        AppLibraryGrid(apps: model.libraryApps, runningAppID: model.hostInfo?.currentAppID,
                            artwork: model.artwork, loadingAllowed: model.artworkLoadingAllowed,
                            requestArtwork: { model.loadArtwork(for: $0) }, launch: start,
                            quit: model.requestQuitRemoteApplication)
                            .disabled(model.busy || session.isActive || launchTask != nil)
                    }
                    Text("During a stream, tap with three fingers to toggle statistics. Swipe inward from the left edge to disconnect and leave the application running on your computer. With VoiceOver, use the stream's accessibility actions. Touch and hold a running application here to quit it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }

    private func start(_ app: RemoteApp) {
        guard launchTask == nil, !session.isActive else { return }
        launchMessage = nil
        model.prepareLaunch(app, onPrepared: startPrepared)
    }

    private func startPrepared(_ app: RemoteApp, client: HostClient, host: HostInfo) {
        guard launchTask == nil, !session.isActive, model.selectedHostID == host.id, scenePhase == .active else { return }
        let settings = model.settings
        let statisticsPreferences = model.statisticsPreferences
        let showStatistics = model.showStatisticsByDefault
        launchGeneration &+= 1
        let generation = launchGeneration
        launchTask = Task {
            defer { if launchGeneration == generation { launchTask = nil } }
            do {
                try Task.checkCancellation()
                try await session.start(client: client, host: host, app: app, settings: settings,
                                        statisticsPreferences: statisticsPreferences, showStatistics: showStatistics)
            }
            catch {
                guard launchGeneration == generation, model.selectedHostID == host.id,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                if let conflict = error as? RunningApplicationConflict {
                    session.errorMessage = nil
                    launchMessage = nil
                    model.presentRunningApplicationConflict(conflict, nextApp: app, hostID: host.id)
                } else if let error = error as? HostError {
                    launchMessage = error.localizedDescription
                } else {
                    launchMessage = session.errorMessage ?? "The stream could not start. Check your computer and connection, then try again."
                }
            }
        }
    }

    private func cancelLaunch() {
        launchGeneration &+= 1
        launchTask?.cancel()
        launchTask = nil
    }
}

private struct MobileComputerList: View {
    @ObservedObject var model: MobileClientModel
    @ObservedObject private var discovery: BonjourHostDiscovery

    init(model: MobileClientModel) {
        self.model = model
        _discovery = ObservedObject(wrappedValue: model.discovery)
    }

    var body: some View {
        List(selection: Binding(get: { model.selectedHostID }, set: { model.selectHost(id: $0) })) {
            Section("My Computers") {
                ForEach(model.hosts) { host in
                    NavigationLink(value: host.id) {
                        Label {
                            Text(host.name)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("savedComputer")
                }
                Button {
                    model.showingAddComputer = true
                } label: {
                    Text("Add Host")
                        .font(.headline)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("addComputer")
                .disabled(model.busy)
            }
            Section {
                ForEach(discovery.hosts.filter { found in !model.hosts.contains { $0.address == found.address } }) { host in
                    Button {
                        model.addComputer(host.address.description)
                    } label: {
                        Label(host.name, systemImage: "desktopcomputer")
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                    }
                    .disabled(model.busy)
                    .accessibilityHint("Connect to this computer")
                }
                if discovery.hosts.isEmpty {
                    Label("Looking for computers…", systemImage: "network")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text(discovery.errorMessage ?? "Use the same local network as a computer running Sunshine or Apollo. You can also add a computer by address.")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("computerList")
    }
}

private struct MobileAddComputerView: View {
    @ObservedObject var model: MobileClientModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hostname or IP address", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(addComputer)
                        .accessibilityIdentifier("computerAddress")
                        .disabled(model.busy)
                } header: {
                    Text("Computer Address")
                } footer: {
                    Text("Enter the address shown by Sunshine or Apollo. Include a port if your computer uses a custom HTTP port.")
                }
                if model.busy {
                    Section { ProgressView("Connecting…") }
                }
                if let message = model.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("addComputerError")
                    }
                }
            }
            .navigationTitle("Add Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { model.dismissAddComputer() }
                        .accessibilityIdentifier("cancelAddComputer")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: addComputer)
                        .accessibilityIdentifier("confirmAddComputer")
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                }
            }
            .task { addressFocused = true }
        }
    }

    private func addComputer() {
        guard !model.busy, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addressFocused = false
        model.addComputer(address)
    }
}

private struct MobilePairingView: View {
    @ObservedObject var model: MobileClientModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter this PIN in Sunshine or Apollo on \(model.selectedHost?.name ?? "your computer").")
                    if let pin = model.pairingPIN {
                        Text(pin)
                            .font(.largeTitle.monospacedDigit().weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical)
                            .accessibilityLabel("Pairing PIN")
                            .accessibilityValue(pin.map(String.init).joined(separator: ", "))
                            .privacySensitive()
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Button("Try Again") { model.beginPairing() }
                            .disabled(model.busy)
                    } else {
                        ProgressView("Waiting for your computer…")
                    }
                }
            }
            .navigationTitle("Pair Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { model.cancelPairing() }
                }
            }
        }
    }
}

#endif
