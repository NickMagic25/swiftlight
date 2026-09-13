import SwiftUI
import SwiftlightHost
import SwiftlightCore

struct ContentView: View {
    @ObservedObject var model: ClientModel
    @State private var showingAddHost = false
    @State private var showingSettings = false
    @State private var confirmingQuit = false
    @State private var confirmingRemove = false
    var body: some View {
        Group {
            if let pipeline = model.pipeline, let transport = model.transport {
                ZStack(alignment: .top) {
                    StreamSurface(pipeline: pipeline, transport: transport, settings: model.settings,
                                  onDisplay: updateDisplay, onError: { model.renderFailure = $0 }, onCapture: { model.inputCaptured = $0 },
                                  onShortcut: model.handleStreamShortcut)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        if !model.inputCaptured { streamOverlay }
                        if model.showingStreamStatistics {
                            StreamStatisticsOverlay(rows: model.streamStatisticRows)
                                .frame(maxWidth: .infinity, alignment: statisticsAlignment)
                                .padding(.horizontal, 16)
                        }
                        Spacer(minLength: 0)
                    }.padding(.top, 12)
                }.background(.black)
            } else {
                NavigationSplitView {
                    List(selection: Binding(get: { model.selectedHostID }, set: { id in
                        if let host = model.hosts.first(where: { $0.id == id }) { model.selectHost(host) }
                    })) {
                        Section("Your Computers") {
                            ForEach(model.hosts) { host in
                                Label(host.name, systemImage: "desktopcomputer").tag(host.id)
                                    .help(host.address.description)
                            }
                        }
                    }
                    .disabled(model.busy)
                    .navigationTitle("Swiftlight")
                    .navigationSplitViewColumnWidth(min: 210, ideal: 240)
                    .safeAreaInset(edge: .bottom) {
                        Button { showingAddHost = true } label: { Label("Add Computer", systemImage: "plus") }
                            .swiftlightGlassButton().padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                } detail: {
                    library
                }
                .background(DisplayProbe(onChange: updateDisplay).frame(width: 0, height: 0))
            }
        }
        .background(StreamWindowReader(controller: model.streamWindow).frame(width: 0, height: 0))
        .toolbar(model.isSessionActive ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            if model.pipeline == nil {
                ToolbarItemGroup {
                    Button { showingAddHost = true } label: { Label("Add Computer", systemImage: "plus") }
                    Button { model.refreshHost() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.selectedHost == nil || model.busy)
                    Button { showingSettings = true } label: { Label("Stream Settings", systemImage: "slider.horizontal.3") }
                }
            }
        }
        .sheet(isPresented: $showingAddHost) { AddHostView(model: model) }
        .sheet(isPresented: $model.showingPairing) { PairingView(model: model) }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                SettingsView(model: model).padding(24)
                HStack { Spacer(); Button("Done") { model.saveSettings(); showingSettings = false }
                    .keyboardShortcut(.defaultAction).swiftlightGlassButton(prominent: true) }.padding()
            }.frame(width: 540)
        }
        .alert("Swiftlight", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("Quit the remote application?", isPresented: $confirmingQuit) {
            Button("Quit Remote Application", role: .destructive) { model.quitRemoteApplication() }
        } message: { Text("This ends the application on the host. Disconnect leaves it running.") }
        .confirmationDialog("Remove this computer and its saved pairing?", isPresented: $confirmingRemove) {
            Button("Remove Computer", role: .destructive) { model.removeHost() }
        }
    }
    private func updateDisplay(_ geometry: DisplayGeometry, _ headroom: Double) {
        if model.display != geometry { model.display = geometry }
        if model.hdrHeadroom != headroom { model.hdrHeadroom = headroom }
    }
    @ViewBuilder private var library: some View {
        if let host = model.selectedHost {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(host.name).font(.largeTitle.bold())
                            Text(host.address.description).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(model.hostStatus)
                                .font(.callout).foregroundStyle(model.hostInfo?.isPaired == true ? .green : .secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Export Last Stream Diagnostics…") { model.exportLastStreamDiagnostics() }
                                .disabled(model.lastStreamDiagnostics == nil)
                            Divider()
                            Button("Pair Computer") { model.showingPairing = true }.disabled(model.hostInfo?.isPaired == true)
                            Button("Unpair and Pair Again") { model.unpair() }
                            Button("Remove Computer…", role: .destructive) { confirmingRemove = true }
                            if (model.hostInfo?.currentAppID ?? 0) > 0 { Button("Quit Remote Application…", role: .destructive) { confirmingQuit = true } }
                        } label: { Image(systemName: "ellipsis").font(.title3) }
                            .menuStyle(.button).swiftlightGlassButton().fixedSize().disabled(model.busy)
                            .accessibilityLabel("Computer options")
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                    if model.hostInfo?.isPaired == false {
                        ContentUnavailableView {
                            Label("Pair this computer", systemImage: "lock.shield")
                        } description: { Text("Connect securely to your Sunshine or Apollo host, then choose a game or desktop.") }
                        actions: { Button("Pair Computer") { model.showingPairing = true }.swiftlightGlassButton(prominent: true) }
                    } else if model.apps.isEmpty && !model.busy {
                        ContentUnavailableView("No applications loaded", systemImage: "square.grid.2x2", description: Text("Refresh the computer to load its application library."))
                    } else {
                        AppLibraryGrid(apps: model.apps, runningAppID: model.hostInfo?.currentAppID,
                                       artwork: model.artwork, loadingAllowed: !model.isSessionActive,
                                       requestArtwork: { model.loadArtwork(for: $0) }, launch: model.launch)
                    }
                    if model.state.phase == .suspending { Button("Resume after Sleep") { model.resumeSuspended() }.swiftlightGlassButton(prominent: true) }
                    if model.isSessionActive {
                        HStack { ProgressView(); Text("Connecting to \(model.activeApp?.name ?? "host")…"); Spacer(); Button("Cancel") { model.disconnect() }.buttonStyle(.borderless) }
                            .padding(16).swiftlightGlassSurface()
                    }
                }.padding(32)
            }
            .safeAreaInset(edge: .bottom) { NetworkFooter(network: model.network) }
            .navigationTitle(host.name)
            .onAppear { model.loadArtwork() }
        } else {
            ContentUnavailableView {
                Label("Your games. Your Mac.", systemImage: "gamecontroller")
            } description: { Text("Add a computer running Sunshine or Apollo to stream your library with native Apple video, audio, and input.").frame(maxWidth: 380) }
            actions: { Button("Add Computer") { showingAddHost = true }.swiftlightGlassButton(prominent: true).controlSize(.large) }
        }
    }
    private var streamOverlay: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.activeApp?.name ?? "Stream").font(.headline)
                Text("Click video to capture input · ⌃⌥⇧Q disconnects · ⌃⌥⇧S toggles statistics").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.streamWindow.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Toggle full screen")
            Menu {
                Button(model.showingStreamStatistics ? "Hide Statistics" : "Show Statistics") { model.handleStreamShortcut(.toggleStatistics) }
                Button("Export Diagnostics…") { model.exportDiagnostics() }
                Button("Stream Settings…") { showingSettings = true }
            } label: { Image(systemName: "ellipsis.circle") }.help("Stream options")
            Button("Reconnect") { model.reconnect() }
            Button("Disconnect") { model.disconnect() }
        }.buttonStyle(.borderless).padding(16).swiftlightGlassSurface(cornerRadius: 20).padding(.horizontal, 16)
    }
    private var statisticsAlignment: Alignment {
        switch model.statisticsPreferences.position {
        case .topLeading: .leading
        case .top: .center
        case .topTrailing: .trailing
        }
    }
}
struct NetworkFooter: View {
    @ObservedObject var network: NetworkStatus
    var body: some View {
        HStack {
            Label(network.description, systemImage: network.available ? "network" : "network.slash")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .swiftlightGlassSurface(cornerRadius: 20)
            Spacer()
        }.padding(.horizontal, 24).padding(.bottom, 12)
            .help("System path observation; the active stream's socket route may differ.")
    }
}
struct AddHostView: View {
    @ObservedObject var model: ClientModel
    @Environment(\.dismiss) var dismiss
    @State private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a computer").font(.title2.bold())
            Text("Enter a hostname or IP address, or select a discovered computer.").foregroundStyle(.secondary)
            TextField("Hostname, IP, or [IPv6]:port", text: $address).textFieldStyle(.roundedBorder).onSubmit(add)
            DiscoveredHostList(discovery: model.discovery) { address = $0; add() }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).swiftlightGlassButton()
                Spacer()
                Button("Continue", action: add).keyboardShortcut(.defaultAction).swiftlightGlassButton(prominent: true).disabled(address.isEmpty)
            }
        }.padding(24).frame(width: 460)
    }
    private func add() { guard !address.isEmpty else { return }; model.addHost(address: address); dismiss() }
}
struct DiscoveredHostList: View {
    @ObservedObject var discovery: BonjourHostDiscovery
    let choose: (String) -> Void
    var body: some View {
        VStack(alignment: .leading) {
            if let error = discovery.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            } else if discovery.hosts.isEmpty {
                Text("Looking for computers on your local network…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(discovery.hosts) { host in Button { choose(host.address.description) } label: { Label(host.name, systemImage: "desktopcomputer") }.swiftlightGlassButton() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct PairingView: View {
    @ObservedObject var model: ClientModel
    @State private var method = 0
    @State private var link = ""
    @State private var useSeparateFields = false
    @State private var apolloAddress = ""
    @State private var otp = ""
    @State private var passphrase = ""
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 42)).foregroundStyle(.tint)
            Text("Pair your computer").font(.title2.bold())
            Picker("Pairing method", selection: $method) { Text("PIN").tag(0); Text("Apollo").tag(1) }.pickerStyle(.segmented).disabled(model.busy)
            if method == 0 {
                if let pin = model.pairingPIN {
                    Text(pin).font(.system(size: 52, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        .accessibilityLabel("Pairing PIN \(pin.map(String.init).joined(separator: " "))")
                    Text("Enter this PIN in your host's pairing page. Keep this window open until pairing finishes.")
                    ProgressView().controlSize(.small)
                } else {
                    Text("Swiftlight will show a four-digit PIN. Enter it in the Sunshine or Apollo web interface to trust this Mac.").foregroundStyle(.secondary)
                    Button("Start PIN Pairing") { model.beginPINPairing() }.swiftlightGlassButton(prominent: true).disabled(model.busy)
                }
            } else {
                Toggle("Enter OTP and passphrase separately", isOn: $useSeparateFields).disabled(model.busy)
                if useSeparateFields {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Host address and HTTP port", text: $apolloAddress)
                            .accessibilityLabel("Apollo host address and HTTP port")
                        SecureField("One-time PIN", text: $otp).accessibilityLabel("Apollo one-time PIN")
                        SecureField("Passphrase", text: $passphrase).accessibilityLabel("Apollo passphrase")
                    }.textFieldStyle(.roundedBorder).disabled(model.busy)
                } else {
                    SecureField("Paste art:// pairing link", text: $link).textFieldStyle(.roundedBorder).disabled(model.busy)
                }
                Text("Generate a one-time pairing link in Apollo. Its secret is used only for this attempt.").font(.callout).foregroundStyle(.secondary)
                Button("Pair with Apollo", action: pairApollo).swiftlightGlassButton(prominent: true)
                    .disabled(model.busy || (useSeparateFields ? apolloAddress.isEmpty || otp.isEmpty || passphrase.isEmpty : link.isEmpty))
                if model.busy { ProgressView().controlSize(.small) }
            }
            Button("Cancel") { clearSecrets(); model.cancelPairing() }.keyboardShortcut(.cancelAction).swiftlightGlassButton()
        }.multilineTextAlignment(.center).padding(28).frame(width: 460).interactiveDismissDisabled(model.busy)
            .onAppear { apolloAddress = model.selectedHost?.address.description ?? "" }
            .onDisappear { clearSecrets() }
    }
    private func pairApollo() {
        do {
            let credential = try useSeparateFields
                ? ApolloPairingCredential(address: HostAddress(apolloAddress), otp: otp, passphrase: passphrase)
                : ApolloPairingCredential(link: link)
            clearSecrets(); model.pairApollo(credential: credential)
        } catch { clearSecrets(); model.message = error.localizedDescription }
    }
    private func clearSecrets() { link = ""; otp = ""; passphrase = "" }
}
