import SwiftUI
import AppKit

@main
struct SwiftlightApp: App {
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
                Button("Video Validation…") { openWindow(id: "replay") }
                Divider()
                Button("Disconnect") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!model.isSessionActive)
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
