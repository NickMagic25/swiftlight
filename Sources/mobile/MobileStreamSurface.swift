#if os(iOS)
import Metal
import QuartzCore
import SwiftUI
import SwiftlightCore
import SwiftlightTransport
import SwiftlightVideo
import UIKit

struct MobileStreamScreen: View {
    @ObservedObject var session: MobileStreamingSession
    var body: some View {
        ZStack {
            Color.black
            if let pipeline = session.pipeline, let transport = session.transport {
                MobileStreamSurface(pipeline: pipeline, transport: transport, settings: session.settings, inputEnabled: session.inputEnabled,
                    statisticsRows: session.statisticsRows, statisticsVisible: session.showingStatistics,
                    statisticsPosition: session.statisticsPreferences.position,
                    toggleStatistics: session.toggleStatistics,
                    disconnect: { Task { await session.disconnect() } },
                    controls: { session.releaseInputs(); session.setControlsVisible(true) })
            }
            // Keep connection feedback and cancellation available through the
            // wait for the first decoded frame. Remove it once streaming starts.
            if !session.hasVideo {
                VStack(spacing: 20) {
                    ProgressView(session.status).tint(.white)
                    Button("Cancel") { Task { await session.disconnect() } }.buttonStyle(.borderedProminent)
                }.foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .interactiveDismissDisabled()
        .sheet(isPresented: Binding(get: { session.controlsVisible }, set: { session.setControlsVisible($0) })) {
            NavigationStack {
                Form {
                    Section {
                        Text("Touch the video to move the pointer. Tap to click, or use a connected game controller.")
                        Text("Tap with three fingers to show or hide statistics. Hold three fingers to open these controls.")
                        Text("Swipe one finger from the left edge to the middle of the screen to disconnect.")
                    }
                    Section("Stream Statistics") {
                        Toggle("Show statistics", isOn: Binding(get: { session.showingStatistics }, set: { visible in
                            session.setStatisticsVisible(visible)
                        }))
                            .accessibilityIdentifier("inStreamStatistics")
                        Picker("Detail", selection: Binding(get: { session.statisticsPreferences.detail }, set: { detail in
                            var preferences = session.statisticsPreferences; preferences.detail = detail
                            session.setStatisticsPreferences(preferences)
                        })) {
                            ForEach(StreamStatisticsDetail.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    if session.settings.effectiveAudioOutput == .systemSpatial {
                        Section {
                            LabeledContent("Spatial playback", value: session.spatialPlaybackAvailable.map {
                                $0 ? "Available on this output" : "Unavailable or turned off"
                            } ?? "Checking output")
                            .accessibilityIdentifier("spatialPlaybackAvailability")
                        } header: {
                            Text("Audio")
                        } footer: {
                            Text("Use Control Center to choose available Spatial Audio and head tracking options.")
                        }
                    }
                    Section {
                        Button("Disconnect", role: .destructive) {
                            session.setControlsVisible(false)
                            Task { await session.disconnect() }
                        }
                        .accessibilityIdentifier("disconnectStream")
                    } footer: { Text("Disconnecting leaves the application running on your computer.") }
                }
                .navigationTitle("Stream Controls")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { session.setControlsVisible(false) } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
}

private struct MobileStreamSurface: UIViewRepresentable {
    let pipeline: StreamingPipeline
    let transport: StreamTransport
    let settings: StreamSettings
    let inputEnabled: Bool
    let statisticsRows: [StreamStatisticRow]
    let statisticsVisible: Bool
    let statisticsPosition: StreamStatisticsPosition
    let toggleStatistics: () -> Void
    let disconnect: () -> Void
    let controls: () -> Void
    func makeUIView(context: Context) -> MobileStreamView {
        MobileStreamView(pipeline: pipeline, transport: transport, settings: settings,
                         toggleStatistics: toggleStatistics, disconnect: disconnect, controls: controls)
    }
    func updateUIView(_ view: MobileStreamView, context: Context) {
        view.inputEnabled = inputEnabled
        view.updateStatistics(rows: statisticsRows, visible: statisticsVisible, position: statisticsPosition)
        view.refreshPresentationDiagnostics()
    }
    static func dismantleUIView(_ view: MobileStreamView, coordinator: ()) { view.stop() }
}

/// A dispatch source coalesces callback wakeups. It owns no decoded frames and
/// never accumulates one main-queue closure per decoder callback.
private final class MobileFrameSignal: @unchecked Sendable {
    private let source: any DispatchSourceUserDataAdd
    init(_ handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeUserDataAddSource(queue: .main)
        source.setEventHandler(handler: handler); source.resume()
    }
    func signal() { source.add(data: 1) }
    func cancel() { source.cancel() }
}

@MainActor private final class MobileStreamAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

@MainActor private final class MobileStreamView: UIView, @preconcurrency CAMetalDisplayLinkDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let pipeline: StreamingPipeline
    private let transport: StreamTransport
    private let settings: StreamSettings
    private let controls: () -> Void
    private let toggleStatistics: () -> Void
    private let disconnect: () -> Void
    private var renderer: MetalVideoRenderer?
    private var displayLink: CAMetalDisplayLink?
    private var signal: MobileFrameSignal?
    private var lastFrame: DecodedFrame?
    private var hdrLayerState = MobileHDRLayerState()
    private var hierarchyCapture = MobilePresentationHierarchyCapture()
    private var recordedHierarchyTime: Double?
    private var redraw = false
    private var lastTouch: CGPoint?
    private var stopped = false
    private var keyboardFocusTask: Task<Void, Never>?
    private var keyboardFocusPending = false
    private var keyboardFocusRevision: UInt64 = 0
    private lazy var streamKeyCommands: [UIKeyCommand] = {
        let controls = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: .command,
                                    action: #selector(openControlsFromKeyboard(_:)))
        controls.discoverabilityTitle = "Stream Controls"
        controls.wantsPriorityOverSystemBehavior = true
        let statistics = UIKeyCommand(input: "s", modifierFlags: [.control, .alternate, .shift],
                                      action: #selector(toggleStatisticsFromKeyboard(_:)))
        statistics.discoverabilityTitle = "Show or Hide Statistics"
        statistics.wantsPriorityOverSystemBehavior = true
        return [controls, statistics]
    }()
    private var statisticsRows: [StreamStatisticRow] = []
    private var statisticsVisible = false
    private var statisticsPosition: StreamStatisticsPosition = .top
    private var statisticsTask: Task<Void, Never>?
    private var statisticsRevision: UInt64 = 0
    private var statisticsRasterKey: StatisticsRasterKey?
    private var statisticsRedrawPending = false
    private var installedStatistics: InstalledStatistics?
    private var statisticsAccessibilityRows: [String: UIAccessibilityElement] = [:]
    private var accessibilityStatisticsVisible: Bool?
    private lazy var streamAccessibilityElement: MobileStreamAccessibilityElement = {
        let element = MobileStreamAccessibilityElement(accessibilityContainer: self)
        element.accessibilityLabel = "Game stream"
        element.accessibilityIdentifier = "streamSurface"
        element.accessibilityHint = "Use the Statistics, Disconnect, or Stream Controls actions."
        element.activate = { [weak self] in self?.showControls() ?? false }
        return element
    }()
    private lazy var statisticsAccessibilityHeader: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityIdentifier = "streamStatistics"
        element.accessibilityTraits = [.header, .staticText]
        return element
    }()
    private struct InstalledStatistics {
        let bitmap: VideoOverlayBitmap
        let raster: StatisticsOverlayRaster
        let key: StatisticsRasterKey
    }
    private struct StatisticsRasterKey: Equatable, Sendable {
        let rows: [StreamStatisticRow]
        let position: StreamStatisticsPosition
        let scale: CGFloat
        let fontScale: CGFloat
        let size: CGSize
        let inset: CGFloat
        let maximumRows: Int
    }
    var inputEnabled = false {
        didSet {
            guard inputEnabled != oldValue else { return }
            if inputEnabled { requestKeyboardFocus() }
            else {
                transport.releaseAllInputs(); lastTouch = nil
                cancelKeyboardFocus()
            }
        }
    }
    private var acceptsStreamCommands: Bool {
        !stopped && inputEnabled && window?.isKeyWindow == true &&
            window?.windowScene?.activationState == .foregroundActive
    }
    override var canBecomeFirstResponder: Bool { acceptsStreamCommands }
    override var keyCommands: [UIKeyCommand]? { acceptsStreamCommands ? streamKeyCommands : nil }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(openControlsFromKeyboard(_:)) || action == #selector(toggleStatisticsFromKeyboard(_:)) {
            return acceptsStreamCommands
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    init(pipeline: StreamingPipeline, transport: StreamTransport, settings: StreamSettings,
         toggleStatistics: @escaping () -> Void, disconnect: @escaping () -> Void, controls: @escaping () -> Void) {
        self.pipeline = pipeline; self.transport = transport; self.settings = settings; self.controls = controls
        self.toggleStatistics = toggleStatistics; self.disconnect = disconnect
        super.init(frame: .zero)
        backgroundColor = .black; isOpaque = true; isMultipleTouchEnabled = true
        isAccessibilityElement = false
        updateStatisticsAccessibility()
        let controlsHold = UILongPressGestureRecognizer(target: self, action: #selector(holdControls(_:)))
        controlsHold.numberOfTouchesRequired = 3; addGestureRecognizer(controlsHold)
        let statisticsTap = UITapGestureRecognizer(target: self, action: #selector(toggleStatisticsAction))
        statisticsTap.numberOfTouchesRequired = 3
        statisticsTap.require(toFail: controlsHold); addGestureRecognizer(statisticsTap)
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(disconnectFromEdge(_:)))
        edge.edges = .left; edge.maximumNumberOfTouches = 1; addGestureRecognizer(edge)
        let tap = UITapGestureRecognizer(target: self, action: #selector(clickPointer(_:)))
        tap.require(toFail: statisticsTap); tap.require(toFail: controlsHold); tap.require(toFail: edge)
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(movePointer(_:)))
        pan.maximumNumberOfTouches = 1; pan.require(toFail: edge); addGestureRecognizer(pan)
        do {
            let renderer = try MetalVideoRenderer()
            self.renderer = renderer; pipeline.attachRenderer(renderer)
            metalLayer.device = renderer.device; metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.framebufferOnly = true; metalLayer.isOpaque = true
            metalLayer.maximumDrawableCount = settings.maximumDrawableCount
            metalLayer.presentsWithTransaction = false
        } catch { pipeline.reportRendererFailure() }
        #if DEBUG
        pipeline.refreshPresentationDiagnostics = { [weak self] in self?.refreshPresentationDiagnostics() }
        #endif
    }
    required init?(coder: NSCoder) { fatalError("Use the streaming initializer") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !stopped else { return }
        guard window != nil else { suspendPresentation(); return }
        updateDrawableGeometry()
        requestKeyboardFocus()
        guard displayLink == nil, signal == nil else {
            updateDisplayLinkFrameRate()
            recordPresentationRuntime()
            return
        }
        if settings.videoPacing == .displayLink {
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self; link.preferredFrameLatency = 1
            link.add(to: .main, forMode: .common); displayLink = link
        } else {
            let signal = MobileFrameSignal { [weak self] in MainActor.assumeIsolated { self?.renderImmediate() } }
            self.signal = signal; pipeline.setFrameAvailableHandler { signal.signal() }; signal.signal()
        }
        updateDisplayLinkFrameRate()
        recordPresentationRuntime()
        refreshStatisticsOverlay(redrawOnInstall: true)
        updateStatisticsAccessibility()
    }
    private func requestKeyboardFocus() {
        guard acceptsStreamCommands, !keyboardFocusPending else { return }
        keyboardFocusPending = true
        let revision = keyboardFocusRevision
        keyboardFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, revision == self.keyboardFocusRevision else { return }
            self.keyboardFocusTask = nil
            self.restoreKeyboardFocus(afterTransition: revision)
        }
    }
    private func restoreKeyboardFocus(afterTransition revision: UInt64) {
        guard revision == keyboardFocusRevision else { return }
        guard acceptsStreamCommands else { keyboardFocusPending = false; return }
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        let controller = responder as? UIViewController
        let transition = controller?.presentedViewController?.transitionCoordinator ?? controller?.transitionCoordinator
        // A sheet can replace the responder during its dismissal animation.
        // Restore after that transition, without polling or a fixed delay.
        if let transition, transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishKeyboardFocus(revision: revision) }
        }) { return }
        finishKeyboardFocus(revision: revision)
    }
    private func finishKeyboardFocus(revision: UInt64) {
        guard revision == keyboardFocusRevision else { return }
        keyboardFocusPending = false
        guard acceptsStreamCommands else { return }
        becomeFirstResponder()
    }
    private func cancelKeyboardFocus() {
        keyboardFocusRevision &+= 1
        keyboardFocusTask?.cancel(); keyboardFocusTask = nil; keyboardFocusPending = false
        if isFirstResponder { resignFirstResponder() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableGeometry()
        updateDisplayLinkFrameRate()
        refreshStatisticsOverlay()
        updateStatisticsAccessibility()
        recordPresentationRuntime()
    }
    @discardableResult private func updateDrawableGeometry() -> Bool {
        guard let screen = window?.windowScene?.screen,
              let size = NativeDrawableGeometry.size(viewSize: bounds.size, screenSize: screen.bounds.size,
                  nativeSize: screen.nativeBounds.size, nativeScale: screen.nativeScale) else { return false }
        // UIKit's logical display scale can render above the panel resolution in
        // scaled display modes. A Metal surface must use the owning screen's
        // native scale and exact full-screen pixel size to avoid downsampling.
        let scale = screen.nativeScale
        let changed = contentScaleFactor != scale || metalLayer.contentsScale != scale || metalLayer.drawableSize != size
        guard changed else { return false }
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        redraw = true; signal?.signal(); transport.releaseAllInputs()
        refreshStatisticsOverlay()
        updateStatisticsAccessibility()
        recordPresentationRuntime()
        return true
    }
    private func updateDisplayLinkFrameRate() {
        guard let displayLink, let screen = window?.windowScene?.screen else { return }
        let maximum = Float(screen.maximumFramesPerSecond)
        let next = CAFrameRateRange(minimum: min(30, maximum), maximum: maximum,
            preferred: min(Float(settings.framesPerSecond == 0 ? Int(maximum) : settings.framesPerSecond), maximum))
        let current = displayLink.preferredFrameRateRange
        guard current.minimum != next.minimum || current.maximum != next.maximum || current.preferred != next.preferred else { return }
        displayLink.preferredFrameRateRange = next
    }
    /// Reuse low-rate UI updates and explicit capture checkpoints. Hidden
    /// statistics stop UI publication, so checkpoints also refresh the snapshot.
    func refreshPresentationDiagnostics() {
        #if DEBUG
        guard !stopped, let hierarchy = hierarchyCapture.capture(from: self),
              hierarchy.capturedAtMediaTimeSeconds != recordedHierarchyTime else { return }
        recordPresentationRuntime()
        #endif
    }
    private func recordPresentationRuntime() {
        let range = displayLink?.preferredFrameRateRange
        let hdr = MobileHDRDisplayCapabilities.capture(from: window)
        let screen = window?.windowScene?.screen
        let hierarchy = hierarchyCapture.capture(from: self)
        recordedHierarchyTime = hierarchy?.capturedAtMediaTimeSeconds
        pipeline.recordPresentationRuntime(PresentationRuntimeDiagnostics(
            pacing: settings.videoPacing.rawValue, displaySyncEnabled: nil,
            maximumDrawableCount: metalLayer.maximumDrawableCount, maximumGPUFramesInFlight: 3,
            displayRefreshHz: nil, preferredFrameLatency: displayLink?.preferredFrameLatency,
            layerOpaque: metalLayer.isOpaque, presentsWithTransaction: metalLayer.presentsWithTransaction,
            nativeFullScreen: window.map { $0.bounds.size == $0.windowScene?.screen.bounds.size } ?? false,
            drawableWidth: Int(metalLayer.drawableSize.width), drawableHeight: Int(metalLayer.drawableSize.height),
            minimumRefreshInterval: nil, maximumRefreshInterval: nil, displayUpdateGranularity: nil,
            cacheEDRMetadata: true, metalLayerIsViewRoot: true, viewOpaque: isOpaque, windowOpaque: window?.isOpaque,
            displaySyncControlSupported: false,
            displayMaximumFramesPerSecond: window?.windowScene?.screen.maximumFramesPerSecond,
            preferredFrameRateMinimum: range?.minimum, preferredFrameRateMaximum: range?.maximum,
            preferredFrameRatePreferred: range?.preferred,
            wantsExtendedDynamicRangeContent: metalLayer.wantsExtendedDynamicRangeContent,
            edrMetadataConfigured: metalLayer.edrMetadata != nil,
            displayPotentialEDRHeadroom: hdr.potentialHeadroom,
            displayCurrentEDRHeadroom: hdr.currentHeadroom,
            viewWidthPoints: Double(bounds.width), viewHeightPoints: Double(bounds.height),
            viewContentScale: Double(contentScaleFactor), layerContentsScale: Double(metalLayer.contentsScale),
            screenWidthPoints: screen.map { Double($0.bounds.width) },
            screenHeightPoints: screen.map { Double($0.bounds.height) },
            screenScale: screen.map { Double($0.scale) }, screenNativeScale: screen.map { Double($0.nativeScale) },
            screenNativeWidthPixels: screen.map { Int($0.nativeBounds.width) },
            screenNativeHeightPixels: screen.map { Int($0.nativeBounds.height) },
            presentationHierarchy: hierarchy))
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        if pipeline.renderOptions.useFrameAutoreleasePool {
            autoreleasepool { renderDisplayLinkUpdate(link, update: update) }
        } else { renderDisplayLinkUpdate(link, update: update) }
    }
    private func renderDisplayLinkUpdate(_ link: CAMetalDisplayLink, update: CAMetalDisplayLink.Update) {
        guard displayLink === link, window != nil else { return }
        // This drawable was acquired before the callback. If the display changed,
        // render the next drawable with its new native dimensions instead.
        guard !updateDrawableGeometry() else { return }
        // Layout may already have applied the new size after this drawable was
        // acquired. Validate the supplied texture as well as the layer state.
        guard update.drawable.texture.width == Int(metalLayer.drawableSize.width),
              update.drawable.texture.height == Int(metalLayer.drawableSize.height),
              update.drawable.texture.pixelFormat == metalLayer.pixelFormat else { return }
        render(into: update.drawable, timing: .init(displayCallbackSeconds: CACurrentMediaTime(),
            targetDeadlineSeconds: update.targetTimestamp, targetPresentationSeconds: update.targetPresentationTimestamp))
    }
    private func renderImmediate() {
        // Bound temporary drawable lifetimes to this submission instead of the
        // outer UIKit run-loop pool. GPU TextureLease ownership is independent.
        if pipeline.renderOptions.useFrameAutoreleasePool {
            autoreleasepool { renderImmediateFrame() }
        } else { renderImmediateFrame() }
    }
    private func renderImmediateFrame() {
        guard !stopped, signal != nil, renderer != nil, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        updateDrawableGeometry()
        let incoming = pipeline.takeLatestFrame()
        guard let frame = incoming ?? (redraw ? lastFrame : nil) else { return }
        // Metadata applies to the next drawable. Retain one frame for a later
        // wakeup if acquisition fails; never queue decoded frames on the UI actor.
        lastFrame = frame; redraw = true
        do {
            _ = try applyHDRMetadata(frame)
            let began = CACurrentMediaTime()
            guard let drawable = metalLayer.nextDrawable() else { return }
            let acquired = CACurrentMediaTime()
            // Acquisition may block. Select the newest output, but discard this
            // drawable if that output needs a different EDR configuration.
            let newest = pipeline.takeLatestFrame() ?? frame
            let selected = CACurrentMediaTime()
            lastFrame = newest
            if try applyHDRMetadata(newest) { signal?.signal(); return }
            render(into: drawable, timing: .init(selectedAtSeconds: selected,
                drawableAcquisitionMilliseconds: (acquired - began) * 1000), selectedFrame: newest)
        } catch { pipeline.reportRendererFailure() }
    }
    private func render(into drawable: any CAMetalDrawable, timing: PresentationSubmissionTiming,
                        selectedFrame: DecodedFrame? = nil) {
        guard !stopped, let renderer else { return }
        let incoming = selectedFrame ?? pipeline.takeLatestFrame()
        let selected = selectedFrame == nil ? CACurrentMediaTime() : (timing.selectedAtSeconds ?? CACurrentMediaTime())
        if let incoming { lastFrame = incoming; pipeline.recordFrame(incoming, viewport: metalLayer.drawableSize) }
        guard incoming != nil || redraw, let frame = lastFrame else { return }
        redraw = true
        do {
            if try applyHDRMetadata(frame) {
                // CAMetalDisplayLink supplies an already acquired drawable. A
                // metadata transition takes effect on the next display update.
                signal?.signal(); return
            }
            let submission = PresentationSubmissionTiming(displayCallbackSeconds: timing.displayCallbackSeconds,
                targetDeadlineSeconds: timing.targetDeadlineSeconds, targetPresentationSeconds: timing.targetPresentationSeconds,
                selectedAtSeconds: selected, drawableAcquisitionMilliseconds: timing.drawableAcquisitionMilliseconds)
            if try renderer.render(frame, into: drawable,
                scaleMode: settings.scaling == .fill ? .fill : settings.scaling == .integer ? .integer : .fit,
                outputColorSpace: hdrLayerState.outputColorSpace,
                submissionTiming: submission, completion: { [pipeline] result in
                    if !result.succeeded { pipeline.reportRendererFailure() }
                }) { redraw = false }
        } catch { pipeline.reportRendererFailure() }
    }
    @discardableResult private func applyHDRMetadata(_ frame: DecodedFrame) throws -> Bool {
        guard try hdrLayerState.apply(color: frame.color, to: metalLayer,
                                     nativePQOutput: pipeline.renderOptions.nativePQOutput) else { return false }
        pipeline.recordEDRMetadataUpdate(nativePQ: hdrLayerState.outputColorSpace == .rec2020PQ)
        recordPresentationRuntime()
        return true
    }
    @objc private func openControlsFromKeyboard(_ command: UIKeyCommand) {
        guard acceptsStreamCommands else { return }
        _ = showControls()
    }
    @objc private func toggleStatisticsFromKeyboard(_ command: UIKeyCommand) {
        guard acceptsStreamCommands else { return }
        _ = toggleStatisticsAction()
    }
    @objc private func showControls() -> Bool {
        guard acceptsStreamCommands else { return false }
        transport.releaseAllInputs(); lastTouch = nil; controls(); return true
    }
    override func accessibilityActivate() -> Bool { showControls() }
    @objc private func holdControls(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { _ = showControls() }
    }
    @objc private func toggleStatisticsAction() -> Bool {
        guard acceptsStreamCommands else { return false }
        transport.releaseAllInputs(); lastTouch = nil; toggleStatistics(); requestKeyboardFocus(); return true
    }
    @objc private func disconnectAction() -> Bool {
        guard acceptsStreamCommands else { return false }
        transport.releaseAllInputs(); lastTouch = nil; disconnect(); return true
    }
    @objc private func disconnectFromEdge(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .began { transport.releaseAllInputs(); lastTouch = nil }
        if gesture.state == .ended, gesture.translation(in: self).x >= bounds.width * 0.45 {
            _ = disconnectAction()
        }
    }
    @objc private func clickPointer(_ gesture: UITapGestureRecognizer) {
        guard inputEnabled else { return }
        if settings.pointerMode == .absolute, !positionPointer(at: gesture.location(in: self)) { return }
        transport.mouseButton(1, pressed: true); transport.mouseButton(1, pressed: false)
    }
    @objc private func movePointer(_ gesture: UIPanGestureRecognizer) {
        guard inputEnabled else { return }
        let point = gesture.location(in: self)
        if settings.pointerMode == .absolute { _ = positionPointer(at: point) }
        else if gesture.state == .changed, let previous = lastTouch {
            transport.mouseMove(dx: Int16(clamping: Int((point.x - previous.x).rounded())),
                dy: Int16(clamping: Int((point.y - previous.y).rounded())))
        }
        lastTouch = [.ended, .cancelled, .failed].contains(gesture.state) ? nil : point
        if gesture.state == .cancelled { transport.releaseAllInputs() }
    }
    private func positionPointer(at point: CGPoint) -> Bool {
        guard let frame = lastFrame else { return false }
        let crop = frame.contentRect
        let transform = ViewportTransform(source: crop.size,
            destination: CGRect(origin: .zero, size: metalLayer.drawableSize), scaling: settings.scaling)
        guard let position = transform.videoPoint(point, from: bounds) else { return false }
        transport.mousePosition(x: Int16(clamping: Int(position.x + crop.minX)), y: Int16(clamping: Int(position.y + crop.minY)),
            width: Int16(clamping: frame.width), height: Int16(clamping: frame.height))
        return true
    }
    func updateStatistics(rows: [StreamStatisticRow], visible: Bool, position: StreamStatisticsPosition) {
        guard rows != statisticsRows || visible != statisticsVisible || position != statisticsPosition else { return }
        let visibilityChanged = visible != statisticsVisible
        statisticsRows = rows; statisticsVisible = visible; statisticsPosition = position
        updateStatisticsAccessibility()
        if !visible {
            clearStatisticsOverlay()
            if visibilityChanged { redraw = true; signal?.signal() }
        } else { refreshStatisticsOverlay(redrawOnInstall: visibilityChanged) }
    }
    private func updateStatisticsAccessibility() {
        let stream = streamAccessibilityElement
        stream.accessibilityFrameInContainerSpace = bounds
        if accessibilityStatisticsVisible != statisticsVisible {
            accessibilityStatisticsVisible = statisticsVisible
            stream.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: statisticsVisible ? "Hide Statistics" : "Show Statistics", target: self, selector: #selector(toggleStatisticsAction)),
                UIAccessibilityCustomAction(name: "Disconnect", target: self, selector: #selector(disconnectAction)),
                UIAccessibilityCustomAction(name: "Stream Controls", target: self, selector: #selector(showControls))
            ]
        }
        guard statisticsVisible, let installed = installedStatistics,
              bounds.width > 0, bounds.height > 0 else {
            stream.accessibilityValue = "Statistics hidden"
            accessibilityElements = [stream]
            return
        }
        stream.accessibilityValue = "Statistics shown"

        // Match the renderer's integer-pixel origin and edge clamping, then map
        // the installed raster's text geometry into this UIView's coordinates.
        let bitmap = installed.bitmap, raster = installed.raster
        let targetWidth = max(1, Int(metalLayer.drawableSize.width))
        let targetHeight = max(1, Int(metalLayer.drawableSize.height))
        let insetX = min(bitmap.insetPixels, max(0, targetWidth - bitmap.width))
        let insetY = min(bitmap.insetPixels, max(0, targetHeight - bitmap.height))
        let originX: Int
        switch bitmap.position {
        case .topLeft: originX = insetX
        case .topCenter: originX = max(0, (targetWidth - bitmap.width) / 2)
        case .topRight: originX = max(0, targetWidth - bitmap.width - insetX)
        }
        let pointsPerPixelX = bounds.width / CGFloat(targetWidth)
        let pointsPerPixelY = bounds.height / CGFloat(targetHeight)
        let rasterScale = installed.key.scale
        let textWidth = max(1, CGFloat(bitmap.width) - 2 * raster.contentInset * rasterScale)
        func frame(top: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: bounds.minX + (CGFloat(originX) + raster.contentInset * rasterScale) * pointsPerPixelX,
                   y: bounds.minY + (CGFloat(insetY) + top * rasterScale) * pointsPerPixelY,
                   width: textWidth * pointsPerPixelX, height: height * rasterScale * pointsPerPixelY)
                .intersection(bounds)
        }

        let rows = Array(installed.key.rows.prefix(raster.displayedRowCount))
        let omittedRows = installed.key.rows.count - rows.count
        let header = statisticsAccessibilityHeader
        header.accessibilityLabel = omittedRows > 0 ? "Stream Statistics · \(omittedRows) more" : "Stream Statistics"
        header.accessibilityValue = rows.isEmpty
            ? (installed.key.rows.isEmpty ? "Waiting for statistics…" : "More space needed for values") : nil
        let headerFrame = frame(top: raster.contentInset,
            height: rows.isEmpty ? raster.rowOriginY + raster.rowHeight - raster.contentInset : raster.rowHeight)
        var elements: [UIAccessibilityElement] = [stream]
        if !headerFrame.isNull, !headerFrame.isEmpty {
            header.accessibilityFrameInContainerSpace = headerFrame
            elements.append(header)
        }
        for (index, row) in rows.enumerated() {
            let rowFrame = frame(top: raster.rowOriginY + CGFloat(index) * raster.rowHeight, height: raster.rowHeight)
            guard !rowFrame.isNull, !rowFrame.isEmpty else { continue }
            let element = statisticsAccessibilityRows[row.id] ?? UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = "statistic-\(row.id)"
            element.accessibilityTraits = .staticText
            element.accessibilityLabel = row.label
            element.accessibilityValue = row.value
            element.accessibilityFrameInContainerSpace = rowFrame
            statisticsAccessibilityRows[row.id] = element
            elements.append(element)
        }
        let ids = Set(rows.map(\.id))
        statisticsAccessibilityRows = statisticsAccessibilityRows.filter { ids.contains($0.key) }
        accessibilityElements = elements
    }
    private func refreshStatisticsOverlay(redrawOnInstall: Bool = false) {
        if redrawOnInstall, statisticsVisible { statisticsRedrawPending = true }
        guard statisticsVisible, !stopped, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let inset = max(16, safeAreaInsets.top, safeAreaInsets.left, safeAreaInsets.right)
        let preferredFontScale = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection).pointSize / 12
        let fontScale = preferredFontScale.isFinite ? min(2, max(1, preferredFontScale)) : 1
        let size = CGSize(width: max(96, bounds.width - 2 * inset), height: max(1, bounds.height - 2 * inset))
        let maximumRows = max(0, min(24, Int((size.height - 48 * fontScale) / (18 * fontScale))))
        let key = StatisticsRasterKey(rows: statisticsRows, position: statisticsPosition, scale: min(4, max(1, metalLayer.contentsScale)),
                                      fontScale: fontScale, size: size, inset: inset, maximumRows: maximumRows)
        guard key != statisticsRasterKey else { return }
        statisticsRasterKey = key; statisticsRevision &+= 1; statisticsTask?.cancel()
        let revision = statisticsRevision
        statisticsTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()
                let raster = try StatisticsOverlayRasterizer.render(rows: key.rows, position: key.position,
                    backingScale: key.scale, availableSize: key.size, fontScale: key.fontScale, maximumRows: key.maximumRows)
                let bitmap = VideoOverlayBitmap(width: raster.bitmap.width, height: raster.bitmap.height, rgba8: raster.bitmap.rgba8,
                    position: raster.bitmap.position, insetPixels: Int((key.inset * key.scale).rounded()))
                try Task.checkCancellation()
                await self?.installStatistics(bitmap, raster: raster, key: key, revision: revision)
            } catch is CancellationError { }
            catch { await self?.statisticsFailed(revision: revision) }
        }
    }
    private func installStatistics(_ bitmap: VideoOverlayBitmap, raster: StatisticsOverlayRaster,
                                   key: StatisticsRasterKey, revision: UInt64) {
        guard revision == statisticsRevision, statisticsVisible, !stopped, window != nil, let renderer else { return }
        do {
            try renderer.setOverlay(bitmap); statisticsTask = nil
            installedStatistics = InstalledStatistics(bitmap: bitmap, raster: raster, key: key)
            updateStatisticsAccessibility()
            // Ordinary value changes ride the next video frame; only a user
            // visibility change requests an extra presentation of a static frame.
            if statisticsRedrawPending { redraw = true; signal?.signal() }
            statisticsRedrawPending = false
        } catch { statisticsFailed(revision: revision) }
    }
    private func statisticsFailed(revision: UInt64) {
        guard revision == statisticsRevision else { return }
        statisticsTask = nil; statisticsRasterKey = nil
    }
    private func clearStatisticsOverlay() {
        statisticsRevision &+= 1; statisticsTask?.cancel(); statisticsTask = nil; statisticsRasterKey = nil
        statisticsRedrawPending = false
        try? renderer?.setOverlay(nil)
        installedStatistics = nil; statisticsAccessibilityRows.removeAll()
        updateStatisticsAccessibility()
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        suspendPresentation()
        renderer = nil
    }
    private func suspendPresentation() {
        cancelKeyboardFocus()
        clearStatisticsOverlay()
        pipeline.setFrameAvailableHandler(nil); signal?.cancel(); signal = nil
        displayLink?.invalidate(); displayLink = nil
        transport.releaseAllInputs(); lastFrame = nil; lastTouch = nil
        hdrLayerState.reset(metalLayer)
    }
}
#endif
