import SwiftUI
import AppKit

@main
struct SwiftlightApp: App {
    init() {
        #if DEBUG
        // Enable the public Metal HUD facility before any Metal device is created.
        // Each streaming layer keeps it disabled unless the debug option is on.
        setenv("MTL_HUD_ENABLED", "1", 0)
        #endif
    }
    @StateObject private var model = ClientModel()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Swiftlight", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear { delegate.model = model }
                .onDisappear { model.disconnect() }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Hosts") { model.refreshHost() }.keyboardShortcut("r")
                    .disabled(model.busy || model.selectedHost == nil || model.isSessionActive)
            }
            CommandMenu("Stream") {
                Button("Export Last Stream Diagnostics…") { model.exportLastStreamDiagnostics() }
                    .disabled(model.lastStreamDiagnostics == nil)
                Divider()
                Button("Video Validation…") { openWindow(id: "replay") }
                #if DEBUG
                Divider()
                Button("Run Latency Comparison (Short)") { model.runLatencyExperiments(short: true) }
                Button("Run Latency Comparison (Full)") { model.runLatencyExperiments() }
                Button("Run Statistics Overlay Comparison") { model.runStatisticsOverlayComparison() }
                Button("Cancel Latency Comparison") { model.cancelLatencyExperiments() }
                Button("Toggle Metal HUD for Next Stream") { model.renderOptions.showMetalHUD.toggle() }
                Button("Preview Native PQ Root Layer on Next Stream") {
                    var options = StreamRenderOptions()
                    options.nativePQOutput = true; options.cacheEDRMetadata = true
                    options.useRootMetalLayer = true; options.hideEmptyOverlayContainer = true
                    options.showMetalHUD = true
                    model.renderOptions = options
                }
                Button("Reset Rendering Experiments") { model.renderOptions = .init() }
                #endif
                Divider()
                Button("Disconnect") { model.disconnect() }.keyboardShortcut("q", modifiers: [.control, .option, .shift]).disabled(!model.isSessionActive)
                Button(model.showingStreamStatistics ? "Hide Stream Statistics" : "Show Stream Statistics") {
                    model.handleStreamShortcut(.toggleStatistics)
                }.keyboardShortcut("s", modifiers: [.control, .option, .shift]).disabled(!model.isSessionActive)
                Button("Full Screen") { model.streamWindow.toggleFullScreen() }.keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
        Window("Video Validation", id: "replay") { ReplayPreview() }.defaultSize(width: 1000, height: 700)
        Settings { SettingsView(model: model).frame(width: 520).padding(24) }
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: ClientModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
