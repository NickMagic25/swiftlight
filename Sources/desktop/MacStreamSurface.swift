#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import Metal
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
    let statisticsRows: [StreamStatisticRow]
    let statisticsVisible: Bool
    let statisticsPosition: StreamStatisticsPosition
    let onDisplay: @MainActor (DisplayGeometry, Double) -> Void
    let onError: @MainActor (String) -> Void
    let onCapture: @MainActor (Bool) -> Void
    let onShortcut: @MainActor (StreamShortcutAction) -> Void
    func makeNSView(context: Context) -> MacStreamView {
        let view = MacStreamView(pipeline: pipeline, transport: transport, settings: settings)
        view.onDisplay = onDisplay; view.onError = onError; view.onCapture = onCapture; view.settings = settings
        view.onShortcut = onShortcut
        view.updateStatistics(rows: statisticsRows, visible: statisticsVisible, position: statisticsPosition)
        return view
    }
    func updateNSView(_ view: MacStreamView, context: Context) {
        view.onDisplay = onDisplay; view.onError = onError; view.onCapture = onCapture
        view.onShortcut = onShortcut
        if view.settings != settings { view.settings = settings; view.needsLayout = true }
        view.updateStatistics(rows: statisticsRows, visible: statisticsVisible, position: statisticsPosition)
    }
    static func dismantleNSView(_ view: MacStreamView, coordinator: ()) { view.stop() }
}
/// Dispatch-source additions coalesce; decoded frames stay in the one-slot mailbox.
/// No per-frame main-queue closures or retained video buffers accumulate here.
private final class FramePresentationSignal: @unchecked Sendable {
    private let source: any DispatchSourceUserDataAdd
    init(handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler(handler: handler); source.resume()
    }
    func signal() { source.add(data: 1) }
    func cancel() { source.cancel() }
}
@MainActor final class MacStreamView: NSView, @preconcurrency CAMetalDisplayLinkDelegate {
    private let pipeline: StreamingPipeline
    private let transport: StreamTransport
    private let configuredPacing: VideoPacing
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?
    private var frameSignal: FramePresentationSignal?
    private var renderer: MetalVideoRenderer?
    private var lastFrame: DecodedFrame?
    private var edrMetadataState = HDRMetadataState()
    private var outputColorSpace = VideoOutputColorSpace.linearSRGB
    private var statisticsRows: [StreamStatisticRow] = []
    private var statisticsVisible = false
    private var statisticsPosition: StreamStatisticsPosition = .topLeading
    private var statisticsRasterKey: StatisticsRasterKey?
    private var statisticsRaster: StatisticsOverlayRaster?
    private var statisticsTask: Task<Void, Never>?
    private var statisticsRevision: UInt64 = 0
    private var statisticsAXElements: [String: NSAccessibilityElement] = [:]
    private struct StatisticsRasterKey: Equatable, Sendable {
        let rows: [StreamStatisticRow]
        let position: StreamStatisticsPosition
        let scale: CGFloat
        let width: CGFloat
    }
    private var captured = false
    private var initialCapturePending = true
    private var cursorHidden = false
    private var mouseRemainderX = 0.0
    private var mouseRemainderY = 0.0
    private var needsRedraw = true
    private var resignObserver: NSObjectProtocol?
    private var destination = CGRect.zero
    private var frameObserver: NSObjectProtocol?
    private var localKeyMonitor: Any?
    private var shortcuts = StreamShortcutState()
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
    var onShortcut: ((StreamShortcutAction) -> Void)?
    private var capsLockState = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(pipeline: StreamingPipeline, transport: StreamTransport, settings: StreamSettings) {
        self.pipeline = pipeline; self.transport = transport
        configuredPacing = settings.videoPacing
        self.settings = settings
        super.init(frame: .zero)
        #if DEBUG
        if pipeline.renderOptions.useRootMetalLayer && settings.resolution != .nativeSafeArea {
            // NSView layer hosting requires assigning the layer BEFORE wantsLayer.
            // This experiment uses the full view; safe-area clipping keeps the child layer.
            layer = metalLayer
        }
        #endif
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        do {
            let renderer = try MetalVideoRenderer(captureScheduledCallback: pipeline.renderOptions.captureScheduledCallback); self.renderer = renderer; pipeline.attachRenderer(renderer)
            metalLayer.device = renderer.device; metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.framebufferOnly = true
            metalLayer.maximumDrawableCount = min(3, max(2, settings.maximumDrawableCount))
            metalLayer.displaySyncEnabled = settings.displaySyncEnabled
            metalLayer.isOpaque = true; metalLayer.presentsWithTransaction = false
            #if DEBUG
            if pipeline.renderOptions.showMetalHUD || Self.environmentRequestsMetalHUD {
                metalLayer.developerHUDProperties = ["mode": "main", "MTL_HUD_ENABLED": "1",
                    "MTL_HUD_ELEMENTS": "device,layersize,fps,gputime,presentdelay", "MTL_HUD_ALIGNMENT": "topright"]
            } else { metalLayer.developerHUDProperties = ["mode": "disabled"] }
            #endif
            if layer !== metalLayer { layer?.addSublayer(metalLayer) }
        } catch { DispatchQueue.main.async { [weak self] in self?.onError?(String(describing: error)) } }
    }
    required init?(coder: NSCoder) { fatalError("Use init(pipeline:transport:)") }

    #if DEBUG
    private static var environmentRequestsMetalHUD: Bool {
        guard let value = ProcessInfo.processInfo.environment["MTL_HUD_ENABLED"]?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }
    #endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        frameSignal?.cancel(); frameSignal = nil; pipeline.setFrameAvailableHandler(nil)
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
        if let window {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isKeyWindow, event.window === window else { return false }
                    return self.handleLocalShortcut(event)
                }
                return handled ? nil : event
            }
            previousAcceptsMouseMovedEvents = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            if configuredPacing == .displayLink {
                let link = CAMetalDisplayLink(metalLayer: metalLayer)
                link.delegate = self; link.preferredFrameLatency = 1
                let maxFPS = Float(window.screen?.maximumFramesPerSecond ?? 60)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maxFPS), maximum: maxFPS, preferred: min(Float(settings.framesPerSecond == 0 ? Int(maxFPS) : settings.framesPerSecond), maxFPS))
                link.add(to: .main, forMode: .common); displayLink = link
            } else {
                let signal = FramePresentationSignal { [weak self] in
                    MainActor.assumeIsolated { self?.renderAvailableFrame() }
                }
                frameSignal = signal
                pipeline.setFrameAvailableHandler { signal.signal() }
                signal.signal()
            }
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
        if let link = displayLink {
            let maxFPS = Float(window?.screen?.maximumFramesPerSecond ?? Int(value.0.refreshHz))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maxFPS), maximum: maxFPS,
                preferred: min(Float(settings.framesPerSecond == 0 ? Int(maxFPS) : settings.framesPerSecond), maxFPS))
        }
        let scale = window?.backingScaleFactor ?? 1
        destination = bounds
        if layer !== metalLayer, settings.resolution == .nativeSafeArea, let window {
            let safeWindow = window.convertFromScreen(value.0.safeContent)
            let local = convert(safeWindow, from: nil)
            destination = bounds.intersection(local)
            if destination.isNull { destination = .zero }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AppKit maps the hosted root to the view. Only child layers use the
        // local destination rectangle; assigning it to the root can displace it.
        if layer !== metalLayer { metalLayer.frame = destination }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, destination.width * scale), height: max(1, destination.height * scale))
        CATransaction.commit(); needsRedraw = true
        frameSignal?.signal()
        pipeline.recordPresentationRuntime(PresentationRuntimeDiagnostics(pacing: configuredPacing.rawValue,
            displaySyncEnabled: metalLayer.displaySyncEnabled, maximumDrawableCount: metalLayer.maximumDrawableCount,
            maximumGPUFramesInFlight: 3, displayRefreshHz: value.0.refreshHz,
            preferredFrameLatency: displayLink?.preferredFrameLatency, layerOpaque: metalLayer.isOpaque,
            presentsWithTransaction: metalLayer.presentsWithTransaction,
            nativeFullScreen: window?.styleMask.contains(.fullScreen) == true,
            drawableWidth: Int(metalLayer.drawableSize.width), drawableHeight: Int(metalLayer.drawableSize.height),
            minimumRefreshInterval: window?.screen?.minimumRefreshInterval ?? 0,
            maximumRefreshInterval: window?.screen?.maximumRefreshInterval ?? 0,
            displayUpdateGranularity: window?.screen?.displayUpdateGranularity ?? 0,
            cacheEDRMetadata: pipeline.renderOptions.cacheEDRMetadata,
            metalLayerIsViewRoot: layer === metalLayer, viewOpaque: isOpaque,
            windowOpaque: window?.isOpaque))
        displayChanges.publish(value.0, value.1) { [weak self] geometry, headroom in
            guard let self, self.window != nil else { return }
            self.onDisplay?(geometry, headroom)
        }
        refreshStatisticsOverlay()
        updateStatisticsAccessibility()
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
        if pipeline.renderOptions.useFrameAutoreleasePool {
            autoreleasepool { renderDisplayLinkUpdate(update) }
        } else { renderDisplayLinkUpdate(update) }
    }
    private func renderDisplayLinkUpdate(_ update: CAMetalDisplayLink.Update) {
        let entered = CACurrentMediaTime()
        renderAvailableFrame(into: update.drawable, timing: PresentationSubmissionTiming(
            displayCallbackSeconds: entered, targetDeadlineSeconds: update.targetTimestamp,
            targetPresentationSeconds: update.targetPresentationTimestamp, selectedAtSeconds: CACurrentMediaTime()))
    }
    private func renderAvailableFrame() {
        // Release temporary Metal/drawable references after CPU submission,
        // without waiting for the outer AppKit run loop to drain its pool.
        if pipeline.renderOptions.useFrameAutoreleasePool {
            autoreleasepool { renderAvailableFrameInPool() }
        } else { renderAvailableFrameInPool() }
    }
    private func renderAvailableFrameInPool() {
        guard frameSignal != nil, window != nil else { return }
        if pipeline.renderOptions.cacheEDRMetadata || pipeline.renderOptions.configureEDRBeforeAcquire {
            let incoming = pipeline.takeLatestFrame()
            guard let frame = incoming ?? (needsRedraw ? lastFrame : nil) else { return }
            // EDR configuration belongs to the drawable being acquired, not the one
            // already acquired. Keep a single retained frame if acquisition fails.
            lastFrame = frame; needsRedraw = true
            _ = applyEDRMetadata(frame, force: !pipeline.renderOptions.cacheEDRMetadata)
            let acquireStart = CACurrentMediaTime()
            guard let drawable = metalLayer.nextDrawable() else { return }
            let acquired = CACurrentMediaTime()
            // Acquisition may block. Prefer the newest decoded frame, provided
            // this drawable was acquired with the matching HDR configuration.
            let newest = pipeline.takeLatestFrame() ?? frame
            lastFrame = newest
            if applyEDRMetadata(newest) { frameSignal?.signal(); return }
            renderAvailableFrame(into: drawable, timing: PresentationSubmissionTiming(selectedAtSeconds: CACurrentMediaTime(),
                drawableAcquisitionMilliseconds: (acquired - acquireStart) * 1000), selectedFrame: newest)
            return
        }
        let acquireStart = CACurrentMediaTime()
        // Acquire first, then select the newest output in case obtaining a drawable waited.
        guard let drawable = metalLayer.nextDrawable() else { return }
        let acquired = CACurrentMediaTime()
        renderAvailableFrame(into: drawable, timing: PresentationSubmissionTiming(selectedAtSeconds: acquired,
            drawableAcquisitionMilliseconds: (acquired - acquireStart) * 1000))
    }
    private func renderAvailableFrame(into drawable: any CAMetalDrawable, timing: PresentationSubmissionTiming,
                                      selectedFrame: DecodedFrame? = nil) {
        guard let renderer else { return }
        let incoming = selectedFrame ?? pipeline.takeLatestFrame()
        let selected = selectedFrame == nil ? CACurrentMediaTime() : (timing.selectedAtSeconds ?? CACurrentMediaTime())
        let submission = PresentationSubmissionTiming(displayCallbackSeconds: timing.displayCallbackSeconds,
            targetDeadlineSeconds: timing.targetDeadlineSeconds, targetPresentationSeconds: timing.targetPresentationSeconds,
            selectedAtSeconds: selected, drawableAcquisitionMilliseconds: timing.drawableAcquisitionMilliseconds)
        if let incoming {
            lastFrame = incoming; pipeline.recordFrame(incoming, viewport: metalLayer.drawableSize)
            if initialCapturePending {
                initialCapturePending = false
                if window?.isKeyWindow == true && NSApp.isActive { capture() }
            }
        }
        guard incoming != nil || needsRedraw, let frame = lastFrame else { return }
        if pipeline.renderOptions.cacheEDRMetadata || pipeline.renderOptions.configureEDRBeforeAcquire {
            if applyEDRMetadata(frame) {
                // Display-link drawables are already acquired. After a metadata
                // transition, render this or a newer frame with the next drawable.
                needsRedraw = true; return
            }
        } else { _ = applyEDRMetadata(frame, force: true) }
        do {
            if try renderer.render(frame, into: drawable,
                scaleMode: settings.scaling == .fill ? .fill : settings.scaling == .integer ? .integer : .fit,
                outputColorSpace: outputColorSpace, submissionTiming: submission,
                completion: { [pipeline] result in if !result.succeeded { pipeline.reportRendererFailure() } }) { needsRedraw = false }
        } catch {
            onError?(String(describing: error)); displayLink?.isPaused = true
            frameSignal?.cancel(); frameSignal = nil; pipeline.setFrameAvailableHandler(nil)
        }
    }
    @discardableResult private func applyEDRMetadata(_ frame: DecodedFrame, force: Bool = false) -> Bool {
        let usePQ = pipeline.renderOptions.nativePQOutput && frame.color.transfer == 16 &&
            frame.color.primaries == 9 && frame.color.matrix == 9
        let nextOutput: VideoOutputColorSpace = usePQ ? .rec2020PQ : .linearSRGB
        let outputChanged = nextOutput != outputColorSpace
        let value: HDRMetadataValue = usePQ ? .none : HDRMetadataValue(color: frame.color)
        let metadataChanged = edrMetadataState.update(value)
        let changed = outputChanged || metadataChanged
        guard changed || force else { return false }
        if !force { CATransaction.begin(); CATransaction.setDisableActions(true) }
        if outputChanged {
            outputColorSpace = nextOutput
            metalLayer.pixelFormat = usePQ ? .bgr10a2Unorm : .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: usePQ ? CGColorSpace.itur_2100_PQ : CGColorSpace.extendedLinearSRGB)
        }
        switch value {
        case .none: metalLayer.edrMetadata = nil
        case .hdr10(let mastering, let contentLight):
            metalLayer.edrMetadata = .hdr10(displayInfo: mastering.isEmpty ? nil : mastering,
                contentInfo: contentLight.isEmpty ? nil : contentLight, opticalOutputScale: 203)
        }
        if !force { CATransaction.commit() }
        pipeline.recordEDRMetadataUpdate(nativePQ: usePQ)
        return changed
    }
    func updateStatistics(rows: [StreamStatisticRow], visible: Bool, position: StreamStatisticsPosition) {
        guard rows != statisticsRows || visible != statisticsVisible || position != statisticsPosition else { return }
        let visibilityChanged = visible != statisticsVisible
        statisticsRows = rows; statisticsVisible = visible; statisticsPosition = position
        if !visible {
            guard visibilityChanged else { return }
            statisticsRevision &+= 1; statisticsTask?.cancel(); statisticsTask = nil
            statisticsRasterKey = nil; statisticsRaster = nil
            try? renderer?.setOverlay(nil)
            statisticsAXElements.removeAll(); setAccessibilityChildren([])
            setAccessibilityElement(false)
            if visibilityChanged { needsRedraw = true; frameSignal?.signal() }
            return
        }
        refreshStatisticsOverlay(redraw: visibilityChanged)
    }
    private func refreshStatisticsOverlay(redraw: Bool = false) {
        guard statisticsVisible, window != nil, destination.width > 0 else { return }
        let key = StatisticsRasterKey(rows: statisticsRows, position: statisticsPosition,
            scale: window?.backingScaleFactor ?? 1, width: min(520, max(96, destination.width - 32)))
        guard key != statisticsRasterKey else { return }
        statisticsRasterKey = key; statisticsRevision &+= 1
        let revision = statisticsRevision, size = destination.size
        statisticsTask?.cancel()
        statisticsTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()
                let raster = try StatisticsOverlayRasterizer.render(rows: key.rows, position: key.position,
                    backingScale: key.scale, availableSize: size)
                try Task.checkCancellation()
                await self?.installStatisticsRaster(raster, revision: revision, redraw: redraw)
            } catch is CancellationError { }
            catch { await self?.statisticsRasterFailed(revision: revision, message: String(describing: error)) }
        }
    }
    private func installStatisticsRaster(_ raster: StatisticsOverlayRaster, revision: UInt64, redraw: Bool) {
        guard revision == statisticsRevision, statisticsVisible, window != nil else { return }
        do {
            try renderer?.setOverlay(raster.bitmap)
            statisticsRaster = raster; statisticsTask = nil
            updateStatisticsAccessibility()
            // Values are picked up by the next decoded frame. Only visibility
            // changes request a redraw, avoiding extra presentation work at 4 Hz.
            if redraw { needsRedraw = true; frameSignal?.signal() }
        } catch { statisticsRasterFailed(revision: revision, message: String(describing: error)) }
    }
    private func statisticsRasterFailed(revision: UInt64, message: String) {
        guard revision == statisticsRevision else { return }
        statisticsRasterKey = nil; statisticsTask = nil
        geometryLogger.error("Statistics overlay failed: \(message, privacy: .public)")
    }
    private func updateStatisticsAccessibility() {
        guard statisticsVisible, let raster = statisticsRaster, let window else { return }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Stream Statistics")
        let scale = window.backingScaleFactor
        let bitmap = raster.bitmap
        let targetWidth = Int(metalLayer.drawableSize.width), targetHeight = Int(metalLayer.drawableSize.height)
        let insetX = min(bitmap.insetPixels, max(0, targetWidth - bitmap.width))
        let insetY = min(bitmap.insetPixels, max(0, targetHeight - bitmap.height))
        let pixelX: Int
        switch bitmap.position {
        case .topLeft: pixelX = insetX
        case .topCenter: pixelX = max(0, (targetWidth - bitmap.width) / 2)
        case .topRight: pixelX = max(0, targetWidth - bitmap.width - insetX)
        }
        let x = destination.minX + CGFloat(pixelX) / scale
        let y = destination.minY + CGFloat(insetY) / scale
        let width = CGFloat(bitmap.width) / scale
        let rows = statisticsRows.isEmpty ? [StreamStatisticRow(id: "waiting", label: "Waiting for statistics…", value: "")] : Array(statisticsRows.prefix(24))
        let parentFrame = accessibilityFrame()
        var children: [NSAccessibilityElement] = []
        for (index, row) in rows.enumerated() {
            let element = statisticsAXElements[row.id] ?? NSAccessibilityElement()
            element.setAccessibilityElement(true); element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(row.label); element.setAccessibilityValue(row.value)
            element.setAccessibilityParent(self)
            let local = CGRect(x: x + 12, y: y + 36 + CGFloat(index) * raster.rowHeight,
                width: max(1, width - 24), height: raster.rowHeight)
            let screenFrame = window.convertToScreen(convert(local, to: nil))
            // AX parent coordinates are bottom-left based even for flipped NSViews.
            // Parent-relative frames follow window movement without new layers.
            element.setAccessibilityFrameInParentSpace(screenFrame.offsetBy(dx: -parentFrame.minX, dy: -parentFrame.minY))
            statisticsAXElements[row.id] = element; children.append(element)
        }
        let ids = Set(rows.map(\.id))
        statisticsAXElements = statisticsAXElements.filter { ids.contains($0.key) }
        setAccessibilityChildren(children)
    }
    func stop() {
        statisticsRevision &+= 1; statisticsTask?.cancel(); statisticsTask = nil
        statisticsRaster = nil; statisticsRasterKey = nil; statisticsAXElements.removeAll()
        try? renderer?.setOverlay(nil); setAccessibilityChildren([])
        releaseCapture(); displayLink?.invalidate(); displayLink = nil; lastFrame = nil
        frameSignal?.cancel(); frameSignal = nil; pipeline.setFrameAvailableHandler(nil)
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
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
        shortcuts = StreamShortcutState()
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
        guard captured, let key = KeyMapping.windowsVirtualKey[event.keyCode] else { super.keyDown(with: event); return }
        transport.key(key, pressed: true, modifiers: modifiers(event))
    }
    override func keyUp(with event: NSEvent) {
        guard captured, let key = KeyMapping.windowsVirtualKey[event.keyCode] else { return }
        transport.key(key, pressed: false, modifiers: modifiers(event))
    }
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        // Match the physical Q/S/Z keys used by Moonlight's shortcut defaults;
        // Option changes charactersIgnoringModifiers on many keyboard layouts.
        guard let key = [UInt16(12): "q", 1: "s", 6: "z"][event.keyCode] else { return false }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let decision = event.type == .keyUp ? shortcuts.keyUp(key) :
            shortcuts.keyDown(key, chordMatches: flags == [.control, .option, .shift], isRepeat: event.isARepeat)
        guard case .consume(let action) = decision else { return false }
        if let action {
            // Release held remote inputs before disconnecting. Stats preserve
            // capture so showing the panel never steals focus from the game.
            if action == .disconnect || action == .releaseInput { releaseCapture() }
            onShortcut?(action)
        }
        return true
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

#endif
