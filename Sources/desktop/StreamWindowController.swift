#if os(macOS)
import AppKit
import SwiftUI
import SwiftlightCore

/// Owns presentation of the main client window, independently of the changing
/// library/stream view hierarchy. Full-screen animation never blocks the main actor.
@MainActor final class StreamWindowController {
    private weak var window: NSWindow?
    private var delegateProxy: StreamWindowDelegateProxy?
    private var observers: [NSObjectProtocol] = []
    private var transitioning = false
    private var target: Bool?
    private var restoreFullScreen: Bool?
    private var restoreToolbar: Bool?
    private var fullSizeContentBeforeFullScreen: Bool?
    private var presentationBeforeFullScreen: NSApplication.PresentationOptions?
    private var sessionActive = false
    private var preparation: CheckedContinuation<Void, Error>?
    private var preparationID = UUID()
    private var timeout: Task<Void, Never>?

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        finishPreparation(throwing: SettingsError.invalid("The stream window changed while preparing playback. Try opening the stream again."))
        if let restoreToolbar { self.window?.toolbar?.isVisible = restoreToolbar }
        setFullScreenContent(false)
        restoreWindowDelegate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        self.window = window
        transitioning = false
        target = nil; restoreFullScreen = nil; restoreToolbar = nil; sessionActive = false
        guard let window else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.transitioning = true
                    if name == NSWindow.willEnterFullScreenNotification, self?.sessionActive == true {
                        self?.setFullScreenContent(true)
                    }
                }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.transitioning = false
                    if name == NSWindow.didExitFullScreenNotification { self?.setFullScreenContent(false) }
                    if name == NSWindow.didEnterFullScreenNotification { self?.fitFullScreenWindow() }
                    self?.applyTarget()
                }
            })
        }
    }

    func prepare(settings: StreamSettings) async throws -> (DisplayGeometry, Double) {
        try Task.checkCancellation()
        guard let window else { throw SettingsError.invalid("The stream window is unavailable. Reopen Swiftlight and try again.") }
        let id = UUID(); preparationID = id
        if restoreFullScreen == nil { restoreFullScreen = window.styleMask.contains(.fullScreen) }
        if restoreToolbar == nil { restoreToolbar = window.toolbar?.isVisible }
        sessionActive = true
        installWindowDelegate(on: window)
        window.toolbar?.isVisible = false
        target = StreamPresentationPolicy.launchesFullScreen(on: .macOS, settings: settings)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                preparation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, self.preparationID == id else { return }
                    self.transitioning = false; self.target = nil
                    self.finishPreparation(throwing: SettingsError.invalid("Full-screen transition did not finish. Try again or turn off Start streams in full screen."))
                }
                applyTarget()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.preparationID == id else { return }
                self.finishPreparation(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
        guard let content = window.contentView else { throw CancellationError() }
        content.layoutSubtreeIfNeeded()
        return geometry(for: content)
    }

    func endSession() {
        finishPreparation(throwing: CancellationError())
        sessionActive = false
        if let restoreToolbar { window?.toolbar?.isVisible = restoreToolbar }
        restoreToolbar = nil
        target = restoreFullScreen
        applyTarget()
        restoreWindowDelegate()
    }

    func toggleFullScreen() {
        guard !transitioning, let window else { return }
        target = nil
        window.toggleFullScreen(nil)
    }

    private func applyTarget() {
        guard !transitioning, let window, let target else { return }
        if window.styleMask.contains(.fullScreen) == target {
            setFullScreenContent(sessionActive && target)
            if target { fitFullScreenWindow() }
            self.target = nil
            finishPreparation()
            if !sessionActive { restoreFullScreen = nil }
        } else {
            transitioning = true
            if target && sessionActive { setFullScreenContent(true) }
            window.toggleFullScreen(nil)
        }
    }

    private func fitFullScreenWindow() {
        guard sessionActive, let window, window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
        // Some menu-bar configurations propose the visible frame even for a native
        // full-screen Space. Video uses the entire screen; safe-area clipping is
        // applied separately by the surface when the user selects that mode.
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
    }

    fileprivate func overridesFullScreenPresentation(for window: NSWindow) -> Bool {
        sessionActive && self.window === window
    }

    private func installWindowDelegate(on window: NSWindow) {
        if let delegateProxy, window.delegate === delegateProxy { return }
        let proxy = StreamWindowDelegateProxy(controller: self, original: window.delegate)
        delegateProxy = proxy
        window.delegate = proxy
    }

    private func restoreWindowDelegate() {
        if let delegateProxy, window?.delegate === delegateProxy {
            window?.delegate = delegateProxy.forwardedDelegate
        }
        delegateProxy = nil
    }

    private func setFullScreenContent(_ enabled: Bool) {
        guard let window else { return }
        if enabled {
            let app = NSApplication.shared
            if presentationBeforeFullScreen == nil { presentationBeforeFullScreen = app.presentationOptions }
            app.presentationOptions = app.presentationOptions.subtracting([.autoHideDock, .autoHideMenuBar, .autoHideToolbar])
                .union([.hideDock, .hideMenuBar])
            if fullSizeContentBeforeFullScreen == nil {
                fullSizeContentBeforeFullScreen = window.styleMask.contains(.fullSizeContentView)
            }
            // Native full-screen content otherwise retains the title-bar inset.
            window.styleMask.insert(.fullSizeContentView)
        } else if let original = fullSizeContentBeforeFullScreen {
            if original { window.styleMask.insert(.fullSizeContentView) }
            else { window.styleMask.remove(.fullSizeContentView) }
            fullSizeContentBeforeFullScreen = nil
        }
        if !enabled, let original = presentationBeforeFullScreen {
            let app = NSApplication.shared
            // AppKit owns the fullScreen bit as native Space transitions complete.
            var restored = original.subtracting(.fullScreen)
                .union(app.presentationOptions.intersection(.fullScreen))
            if !restored.contains(.fullScreen) { restored.remove(.autoHideToolbar) }
            app.presentationOptions = restored
            presentationBeforeFullScreen = nil
        }
    }

    private func finishPreparation(throwing error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        guard let preparation else { return }
        self.preparation = nil
        if let error { preparation.resume(throwing: error) }
        else { preparation.resume() }
    }
}

/// Intercepts only native full-screen negotiation. SwiftUI's delegate continues
/// to receive its other optional callbacks through Objective-C forwarding.
@MainActor private final class StreamWindowDelegateProxy: NSObject, NSWindowDelegate {
    private weak var controller: StreamWindowController?
    // NSObject's selector discovery/forwarding is nonisolated. This weak pointer
    // is set before publication and never reassigned; ARC handles its lifetime.
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    var forwardedDelegate: (any NSWindowDelegate)? { original }

    init(controller: StreamWindowController, original: (any NSWindowDelegate)?) {
        self.controller = controller; self.original = original
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        let originalSize = original?.window?(window, willUseFullScreenContentSize: proposedSize) ?? proposedSize
        guard controller?.overridesFullScreenPresentation(for: window) == true, let screen = window.screen else { return originalSize }
        return screen.frame.size
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        let originalOptions = original?.window?(window, willUseFullScreenPresentationOptions: proposedOptions) ?? proposedOptions
        guard controller?.overridesFullScreenPresentation(for: window) == true else { return originalOptions }
        return originalOptions.subtracting([.autoHideDock, .autoHideMenuBar, .autoHideToolbar]).union([.hideDock, .hideMenuBar])
    }
}

struct StreamWindowReader: NSViewRepresentable {
    let controller: StreamWindowController
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView(); view.controller = controller; return view
    }
    func updateNSView(_ view: WindowView, context: Context) { view.controller = controller }
    @MainActor final class WindowView: NSView {
        weak var controller: StreamWindowController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller?.attach(window)
        }
    }
}

#endif
