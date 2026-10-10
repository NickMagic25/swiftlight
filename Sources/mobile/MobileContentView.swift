#if os(iOS)
import SwiftUI
import SwiftlightCore
import SwiftlightHost

struct MobileContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: MobileClientModel
    @ObservedObject var session: MobileStreamingSession
    @ObservedObject private var discovery: BonjourHostDiscovery
    @State private var showingSettings = false
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var launchTask: Task<Void, Never>?
    @State private var launchGeneration: UInt64 = 0
    @State private var launchMessage: String?
    @State private var controllerNavigation = ControllerMenuNavigation()

    init(model: MobileClientModel, session: MobileStreamingSession) {
        self.model = model
        self.session = session
        _discovery = ObservedObject(wrappedValue: model.discovery)
    }

    var body: some View {
        MobileControllerEventContent { navigation }
        .controllerMenuInput(enabled: scenePhase == .active && !session.isActive, handler: handleControllerMenu)
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
        .background(MobileStreamPresentation(session: session).allowsHitTesting(false).accessibilityHidden(true))
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
            if let selection {
                preferredCompactColumn = .detail
                controllerNavigation.selectedComputer("saved:\(selection)")
            }
        }
        .onChange(of: model.libraryApps.map(\.id)) { _, applications in
            if controllerNavigation.region == .applications,
               !applications.contains(controllerNavigation.applicationID ?? -1) {
                controllerNavigation.applicationID = applications.first
            }
        }
        .onChange(of: preferredCompactColumn) { _, column in
            if column == .sidebar { controllerNavigation.returnToComputers(computerChoices) }
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

    private var navigation: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            MobileComputerList(model: model, controllerSelection: controllerNavigation.isActive && controllerNavigation.region == .computers ? controllerNavigation.computerID : nil)
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
    }

    private var computerChoices: [String] {
        model.hosts.map { "saved:\($0.id)" } + ["add"] + nearbyComputers.map { "nearby:\($0.id)" }
    }

    private var nearbyComputers: [DiscoveredHost] {
        discovery.hosts.filter { found in !model.hosts.contains { $0.address == found.address } }
    }

    private func handleControllerMenu(_ action: MenuControllerAction) {
        guard scenePhase == .active, !session.isActive else { return }
        // A controller can dismiss a modal, but can never activate its destructive
        // action or move the hidden computer/game selection underneath it.
        if model.remoteApplicationAction != nil {
            if action == .back { model.remoteApplicationAction = nil }
            return
        }
        if model.showingPairing {
            if action == .back { model.cancelPairing() }
            return
        }
        if model.showingAddComputer {
            if action == .back { model.dismissAddComputer() }
            return
        }
        if showingSettings {
            if action == .back { showingSettings = false }
            return
        }
        if launchMessage != nil || model.message != nil {
            if action == .back { launchMessage = nil; model.message = nil }
            return
        }
        controllerNavigation.isActive = true
        if action == .back {
            cancelLaunch()
            controllerNavigation.returnToComputers(computerChoices)
            preferredCompactColumn = .sidebar
            return
        }
        guard !model.busy, launchTask == nil else { return }
        switch action {
        case .move(let direction):
            if direction == .right, controllerNavigation.region == .computers {
                guard let hostID = model.selectedHostID else { return }
                let selected = "saved:\(hostID)"
                guard controllerNavigation.computerID == nil || controllerNavigation.computerID == selected else { return }
                controllerNavigation.computerID = selected
            }
            controllerNavigation.move(direction, computers: computerChoices, applications: model.libraryApps.map(\.id))
            preferredCompactColumn = controllerNavigation.region == .computers ? .sidebar : .detail
        case .activate:
            if controllerNavigation.region == .computers {
                let choice = controllerNavigation.computerID ?? model.selectedHostID.map { "saved:\($0)" } ?? computerChoices.first
                if let host = model.hosts.first(where: { "saved:\($0.id)" == choice }) {
                    controllerNavigation.selectedComputer("saved:\(host.id)")
                    if model.selectedHostID == host.id { controllerNavigation.applicationID = model.libraryApps.first?.id }
                    preferredCompactColumn = .detail
                    model.selectHost(id: host.id)
                } else if let host = nearbyComputers.first(where: { "nearby:\($0.id)" == choice }) {
                    model.addComputer(host.address.description)
                } else if choice == "add" {
                    model.showingAddComputer = true
                }
            } else if model.hostInfo?.isPaired == false {
                model.beginPairing()
            } else if model.selectedHost == nil {
                model.showingAddComputer = true
            } else if model.hostInfo == nil || model.libraryApps.isEmpty {
                model.refresh()
            } else if let app = model.libraryApps.first(where: { $0.id == controllerNavigation.applicationID }) ?? model.libraryApps.first {
                start(app)
            }
        case .settings: showingSettings = true
        case .back: break
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
                    .controllerMenuHighlight(controllerNavigation.isActive && controllerNavigation.region == .applications)
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
                    .controllerMenuHighlight(controllerNavigation.isActive && controllerNavigation.region == .applications)
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
                    .controllerMenuHighlight(controllerNavigation.isActive && controllerNavigation.region == .applications)
            }
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.libraryApps.isEmpty {
                            ContentUnavailableView("No Applications", systemImage: "gamecontroller", description: Text("Add applications in Sunshine or Apollo on your computer, then refresh."))
                        } else {
                            AppLibraryGrid(apps: model.libraryApps, runningAppID: model.hostInfo?.currentAppID,
                                artwork: model.artwork, loadingAllowed: model.artworkLoadingAllowed,
                                requestArtwork: { model.loadArtwork(for: $0) }, launch: start,
                                quit: model.requestQuitRemoteApplication,
                                controllerSelectedAppID: controllerNavigation.isActive && controllerNavigation.region == .applications ? controllerNavigation.applicationID : nil,
                                onColumnCountChange: { controllerNavigation.applicationColumns = $0 })
                                .disabled(model.busy || session.isActive || launchTask != nil)
                        }
                        Text("During a stream, tap with three fingers to toggle statistics. Swipe inward from the left edge to disconnect and leave the application running on your computer. With VoiceOver, use the stream's accessibility actions. Touch and hold a running application here to quit it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                .onChange(of: controllerNavigation.applicationID) { _, selection in
                    if controllerNavigation.isActive, let selection { scroll.scrollTo(selection, anchor: .center) }
                }
            }
        }
    }

    private func start(_ app: RemoteApp) {
        guard launchTask == nil, !session.isActive else { return }
        launchMessage = nil
        launchGeneration &+= 1
        let generation = launchGeneration
        model.prepareLaunch(app) { preparedApp, client, host in
            guard launchGeneration == generation else { return }
            startPrepared(preparedApp, client: client, host: host)
        }
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
        model.cancelLaunchPreparation()
    }
}

private struct MobileComputerList: View {
    @ObservedObject var model: MobileClientModel
    @ObservedObject private var discovery: BonjourHostDiscovery
    let controllerSelection: String?

    init(model: MobileClientModel, controllerSelection: String?) {
        self.model = model
        self.controllerSelection = controllerSelection
        _discovery = ObservedObject(wrappedValue: model.discovery)
    }

    var body: some View {
        ScrollViewReader { scroll in
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
                        .id("saved:\(host.id)")
                        .controllerMenuHighlight(controllerSelection == "saved:\(host.id)")
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
                    .id("add")
                    .controllerMenuHighlight(controllerSelection == "add")
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
                        .id("nearby:\(host.id)")
                        .controllerMenuHighlight(controllerSelection == "nearby:\(host.id)")
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
            .onChange(of: controllerSelection) { _, selection in
                if let selection { scroll.scrollTo(selection, anchor: .center) }
            }
        }
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
