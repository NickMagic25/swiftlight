// Appended to the production controller after substituting only its NSWindow
// and NSApplication type names. No display server or real UI is accessed.
@MainActor final class FixtureApplication {
    // The imported option type preserves Objective-C delegate ABI. Its use does
    // not create/access NSApplication.shared or alter actual presentation options.
    typealias PresentationOptions = NSApplication.PresentationOptions
    static let shared = FixtureApplication()
    var presentationOptions: PresentationOptions = []
}
@MainActor @objc protocol FixtureWindowDelegate: NSObjectProtocol {
    @objc optional func window(_ window: FixtureWindow, willUseFullScreenContentSize proposed: NSSize) -> NSSize
    @objc optional func window(_ window: FixtureWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions
    @objc optional func windowShouldClose(_ window: FixtureWindow) -> Bool
}
@MainActor final class FixtureContent {
    var layoutCount = 0
    func layoutSubtreeIfNeeded() { layoutCount += 1 }
}
@MainActor final class FixtureToolbar {
    var isVisible: Bool
    init(visible: Bool) { isVisible = visible }
}
@MainActor final class FixtureScreen {
    let frame: CGRect
    init(frame: CGRect) { self.frame = frame }
}
@MainActor final class FixtureWindow: NSObject {
    struct Style: OptionSet {
        let rawValue: Int
        static let fullScreen = Style(rawValue: 1)
        static let fullSizeContentView = Style(rawValue: 2)
    }
    struct Behavior: OptionSet { let rawValue: Int; static let fullScreenPrimary = Behavior(rawValue: 1) }
    static let willEnterFullScreenNotification = Notification.Name("fixture.willEnter")
    static let willExitFullScreenNotification = Notification.Name("fixture.willExit")
    static let didEnterFullScreenNotification = Notification.Name("fixture.didEnter")
    static let didExitFullScreenNotification = Notification.Name("fixture.didExit")
    var styleMask: Style
    var collectionBehavior: Behavior = []
    let toolbar: FixtureToolbar?
    let contentView: FixtureContent? = FixtureContent()
    var pendingTransition: Bool?
    var toggleCount = 0
    var screen: FixtureScreen?
    var frame: CGRect
    var proposedFullScreenFrame: CGRect?
    private var previousWindowedFrame: CGRect
    var setFrameCount = 0
    var lastDisplayRequest: Bool?
    weak var delegate: (any FixtureWindowDelegate)?
    var negotiatedContentSize: NSSize?
    var negotiatedPresentationOptions: FixtureApplication.PresentationOptions?
    init(fullScreen: Bool = false, toolbarVisible: Bool = true, fullSizeContent: Bool = false,
         frame: CGRect? = nil, screenFrame: CGRect = CGRect(x: 0, y: 0, width: 3440, height: 1440)) {
        styleMask = fullScreen ? [.fullScreen] : []
        if fullSizeContent { styleMask.insert(.fullSizeContentView) }
        toolbar = FixtureToolbar(visible: toolbarVisible)
        screen = FixtureScreen(frame: screenFrame)
        previousWindowedFrame = CGRect(x: 100, y: 100, width: 1280, height: 720)
        self.frame = frame ?? (fullScreen ? screenFrame : previousWindowedFrame)
    }
    func setFrame(_ frame: CGRect, display: Bool) {
        setFrameCount += 1; lastDisplayRequest = display; self.frame = frame
    }
    func toggleFullScreen(_ sender: Any?) {
        toggleCount += 1
        pendingTransition = !styleMask.contains(.fullScreen)
        if pendingTransition == true {
            previousWindowedFrame = frame
            let proposed = proposedFullScreenFrame ?? screen?.frame ?? frame
            negotiatedContentSize = delegate?.window?(self, willUseFullScreenContentSize: proposed.size)
            negotiatedPresentationOptions = delegate?.window?(self, willUseFullScreenPresentationOptions: FixtureApplication.shared.presentationOptions.union(.fullScreen))
        }
        NotificationCenter.default.post(name: pendingTransition == true ? Self.willEnterFullScreenNotification : Self.willExitFullScreenNotification, object: self)
    }
    func completeTransition() {
        guard let destination = pendingTransition else { return }
        pendingTransition = nil
        if destination {
            frame = proposedFullScreenFrame ?? screen?.frame ?? frame
            if let negotiatedContentSize { frame.size = negotiatedContentSize }
            styleMask.insert(.fullScreen)
            FixtureApplication.shared.presentationOptions.insert(.fullScreen)
        } else {
            // AppKit restores the pre-full-screen frame before notifying clients.
            frame = previousWindowedFrame
            styleMask.remove(.fullScreen)
            FixtureApplication.shared.presentationOptions.remove(.fullScreen)
        }
        NotificationCenter.default.post(name: destination ? Self.didEnterFullScreenNotification : Self.didExitFullScreenNotification, object: self)
    }
}
@MainActor private func geometry(for content: FixtureContent) -> (DisplayGeometry, Double) { (.fallback, 1) }

@MainActor private final class OriginalWindowDelegate: NSObject, FixtureWindowDelegate {
    var sizeCalls = 0, optionsCalls = 0, closeCalls = 0
    let preferredSize = NSSize(width: 3000, height: 1400)
    let preferredOptions: FixtureApplication.PresentationOptions = [.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar]
    func window(_ window: FixtureWindow, willUseFullScreenContentSize proposed: NSSize) -> NSSize {
        sizeCalls += 1; return preferredSize
    }
    func window(_ window: FixtureWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        optionsCalls += 1; return preferredOptions
    }
    func windowShouldClose(_ window: FixtureWindow) -> Bool { closeCalls += 1; return false }
}

@MainActor private final class PreparationProbe {
    var done = false
    var succeeded = false
    var canceled = false
    var failure: String?
    var task: Task<Void, Never>?
    init(_ controller: StreamWindowController, settings: StreamSettings = StreamSettings()) {
        task = Task {
            do { _ = try await controller.prepare(settings: settings); succeeded = true }
            catch is CancellationError { canceled = true }
            catch { failure = error.localizedDescription }
            done = true
        }
    }
}

@main private struct WindowLifecycleHarness {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsError.invalid(message) }
    }
    @MainActor static func until(_ predicate: () -> Bool, seconds: Int = 2) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw SettingsError.invalid("Lifecycle wait timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    @MainActor static func main() async {
        var checks: [String] = []
        do {
            // Cancel while entering, then deliver both delayed AppKit completions.
            do {
                let controller = StreamWindowController(), window = FixtureWindow()
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until { window.pendingTransition == true }
                try require(window.toolbar?.isVisible == false && !probe.done, "Preparation must wait for full-screen geometry")
                probe.task?.cancel(); controller.endSession()
                try await until { probe.done }
                try require(probe.canceled, "Canceled entry must cancel its continuation")
                window.completeTransition()
                try require(window.pendingTransition == false, "Late entry completion must restore the original windowed state")
                window.completeTransition()
                try require(!window.styleMask.contains(.fullScreen) && window.toolbar?.isVisible == true, "Canceled entry lost window/toolbar restoration")
                try require(!window.styleMask.contains(.fullSizeContentView), "Canceled entry did not restore the original content style")
                try require(FixtureApplication.shared.presentationOptions.isEmpty, "Canceled entry did not restore menu bar and Dock presentation")
                controller.attach(nil)
                checks.append("cancellation during entry and delayed restoration")
            }
            // A manual exit during a session must not be forced back to full screen.
            do {
                let controller = StreamWindowController(), window = FixtureWindow()
                controller.attach(window)
                for _ in 0..<3 {
                    let probe = PreparationProbe(controller)
                    try await until { window.pendingTransition == true }
                    window.completeTransition()
                    try await until { probe.done }
                    try require(probe.succeeded && window.contentView!.layoutCount > 0, "Successful entry must resolve current geometry")
                    try require(window.styleMask.contains(.fullSizeContentView), "Full-screen streaming must include the titlebar content area")
                    controller.toggleFullScreen(); window.completeTransition()
                    try require(window.pendingTransition == nil && !window.styleMask.contains(.fullScreen), "Manual exit was forced back to full screen")
                    try require(!window.styleMask.contains(.fullSizeContentView), "Manual exit did not restore the original content style")
                    controller.endSession()
                    try require(window.pendingTransition == nil && window.toolbar?.isVisible == true, "Repeated session failed restoration")
                }
                try require(window.toggleCount == 6, "Unexpected duplicate full-screen transitions")
                controller.attach(nil)
                checks.append("three sessions with manual exit and no forced reentry")
            }
            // A window already in full screen remains there after disconnect.
            do {
                let controller = StreamWindowController(), window = FixtureWindow(fullScreen: true, toolbarVisible: false)
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until { probe.done }
                try require(window.styleMask.contains(.fullSizeContentView), "Already full-screen playback must use full-size content")
                controller.endSession()
                try require(probe.succeeded && window.toggleCount == 0 && window.styleMask.contains(.fullScreen), "Initially full-screen window was not preserved")
                try require(window.toolbar?.isVisible == false, "Initially hidden toolbar was not preserved")
                try require(!window.styleMask.contains(.fullSizeContentView), "Ending an initially full-screen session did not restore its content style")
                var windowed = StreamSettings(); windowed.launchInFullScreen = false
                let second = PreparationProbe(controller, settings: windowed)
                try await until { window.pendingTransition == false }
                window.completeTransition(); try await until { second.done }
                controller.endSession()
                try require(window.pendingTransition == true, "Windowed launch must restore an initially full-screen window")
                window.completeTransition()
                try require(second.succeeded && window.styleMask.contains(.fullScreen), "Windowed launch restoration failed")
                controller.attach(nil)
                checks.append("initial full-screen and toolbar state restored")
            }
            // A pre-existing full-size content style belongs to the application
            // and must survive both manual exit and session teardown.
            do {
                let controller = StreamWindowController(), window = FixtureWindow(fullSizeContent: true)
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until { window.pendingTransition == true }
                window.completeTransition(); try await until { probe.done }
                controller.toggleFullScreen(); window.completeTransition()
                try require(window.styleMask.contains(.fullSizeContentView), "Manual exit removed the pre-existing full-size content flag")
                controller.endSession()
                try require(probe.succeeded && window.styleMask.contains(.fullSizeContentView), "Teardown removed the pre-existing full-size content flag")
                controller.attach(nil)
                checks.append("full-size content enabled for playback and original flag restored")
            }
            // Replacing the window retires old notification delivery and toolbar
            // state; its pending preparation must fail visibly, not as cancellation.
            do {
                let controller = StreamWindowController(), oldWindow = FixtureWindow()
                let replacement = FixtureWindow(fullScreen: true, toolbarVisible: false)
                controller.attach(oldWindow)
                let old = PreparationProbe(controller)
                try await until { oldWindow.pendingTransition == true }
                controller.attach(replacement)
                try await until { old.done }
                try require(old.failure != nil && !old.canceled, "Window replacement must report a visible preparation failure")
                try require(oldWindow.toolbar?.isVisible == true, "Replacement did not restore the old toolbar")
                try require(!oldWindow.styleMask.contains(.fullSizeContentView), "Replacement did not restore the old content style")
                oldWindow.completeTransition()
                let current = PreparationProbe(controller)
                try await until { current.done }
                controller.endSession()
                try require(current.succeeded && replacement.toggleCount == 0 && replacement.styleMask.contains(.fullScreen), "Replacement inherited stale windowed restoration state")
                try require(replacement.toolbar?.isVisible == false, "Replacement inherited stale toolbar visibility")
                controller.attach(nil)
                let absent = PreparationProbe(controller)
                try await until { absent.done }
                try require(absent.failure != nil && !absent.canceled, "Missing window must fail visibly")
                checks.append("window replacement retires old notifications and state")
            }
            // Application presentation is temporary and must not overwrite the
            // fullScreen bit changed by the platform during a native transition.
            do {
                let app = FixtureApplication.shared
                let original: FixtureApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
                app.presentationOptions = original
                let controller = StreamWindowController(), window = FixtureWindow()
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until { window.pendingTransition == true }
                try require(app.presentationOptions == [.hideDock, .hideMenuBar], "Playback must hide the menu bar and Dock without auto-hide or process restrictions")
                window.completeTransition(); try await until { probe.done }
                try require(app.presentationOptions == [.fullScreen, .hideDock, .hideMenuBar], "Playback lost the platform-owned full-screen bit")
                controller.toggleFullScreen(); window.completeTransition()
                try require(app.presentationOptions == original, "Manual exit did not restore menu bar and Dock options")
                controller.endSession(); controller.attach(nil)
                let alreadyFullScreen = FixtureWindow(fullScreen: true)
                app.presentationOptions = original.union(.fullScreen)
                controller.attach(alreadyFullScreen)
                let second = PreparationProbe(controller)
                try await until { second.done }
                controller.endSession()
                try require(second.succeeded && app.presentationOptions == original.union(.fullScreen), "Session end must restore options and retain the current platform full-screen bit")
                controller.attach(nil)
                app.presentationOptions = []
                checks.append("menu bar and Dock options restored with platform full-screen bit preserved")
            }
            // Auto-hiding the toolbar is valid only while the platform keeps the
            // application in full screen; restoration after manual exit removes it.
            do {
                let app = FixtureApplication.shared
                app.presentationOptions = [.fullScreen, .autoHideToolbar, .autoHideDock, .autoHideMenuBar]
                let controller = StreamWindowController(), window = FixtureWindow(fullScreen: true)
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until { probe.done }
                controller.toggleFullScreen(); window.completeTransition()
                try require(probe.succeeded && app.presentationOptions == [.autoHideDock, .autoHideMenuBar], "Windowed restoration retained the full-screen-only autoHideToolbar option")
                controller.endSession(); window.completeTransition(); controller.attach(nil)
                app.presentationOptions = []
                checks.append("windowed restoration excludes full-screen-only toolbar option")
            }
            // Simulate AppKit proposing a 3440x1410 window on a 3440x1440
            // display. Correction is bounded and only applies to an active stream.
            do {
                let screenFrame = CGRect(x: -3440, y: 200, width: 3440, height: 1440)
                let shortFrame = CGRect(x: -3440, y: 200, width: 3440, height: 1410)
                let originalFrame = CGRect(x: -3000, y: 300, width: 1200, height: 800)
                let controller = StreamWindowController()
                let window = FixtureWindow(frame: originalFrame, screenFrame: screenFrame)
                window.proposedFullScreenFrame = shortFrame
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until { window.pendingTransition == true }
                try require(window.setFrameCount == 0, "Preparation resized a window before it entered full screen")
                window.completeTransition(); try await until { probe.done }
                try require(probe.succeeded && window.frame == screenFrame && window.setFrameCount == 0, "Native full-screen content negotiation must cover the display before post-transition sizing")
                NotificationCenter.default.post(name: FixtureWindow.didEnterFullScreenNotification, object: window)
                try require(window.setFrameCount == 0, "Already-correct full-screen frame triggered redundant resizing")
                controller.toggleFullScreen(); window.completeTransition(); controller.endSession()
                try require(window.frame == originalFrame && window.setFrameCount == 0, "Controller changed AppKit's restored windowed frame")
                var windowed = StreamSettings(); windowed.launchInFullScreen = false
                let second = PreparationProbe(controller, settings: windowed)
                try await until { second.done }
                controller.endSession()
                try require(second.succeeded && window.frame == originalFrame && window.setFrameCount == 0, "Windowed stream was resized to the display")
                controller.attach(nil)
                let alreadyFullScreen = FixtureWindow(fullScreen: true, frame: shortFrame, screenFrame: screenFrame)
                controller.attach(alreadyFullScreen)
                let third = PreparationProbe(controller)
                try await until { third.done }
                try require(third.succeeded && alreadyFullScreen.frame == screenFrame && alreadyFullScreen.setFrameCount == 1, "Already-full-screen preparation did not correct a short window")
                controller.endSession(); controller.attach(nil)
                let library = FixtureWindow(frame: originalFrame, screenFrame: screenFrame)
                library.proposedFullScreenFrame = shortFrame
                controller.attach(library); controller.toggleFullScreen(); library.completeTransition()
                try require(library.frame == shortFrame && library.setFrameCount == 0, "Inactive library full-screen transition was resized")
                controller.toggleFullScreen(); library.completeTransition(); controller.attach(nil)
                FixtureApplication.shared.presentationOptions = []
                checks.append("native full-screen negotiation fills display and preserves windowed geometry")
            }
            // Intercept only the two negotiation hooks. Other optional selectors
            // and the prior delegate's lifetime/restoration remain intact.
            do {
                let controller = StreamWindowController(), window = FixtureWindow()
                let original = OriginalWindowDelegate()
                window.delegate = original; controller.attach(window)
                try require(window.delegate === original, "Attaching an idle window replaced its delegate")
                let probe = PreparationProbe(controller)
                try await until { window.pendingTransition == true }
                guard let proxy = window.delegate else { throw SettingsError.invalid("Missing delegate proxy") }
                try require(proxy !== original && original.sizeCalls == 1 && original.optionsCalls == 1, "Negotiation did not call the prior delegate before overriding")
                try require(window.negotiatedContentSize == window.screen?.frame.size, "Proxy did not negotiate the entire screen")
                try require(window.negotiatedPresentationOptions == [.fullScreen, .hideDock, .hideMenuBar], "Proxy did not replace all conflicting auto-hide presentation options")
                try require(proxy.responds(to: #selector(FixtureWindowDelegate.windowShouldClose(_:))), "Proxy hid an optional original delegate selector")
                try require(proxy.windowShouldClose?(window) == false && original.closeCalls == 1, "Optional delegate message was not forwarded exactly once")
                try require(!proxy.responds(to: NSSelectorFromString("swiftlightUnknownFixtureSelector")), "Proxy claims an unsupported selector")
                let unrelated = FixtureWindow()
                try require(proxy.window?(unrelated, willUseFullScreenContentSize: .zero) == original.preferredSize, "Proxy overrode an unrelated window")
                window.completeTransition(); try await until { probe.done }
                controller.endSession()
                try require(window.delegate === original, "Ending a session did not restore the original delegate")
                try require(proxy.window?(window, willUseFullScreenContentSize: .zero) == original.preferredSize, "Retired proxy still overrides full-screen content size")
                window.completeTransition(); controller.attach(nil)

                var windowed = StreamSettings(); windowed.launchInFullScreen = false
                controller.attach(window)
                let next = PreparationProbe(controller, settings: windowed)
                try await until { next.done }
                let replacement = OriginalWindowDelegate()
                window.delegate = replacement
                controller.endSession(); controller.attach(nil)
                try require(window.delegate === replacement, "Restoration overwrote a new framework delegate")
                FixtureApplication.shared.presentationOptions = []
                checks.append("delegate proxy forwards optional callbacks and restores without clobbering replacements")
            }
            // With no AppKit completion, the real eight-second timeout must
            // release the caller and permit a subsequent windowed connection.
            do {
                let controller = StreamWindowController(), window = FixtureWindow()
                controller.attach(window)
                let probe = PreparationProbe(controller)
                try await until({ probe.done }, seconds: 10)
                try require(probe.failure?.contains("transition did not finish") == true, "Missing transition must produce a bounded failure")
                controller.endSession()
                var windowed = StreamSettings(); windowed.launchInFullScreen = false
                let retry = PreparationProbe(controller, settings: windowed)
                try await until { retry.done }
                try require(retry.succeeded, "Timed-out transition prevented a new windowed session")
                controller.endSession(); controller.attach(nil)
                checks.append("transition timeout and subsequent windowed recovery")
            }
            let evidence: [String: Any] = ["status": "PASS", "mode": "stream-window-lifecycle-no-window",
                "sourceSHA256": ProcessInfo.processInfo.environment["SWIFTLIGHT_WINDOW_SOURCE_SHA256"] ?? "",
                "checks": checks, "realWindowsCreated": 0, "visiblePresentationMeasured": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } catch {
            let evidence: [String: Any] = ["status": "FAIL", "reason": error.localizedDescription, "completedChecks": checks,
                "realWindowsCreated": 0, "sourceSHA256": ProcessInfo.processInfo.environment["SWIFTLIGHT_WINDOW_SOURCE_SHA256"] ?? ""]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            exit(1)
        }
    }
}
