import AppKit
import SwiftUI
import QuartzCore
import CoreGraphics
import SwiftlightCore
import SwiftlightVideo
import SwiftlightTransport
import os

@MainActor func geometry(for view: NSView) -> (DisplayGeometry, Double) {
    guard let window = view.window, let screen = window.screen else { return (.fallback, 1) }
    let screenRect = screen.frame
    let insets = screen.safeAreaInsets
    let safe = CGRect(x: screenRect.minX + insets.left, y: screenRect.minY + insets.bottom,
                      width: screenRect.width - insets.left - insets.right, height: screenRect.height - insets.top - insets.bottom)
    let contentView = view.bounds.isEmpty ? window.contentView! : view
    let content = window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    let mode = displayID.flatMap { CGDisplayCopyDisplayMode($0) }
    let pixels = PixelSize(mode?.pixelWidth ?? Int(screenRect.width * screen.backingScaleFactor),
                           mode?.pixelHeight ?? Int(screenRect.height * screen.backingScaleFactor))
    let refresh = mode.map { $0.refreshRate > 0 ? $0.refreshRate : Double(screen.maximumFramesPerSecond) } ?? 60
    return (DisplayGeometry(screen: screenRect, safeScreen: safe, content: content, nativePixels: pixels,
                            backingScale: screen.backingScaleFactor, refreshHz: refresh),
            screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
}
struct DisplayProbe: NSViewRepresentable {
    let onChange: @MainActor (DisplayGeometry, Double) -> Void
    func makeNSView(context: Context) -> ProbeView { let view = ProbeView(); view.onChange = onChange; return view }
    func updateNSView(_ view: ProbeView, context: Context) { view.onChange = onChange; view.publish() }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.stop() }
    @MainActor final class ProbeView: NSView {
        var onChange: ((DisplayGeometry, Double) -> Void)?
        private let displayChanges = DisplayChangePublisher()
        private var windowObservers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            if let window {
                for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                    windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.publish() }
                    })
                }
            }
            publish()
        }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); publish() }
        func publish() {
            guard window != nil else { return }
            let value = geometry(for: self)
            displayChanges.publish(value.0, value.1) { [weak self] geometry, headroom in
                guard let self, self.window != nil else { return }
                self.onChange?(geometry, headroom)
            }
        }
        func stop() {
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers.removeAll()
            displayChanges.clear()
        }
    }
}

/// One pending main-actor publication, deduplicated against the last delivered value.
/// Record delivery before invoking SwiftUI so an identical reentrant layout cannot
/// schedule another graph update. Resize bursts keep only their latest geometry.
@MainActor final class DisplayChangePublisher {
    private struct Value: Equatable { let geometry: DisplayGeometry; let headroom: Double }
    private var last: Value?
    private var pending: Value?
    private var scheduled = false
    func publish(_ geometry: DisplayGeometry, _ headroom: Double,
                 deliver: @escaping @MainActor (DisplayGeometry, Double) -> Void) {
        let value = Value(geometry: geometry, headroom: headroom)
        pending = value
        guard !scheduled else { return }
        guard value != last else { pending = nil; return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let value = self.pending else { return }
            self.pending = nil
            guard value != self.last else { return }
            self.last = value
            deliver(value.geometry, value.headroom)
        }
    }
    func clear() { last = nil; pending = nil }
}

struct StreamSurface: NSViewRepresentable {
    let pipeline: StreamingPipeline
    let transport: StreamTransport
    let settings: StreamSettings
    let onDisplay: @MainActor (DisplayGeometry, Double) -> Void
    let onError: @MainActor (String) -> Void
    let onCapture: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> MacStreamView {
        let view = MacStreamView(pipeline: pipeline, transport: transport)
        view.onDisplay = onDisplay; view.onError = onError; view.onCapture = onCapture; view.settings = settings
        return view
    }
    func updateNSView(_ view: MacStreamView, context: Context) {
        view.onDisplay = onDisplay; view.onError = onError; view.onCapture = onCapture
        if view.settings != settings { view.settings = settings; view.needsLayout = true }
    }
    static func dismantleNSView(_ view: MacStreamView, coordinator: ()) { view.stop() }
}
@MainActor final class MacStreamView: NSView, @preconcurrency CAMetalDisplayLinkDelegate {
    private let pipeline: StreamingPipeline
    private let transport: StreamTransport
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?
    private var renderer: MetalVideoRenderer?
    private var lastFrame: DecodedFrame?
    private var captured = false
    private var initialCapturePending = true
    private var cursorHidden = false
    private var mouseRemainderX = 0.0
    private var mouseRemainderY = 0.0
    private var needsRedraw = true
    private var resignObserver: NSObjectProtocol?
    private var destination = CGRect.zero
    private var frameObserver: NSObjectProtocol?
    private let displayChanges = DisplayChangePublisher()
    private let geometryLogger = Logger(subsystem: "net.edrisil.swiftlight", category: "DisplayGeometry")
    private var geometryLogTask: Task<Void, Never>?
    private var pendingGeometryDiagnostic: String?
    private var lastGeometryDiagnostic: String?
    private var previousAcceptsMouseMovedEvents = false
    var settings = StreamSettings() { didSet { if oldValue.pointerMode != settings.pointerMode { releaseCapture(cancelInitialCapture: false) } } }
    var onDisplay: ((DisplayGeometry, Double) -> Void)?
    var onError: ((String) -> Void)?
    var onCapture: ((Bool) -> Void)?
    private var capsLockState = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(pipeline: StreamingPipeline, transport: StreamTransport) {
        self.pipeline = pipeline; self.transport = transport
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        do {
            let renderer = try MetalVideoRenderer(); self.renderer = renderer; pipeline.attachRenderer(renderer)
            metalLayer.device = renderer.device; metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.framebufferOnly = true; metalLayer.maximumDrawableCount = 3
            layer?.addSublayer(metalLayer)
        } catch { DispatchQueue.main.async { [weak self] in self?.onError?(String(describing: error)) } }
    }
    required init?(coder: NSCoder) { fatalError("Use init(pipeline:transport:)") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        if let window {
            previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self; link.preferredFrameLatency = 1
            let maxFPS = Float(window.screen?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maxFPS), maximum: maxFPS, preferred: min(Float(settings.framesPerSecond == 0 ? Int(maxFPS) : settings.framesPerSecond), maxFPS))
            link.add(to: .main, forMode: .common); displayLink = link
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseCapture() }
            }
            frameObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            }
            ControllerHub.shared.start(transport: transport)
        } else { stop() }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func layout() {
        super.layout()
        let value = geometry(for: self)
        let scale = window?.backingScaleFactor ?? 1
        destination = bounds
        if settings.resolution == .nativeSafeArea, let window {
            let safeWindow = window.convertFromScreen(value.0.safeContent)
            let local = convert(safeWindow, from: nil)
            destination = bounds.intersection(local)
            if destination.isNull { destination = .zero }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.frame = destination; metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, destination.width * scale), height: max(1, destination.height * scale))
        CATransaction.commit(); needsRedraw = true
        displayChanges.publish(value.0, value.1) { [weak self] geometry, headroom in
            guard let self, self.window != nil else { return }
            self.onDisplay?(geometry, headroom)
        }
        recordGeometryDiagnostic()
    }
    /// Diagnostic numbers only. Coalesce resize/animation bursts and publish at most
    /// four changed snapshots per second; never feed geometry back into SwiftUI.
    private func recordGeometryDiagnostic() {
        func rect(_ value: CGRect?) -> String {
            guard let value else { return "none" }
            return String(format: "(%.2f,%.2f %.2fx%.2f)", value.origin.x, value.origin.y, value.width, value.height)
        }
        func insets(_ value: NSEdgeInsets?) -> String {
            guard let value else { return "none" }
            return String(format: "(t%.2f l%.2f b%.2f r%.2f)", value.top, value.left, value.bottom, value.right)
        }
        let diagnostic = "fullScreen=\(window?.styleMask.contains(.fullScreen) == true ? 1 : 0) " +
            "fullSizeContent=\(window?.styleMask.contains(.fullSizeContentView) == true ? 1 : 0) " +
            "scale=\(window?.backingScaleFactor ?? 1) screen=\(rect(window?.screen?.frame)) " +
            "window=\(rect(window?.frame)) content=\(rect(window?.contentView?.bounds)) " +
            "contentLayout=\(rect(window?.contentLayoutRect)) viewFrame=\(rect(frame)) viewBounds=\(rect(bounds)) " +
            "viewSafe=\(insets(safeAreaInsets)) screenSafe=\(insets(window?.screen?.safeAreaInsets)) " +
            "layer=\(rect(metalLayer.frame)) drawable=\(Int(metalLayer.drawableSize.width))x\(Int(metalLayer.drawableSize.height))"
        pendingGeometryDiagnostic = diagnostic
        guard geometryLogTask == nil else { return }
        guard diagnostic != lastGeometryDiagnostic else { pendingGeometryDiagnostic = nil; return }
        geometryLogTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.geometryLogTask = nil
            guard let diagnostic = self.pendingGeometryDiagnostic else { return }
            self.pendingGeometryDiagnostic = nil
            guard diagnostic != self.lastGeometryDiagnostic else { return }
            self.lastGeometryDiagnostic = diagnostic
            self.geometryLogger.info("\(diagnostic, privacy: .public)")
        }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let renderer else { return }
        let incoming = pipeline.takeLatestFrame()
        if let incoming {
            lastFrame = incoming; pipeline.recordFrame(incoming, viewport: metalLayer.drawableSize)
            if initialCapturePending {
                initialCapturePending = false
                if window?.isKeyWindow == true && NSApp.isActive { capture() }
            }
        }
        guard incoming != nil || needsRedraw, let frame = lastFrame else { return }
        // targetTimestamp is a submission deadline. It is not recorded as actual presentation.
        // Use only the update's drawable; renderer records MTLDrawable.presentedTime when available.
        if frame.color.transfer == 16 {
            metalLayer.edrMetadata = .hdr10(displayInfo: frame.color.mastering.isEmpty ? nil : Data(frame.color.mastering),
                contentInfo: frame.color.contentLight.isEmpty ? nil : Data(frame.color.contentLight), opticalOutputScale: 203)
        } else { metalLayer.edrMetadata = nil }
        do {
            if try renderer.render(frame, into: update.drawable,
                scaleMode: settings.scaling == .fill ? .fill : settings.scaling == .integer ? .integer : .fit,
                completion: { [pipeline] result in if !result.succeeded { pipeline.reportRendererFailure() } }) { needsRedraw = false }
        } catch { onError?(String(describing: error)); link.isPaused = true }
    }
    func stop() {
        releaseCapture(); displayLink?.invalidate(); displayLink = nil; lastFrame = nil
        displayChanges.clear()
        geometryLogTask?.cancel(); geometryLogTask = nil; pendingGeometryDiagnostic = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver); self.frameObserver = nil }
        ControllerHub.shared.stop()
        window?.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
    }
    private func capture() {
        guard !captured else { return }; captured = true
        initialCapturePending = false
        capsLockState = NSEvent.modifierFlags.contains(.capsLock)
        DispatchQueue.main.async { [weak self] in self?.onCapture?(true) }
        window?.makeFirstResponder(self)
        ControllerHub.shared.start(transport: transport)
        if settings.pointerMode == .relative { CGAssociateMouseAndMouseCursorPosition(0); NSCursor.hide(); cursorHidden = true }
    }
    func releaseCapture(cancelInitialCapture: Bool = true) {
        if cancelInitialCapture { initialCapturePending = false }
        ControllerHub.shared.stop(); transport.releaseAllInputs()
        guard captured else { return }; captured = false
        DispatchQueue.main.async { [weak self] in self?.onCapture?(false) }
        if cursorHidden { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide(); cursorHidden = false }
        mouseRemainderX = 0; mouseRemainderY = 0
    }
    override func resignFirstResponder() -> Bool { releaseCapture(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard captured else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        let escapeModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
        if event.keyCode == 12 && event.modifierFlags.intersection(escapeModifiers) == escapeModifiers { releaseCapture(); return }
        guard captured, let key = KeyMapping.windowsVirtualKey[event.keyCode] else { super.keyDown(with: event); return }
        transport.key(key, pressed: true, modifiers: modifiers(event))
    }
    override func keyUp(with event: NSEvent) {
        guard captured, let key = KeyMapping.windowsVirtualKey[event.keyCode] else { return }
        transport.key(key, pressed: false, modifiers: modifiers(event))
    }
    override func flagsChanged(with event: NSEvent) {
        guard captured else { return }
        if event.keyCode == 57 {
            let enabled = event.modifierFlags.contains(.capsLock)
            if capsLockState != enabled {
                capsLockState = enabled
                transport.key(0x14, pressed: true, modifiers: modifiers(event))
                transport.key(0x14, pressed: false, modifiers: modifiers(event))
            }
            return
        }
        // Public IOKit/hidsystem/IOLLEvent.h device-specific masks distinguish
        // both sides even while the other side keeps the aggregate modifier set.
        let mapping: [UInt16: (UInt16, UInt)] = [56:(0xA0,0x2),60:(0xA1,0x4),59:(0xA2,0x1),62:(0xA3,0x2000),
            58:(0xA4,0x20),61:(0xA5,0x40),55:(0x5B,0x8),54:(0x5C,0x10)]
        if let (key, mask) = mapping[event.keyCode] {
            transport.key(key, pressed: event.modifierFlags.rawValue & mask != 0, modifiers: modifiers(event))
        }
    }
    private func modifiers(_ event: NSEvent) -> UInt8 {
        var flags: UInt8 = 0
        if event.modifierFlags.contains(.shift) { flags |= 1 }; if event.modifierFlags.contains(.control) { flags |= 2 }
        if event.modifierFlags.contains(.option) { flags |= 4 }; if event.modifierFlags.contains(.command) { flags |= 8 }; return flags
    }
    override func mouseDown(with event: NSEvent) { if !captured { capture(); if settings.pointerMode == .relative { return } }; if position(event) { transport.mouseButton(1, pressed: true) } }
    override func mouseUp(with event: NSEvent) { if captured { transport.mouseButton(1, pressed: false) } }
    override func rightMouseDown(with event: NSEvent) { if captured && position(event) { transport.mouseButton(3, pressed: true) } }
    override func rightMouseUp(with event: NSEvent) { if captured { transport.mouseButton(3, pressed: false) } }
    override func otherMouseDown(with event: NSEvent) { if captured && position(event) { transport.mouseButton(event.buttonNumber == 2 ? 2 : min(5, event.buttonNumber + 1), pressed: true) } }
    override func otherMouseUp(with event: NSEvent) { if captured { transport.mouseButton(event.buttonNumber == 2 ? 2 : min(5, event.buttonNumber + 1), pressed: false) } }
    /// Uses the same clean aperture/fit/fill viewport as the Metal renderer.
    private func position(_ event: NSEvent) -> Bool {
        guard settings.pointerMode == .absolute else { return true }
        guard let frame = lastFrame else { return false }
        let transform = ViewportTransform(source: frame.contentRect.size, destination: destination, scaling: settings.scaling)
        guard let point = transform.videoPoint(convert(event.locationInWindow, from: nil)) else { return false }
        transport.mousePosition(x: Int16(clamping: Int(point.x)), y: Int16(clamping: Int(point.y)),
            width: Int16(clamping: Int(frame.contentRect.width)), height: Int16(clamping: Int(frame.contentRect.height)))
        return true
    }
    override func mouseMoved(with event: NSEvent) {
        guard captured else { return }
        if settings.pointerMode == .absolute { _ = position(event) }
        else {
            mouseRemainderX += event.deltaX; mouseRemainderY += event.deltaY
            let dx = Int16(clamping: Int(mouseRemainderX.rounded())), dy = Int16(clamping: Int(mouseRemainderY.rounded()))
            mouseRemainderX -= Double(dx); mouseRemainderY -= Double(dy)
            if dx != 0 || dy != 0 { transport.mouseMove(dx: dx, dy: dy) }
        }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func scrollWheel(with event: NSEvent) {
        if captured { transport.scroll(vertical: Int16(clamping: Int((event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 120)).rounded())),
            horizontal: Int16(clamping: Int((event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 120)).rounded()))) }
    }
}
