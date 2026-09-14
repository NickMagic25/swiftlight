import Metal
import QuartzCore
import SwiftUI
import SwiftlightCore
import SwiftlightTransport
import SwiftlightVideo
import UIKit

struct MobileStreamScreen: View {
    @ObservedObject var session: MobileStreamingSession
    @State private var showingControls = false
    var body: some View {
        ZStack {
            Color.black
            if let pipeline = session.pipeline, let transport = session.transport {
                MobileStreamSurface(pipeline: pipeline, transport: transport, settings: session.settings, inputEnabled: session.inputEnabled,
                    controls: { session.releaseInputs(); showingControls.toggle() })
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
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingControls) {
            NavigationStack {
                Form {
                    Section {
                        Text("Touch the video to move the pointer. Tap to click, or use a connected game controller.")
                        Text("Tap with three fingers to show or hide these controls.")
                    }
                    Section {
                        Button("Disconnect", role: .destructive) {
                            showingControls = false
                            Task { await session.disconnect() }
                        }
                    } footer: { Text("Disconnecting leaves the application running on your computer.") }
                }
                .navigationTitle("Stream Controls")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { showingControls = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .onChange(of: showingControls) { _, visible in
            session.setControlsVisible(visible)
        }
    }
}

private struct MobileStreamSurface: UIViewRepresentable {
    let pipeline: StreamingPipeline
    let transport: StreamTransport
    let settings: StreamSettings
    let inputEnabled: Bool
    let controls: () -> Void
    func makeUIView(context: Context) -> MobileStreamView {
        MobileStreamView(pipeline: pipeline, transport: transport, settings: settings, controls: controls)
    }
    func updateUIView(_ view: MobileStreamView, context: Context) { view.inputEnabled = inputEnabled }
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

@MainActor private final class MobileStreamView: UIView, @preconcurrency CAMetalDisplayLinkDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let pipeline: StreamingPipeline
    private let transport: StreamTransport
    private let settings: StreamSettings
    private let controls: () -> Void
    private var renderer: MetalVideoRenderer?
    private var displayLink: CAMetalDisplayLink?
    private var signal: MobileFrameSignal?
    private var lastFrame: DecodedFrame?
    private var redraw = false
    private var lastTouch: CGPoint?
    private var stopped = false
    var inputEnabled = false {
        didSet { if !inputEnabled { transport.releaseAllInputs(); lastTouch = nil } }
    }
    override var canBecomeFirstResponder: Bool { true }

    init(pipeline: StreamingPipeline, transport: StreamTransport, settings: StreamSettings, controls: @escaping () -> Void) {
        self.pipeline = pipeline; self.transport = transport; self.settings = settings; self.controls = controls
        super.init(frame: .zero)
        backgroundColor = .black; isOpaque = true; isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Game stream"
        accessibilityHint = "Use the Stream Controls action to disconnect."
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Stream Controls", target: self, selector: #selector(showControls))]
        let menu = UITapGestureRecognizer(target: self, action: #selector(showControls))
        menu.numberOfTouchesRequired = 3; addGestureRecognizer(menu)
        let tap = UITapGestureRecognizer(target: self, action: #selector(clickPointer(_:)))
        tap.require(toFail: menu); addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(movePointer(_:)))
        pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        do {
            let renderer = try MetalVideoRenderer()
            self.renderer = renderer; pipeline.attachRenderer(renderer)
            metalLayer.device = renderer.device; metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.framebufferOnly = true; metalLayer.isOpaque = true
            metalLayer.maximumDrawableCount = settings.maximumDrawableCount
            metalLayer.presentsWithTransaction = false
        } catch { pipeline.reportRendererFailure() }
    }
    required init?(coder: NSCoder) { fatalError("Use the streaming initializer") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !stopped else { return }
        guard window != nil else { suspendPresentation(); return }
        guard displayLink == nil, signal == nil else { return }
        becomeFirstResponder()
        if settings.videoPacing == .displayLink {
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self; link.preferredFrameLatency = 1
            let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maximum), maximum: maximum,
                preferred: min(Float(settings.framesPerSecond == 0 ? Int(maximum) : settings.framesPerSecond), maximum))
            link.add(to: .main, forMode: .common); displayLink = link
        } else {
            let signal = MobileFrameSignal { [weak self] in MainActor.assumeIsolated { self?.renderImmediate() } }
            self.signal = signal; pipeline.setFrameAvailableHandler { signal.signal() }; signal.signal()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size; redraw = true; signal?.signal(); transport.releaseAllInputs()
        }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        render(into: update.drawable, timing: .init(displayCallbackSeconds: CACurrentMediaTime(),
            targetDeadlineSeconds: update.targetTimestamp, targetPresentationSeconds: update.targetPresentationTimestamp))
    }
    private func renderImmediate() {
        guard !stopped, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let began = CACurrentMediaTime()
        guard let drawable = metalLayer.nextDrawable() else { return }
        render(into: drawable, timing: .init(drawableAcquisitionMilliseconds: (CACurrentMediaTime() - began) * 1000))
    }
    private func render(into drawable: any CAMetalDrawable, timing: PresentationSubmissionTiming) {
        guard !stopped, let renderer else { return }
        let incoming = pipeline.takeLatestFrame()
        if let incoming { lastFrame = incoming; pipeline.recordFrame(incoming, viewport: metalLayer.drawableSize) }
        guard incoming != nil || redraw, let frame = lastFrame else { return }
        do {
            let submission = PresentationSubmissionTiming(displayCallbackSeconds: timing.displayCallbackSeconds,
                targetDeadlineSeconds: timing.targetDeadlineSeconds, targetPresentationSeconds: timing.targetPresentationSeconds,
                selectedAtSeconds: CACurrentMediaTime(), drawableAcquisitionMilliseconds: timing.drawableAcquisitionMilliseconds)
            if try renderer.render(frame, into: drawable,
                scaleMode: settings.scaling == .fill ? .fill : settings.scaling == .integer ? .integer : .fit,
                submissionTiming: submission, completion: { [pipeline] result in
                    if !result.succeeded { pipeline.reportRendererFailure() }
                }) { redraw = false }
        } catch { pipeline.reportRendererFailure() }
    }
    @objc private func showControls() -> Bool { transport.releaseAllInputs(); controls(); return true }
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
        let transform = ViewportTransform(source: crop.size, destination: bounds, scaling: settings.scaling)
        guard let position = transform.videoPoint(point) else { return false }
        transport.mousePosition(x: Int16(clamping: Int(position.x + crop.minX)), y: Int16(clamping: Int(position.y + crop.minY)),
            width: Int16(clamping: frame.width), height: Int16(clamping: frame.height))
        return true
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [.command], action: #selector(showControls))]
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        suspendPresentation()
        renderer = nil
    }
    private func suspendPresentation() {
        pipeline.setFrameAvailableHandler(nil); signal?.cancel(); signal = nil
        displayLink?.invalidate(); displayLink = nil
        transport.releaseAllInputs(); lastFrame = nil; lastTouch = nil
    }
}
