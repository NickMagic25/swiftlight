import AppKit
import SwiftUI
import QuartzCore
import Metal
import CryptoKit
import UniformTypeIdentifiers
import SwiftlightVideo

/// Development and diagnostics surface. Uses the production decoder owner and Metal
/// renderer; fixture parsing/scheduling here provides compressed input without a host.
struct ReplayPreview: View {
    @StateObject private var model = ReplayPreviewModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Choose Fixture…") { model.chooseFixture() }
                Text(model.selectedURL?.deletingLastPathComponent().lastPathComponent ?? "No fixture selected")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Toggle("Loop", isOn: $model.repeating).toggleStyle(.checkbox)
                    .onChange(of: model.repeating) { _, value in model.engine?.setRepeating(value) }
                Button("Play", systemImage: "play.fill") { model.start() }.disabled(model.selectedURL == nil || model.isPlaying)
                Button("Stop", systemImage: "stop.fill") { model.stop() }.disabled(!model.canStop)
                Button("Export Results…") { model.export() }.disabled(model.engine == nil)
            }.padding()
            if let engine = model.engine {
                ReplayMetalSurface(engine: engine).id(model.runID)
                    .frame(minWidth: 560, minHeight: 315)
                    .accessibilityLabel("Native Metal video validation")
            } else {
                ContentUnavailableView("Choose a Video Fixture", systemImage: "film",
                    description: Text("Select a manifest.json file or its fixture folder. Playback uses the same hardware decoder and Metal renderer as streaming."))
                    .frame(minWidth: 560, minHeight: 315)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusLine).font(.headline)
                Text(model.countsLine).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(model.displayLine).font(.caption).foregroundStyle(.secondary)
                Text("Presented counts require an actual drawable timestamp. Callback-to-presentation timing uses measured clock calibration; it is not an optical display-latency measurement.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}

private struct PreviewFixture: Decodable {
    struct Rational: Decodable { let num: Int64; let den: Int64 }
    struct Unit: Decodable {
        let frame_id: UInt64
        let offset: Int
        let length: Int
        let sha256: String
        let pts: Int64?
        let random_access: Bool
        let expected_display_count: Int
    }
    let schema_version: Int
    let codec: VideoCodec
    let width: Int
    let height: Int
    let bit_depth: Int
    let chroma: String
    let framing: String
    let timebase: Rational
    let frame_rate: Rational
    let payload_file: String
    let payload_sha256: String
    let access_units: [Unit]
}

private struct PreviewClockCalibration: Codable, Sendable {
    let sampledAtDecoderNanoseconds: UInt64
    let coreAnimationSeconds: Double
    let decoderMinusCoreAnimationNanoseconds: Double
    let uncertaintyNanoseconds: UInt64
    static func measure() -> Self {
        var best: Self?
        for _ in 0..<31 {
            let before = VideoDecoder.monotonicNanoseconds
            let ca = CACurrentMediaTime()
            let after = VideoDecoder.monotonicNanoseconds
            let span = after >= before ? after - before : UInt64.max
            let midpoint = Double(before) + Double(span) / 2
            let uncertainty = span / 2 + span % 2
            let candidate = Self(sampledAtDecoderNanoseconds: before + span / 2, coreAnimationSeconds: ca,
                decoderMinusCoreAnimationNanoseconds: midpoint - ca * 1_000_000_000, uncertaintyNanoseconds: uncertainty)
            if best == nil || uncertainty < best!.uncertaintyNanoseconds { best = candidate }
        }
        return best!
    }
}

private struct PreviewPresentation: Codable, Sendable {
    let frameID: UInt64
    let generation: UInt64
    let callbackNanoseconds: UInt64
    let submissionDeadlineSeconds: Double
    let targetPresentationSeconds: Double
    let actualPresentationSeconds: Double
    let mappedActualPresentationNanoseconds: Double
    let callbackToPresentationMilliseconds: Double?
    let calibrationUncertaintyNanoseconds: UInt64
}

private struct PreviewState: Codable, Sendable {
    var phase = "Loading"
    var fixture = ""
    var fixtureSHA256 = ""
    var codec = ""
    var profileDescription = ""
    var completedCycles: UInt64 = 0
    var failure: String?
    var frameRate: Double = 60
    var decodedWidth = 0
    var decodedHeight = 0
    var decodedBitDepth = 0
    var visibleWidth: Double = 0
    var visibleHeight: Double = 0
    var drawableWidth = 0
    var drawableHeight = 0
    var backingScale: Double = 1
    var displayName = "Unavailable"
    var currentEDRHeadroom: Double = 1
    var potentialEDRHeadroom: Double = 1
    var lateDisplayLinkCallbacks: UInt64 = 0
    var calibrations: [PreviewClockCalibration] = []
    var presentations: [PreviewPresentation] = []
}

private struct PreviewReport: Codable, Sendable {
    let schemaVersion: Int
    let mode: String
    let exportedAt: Date
    let presentationStatus: String
    let terminalAccountingStatus: String
    let state: PreviewState
    let decoder: DecoderStatistics?
    let renderer: RenderStatistics?
    let processWideFrameOwnership: FrameOwnershipStatistics
    let callbackToPresentationMedianMilliseconds: Double?
    let callbackToPresentationP95Milliseconds: Double?
    let limitations: [String]
}

private enum PreviewError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let text) = self { text } else { "Invalid fixture" } }
}

/// The condition protects lifecycle flags, decoder/renderer references and bounded
/// report state. Compressed loading and every decoder control operation are confined
/// to worker. Display callbacks use only the decoder's locked one-frame mailbox.
/// No control operation occurs while the condition is held. Stop wakes the timed
/// arrival wait immediately, then worker joins decoder destruction off the main actor.
private final class ReplayPreviewEngine: @unchecked Sendable {
    private let condition = NSCondition()
    private let worker = DispatchQueue(label: "net.swiftlight.visible-replay", qos: .userInteractive)
    private let finished = DispatchGroup()
    private var owner: VideoDecoder?
    private var renderer: MetalVideoRenderer?
    private var stopped = false
    private var repeating: Bool
    private var state = PreviewState()
    private var finalDecoder: DecoderStatistics?
    private let url: URL

    init(url: URL, repeating: Bool) {
        self.url = url; self.repeating = repeating
        state.fixture = url.path
        state.calibrations = [.measure()]
        finished.enter()
        worker.async { [self] in run() }
    }
    func setRepeating(_ value: Bool) { condition.lock(); repeating = value; condition.unlock() }
    func requestStop() {
        condition.lock(); stopped = true
        if ["Running", "Loading", "Completed"].contains(state.phase) { state.phase = "Stopping" }
        condition.broadcast(); condition.unlock()
    }
    func whenStopped(_ completion: @escaping @MainActor @Sendable () -> Void) {
        finished.notify(queue: .main) { MainActor.assumeIsolated { completion() } }
    }
    var stopRequested: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    var frameRate: Double { condition.lock(); defer { condition.unlock() }; return state.frameRate }
    func attachRenderer(_ value: MetalVideoRenderer) { condition.lock(); renderer = value; condition.unlock() }
    func takeLatestFrame() -> DecodedFrame? {
        condition.lock(); let decoder = stopped ? nil : owner; condition.unlock()
        return decoder?.takeLatestFrame()
    }
    func fail(_ text: String) {
        condition.lock(); if state.failure == nil { state.failure = text }; state.phase = "Failed"
        stopped = true; condition.broadcast(); condition.unlock()
    }
    func updateDisplay(width: Int, height: Int, scale: Double, name: String, currentEDR: Double, potentialEDR: Double) {
        condition.lock(); defer { condition.unlock() }
        state.drawableWidth = width; state.drawableHeight = height; state.backingScale = scale
        state.displayName = name; state.currentEDRHeadroom = currentEDR; state.potentialEDRHeadroom = potentialEDR
    }
    func noteFrame(_ frame: DecodedFrame) {
        condition.lock(); defer { condition.unlock() }
        state.decodedWidth = frame.width; state.decodedHeight = frame.height; state.decodedBitDepth = frame.bitDepth
        state.visibleWidth = frame.contentRect.width; state.visibleHeight = frame.contentRect.height
    }
    func noteLateCallback() { condition.lock(); state.lateDisplayLinkCallbacks += 1; condition.unlock() }
    func refreshCalibration() {
        let calibration = PreviewClockCalibration.measure()
        condition.lock(); defer { condition.unlock() }
        if state.calibrations.count == 64 { state.calibrations.removeFirst() }
        state.calibrations.append(calibration)
    }
    func presentation(frameID: UInt64, generation: UInt64, callback: UInt64, deadline: Double, target: Double, actual: Double) {
        guard actual.isFinite, actual > 0 else { return }
        condition.lock(); defer { condition.unlock() }
        guard let calibration = state.calibrations.last else { return }
        let mapped = actual * 1_000_000_000 + calibration.decoderMinusCoreAnimationNanoseconds
        // A negative difference beyond the calibration interval is invalid, never
        // clamped into a plausible latency. Preserve raw clocks for independent audit.
        let delta = mapped - Double(callback)
        let latency = callback != 0 && delta >= -Double(calibration.uncertaintyNanoseconds) ? delta / 1_000_000 : nil
        if state.presentations.count == 1024 { state.presentations.removeFirst() }
        state.presentations.append(PreviewPresentation(frameID: frameID, generation: generation, callbackNanoseconds: callback,
            submissionDeadlineSeconds: deadline, targetPresentationSeconds: target, actualPresentationSeconds: actual,
            mappedActualPresentationNanoseconds: mapped, callbackToPresentationMilliseconds: latency,
            calibrationUncertaintyNanoseconds: calibration.uncertaintyNanoseconds))
    }
    func report() -> PreviewReport {
        condition.lock(); let captured = state; let decoder = owner; let final = finalDecoder; let renderer = renderer; condition.unlock()
        let decode = decoder?.statistics ?? final
        let rendered = renderer?.statistics
        let timings = captured.presentations.compactMap(\.callbackToPresentationMilliseconds).sorted()
        func percentile(_ fraction: Double) -> Double? { timings.isEmpty ? nil : timings[min(timings.count - 1, max(0, Int(ceil(Double(timings.count) * fraction)) - 1))] }
        let ended = captured.phase == "Stopped" || captured.phase == "Completed"
        return PreviewReport(schemaVersion: 1, mode: "visible-macos-replay", exportedAt: Date(),
            presentationStatus: (rendered?.presented ?? 0) > 0 && decode?.hardwareValidated == true ? "PASS" : "UNCONFIRMED",
            terminalAccountingStatus: ended && decode?.accepted == decode?.completed && decode?.outstanding == 0 && decode?.failed == 0 ? "PASS" : "UNCONFIRMED",
            state: captured, decoder: decode, renderer: rendered, processWideFrameOwnership: DecodedFrame.ownershipStatistics,
            callbackToPresentationMedianMilliseconds: percentile(0.5), callbackToPresentationP95Milliseconds: percentile(0.95),
            limitations: ["PASS presentation means actual positive drawable presentation timestamps were observed for hardware-decoded fixture output.",
                "Synthetic fixture arrival timing; no host, network, input or audio latency is measured.",
                "Callback-to-presentation is calibrated software timing, not photon or scanout latency.",
                "Late display-link callbacks compare callback entry with the submission deadline; they do not measure submission misses.",
                "Completed means input drained with its decoder and final output retained for presentation. Stop or window close destroys the decoder.",
                "Calibration assumes locally stable unit-rate clocks; raw times and uncertainty are retained. Sleep/wake starts a new run.",
                "Physical HDR luminance and tone mapping require separate display validation.",
                "Frame ownership counts cover the entire app process; another active stream may retain frames."])
    }
    private func wait(until deadline: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while !stopped {
            let now = VideoDecoder.monotonicNanoseconds
            if now >= deadline { return true }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(1, Double(deadline - now) / 1_000_000_000)))
        }
        return false
    }
    private func run() {
        defer { finished.leave() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var decoder: VideoDecoder?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { throw PreviewError.invalid("Manifest exceeds 8 MiB") }
            let manifestData = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(PreviewFixture.self, from: manifestData)
            let framesPerSecond = Double(fixture.frame_rate.num) / Double(fixture.frame_rate.den)
            guard fixture.schema_version == 1, fixture.width > 0, fixture.height > 0, fixture.width <= 8192, fixture.height <= 8192,
                  [8, 10].contains(fixture.bit_depth), fixture.chroma == "420", fixture.timebase.num > 0, fixture.timebase.den > 0,
                  fixture.frame_rate.num > 0, fixture.frame_rate.den > 0, framesPerSecond.isFinite, (1...1000).contains(framesPerSecond),
                  (1...10000).contains(fixture.access_units.count),
                  fixture.access_units[0].random_access,
                  fixture.framing == (fixture.codec == .hevc ? "hevc-annex-b" : "av1-low-overhead-obu") else { throw PreviewError.invalid("Unsupported fixture schema, dimensions, framing or starting keyframe") }
            let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let payloadURL = directory.appendingPathComponent(fixture.payload_file).resolvingSymlinksInPath()
            guard payloadURL.path.hasPrefix(directory.path + "/") else { throw PreviewError.invalid("Payload escapes fixture directory") }
            let payloadAttributes = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
            guard let payloadSize = payloadAttributes[.size] as? NSNumber, payloadSize.uint64Value <= 256 * 1024 * 1024 else { throw PreviewError.invalid("Visible replay payload exceeds 256 MiB") }
            let payload = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
            func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            guard digest(payload) == fixture.payload_sha256 else { throw PreviewError.invalid("Fixture payload hash mismatch") }
            var identities = Set<UInt64>(), end = 0
            var offsets: [UInt64] = []
            let firstPTS = Double(fixture.access_units[0].pts ?? 0)
            for (index, unit) in fixture.access_units.enumerated() {
                guard identities.insert(unit.frame_id).inserted, unit.offset == end, unit.length > 0, unit.length <= 64 * 1024 * 1024,
                      unit.offset >= 0, unit.offset <= payload.count, unit.length <= payload.count - unit.offset,
                      (0...1).contains(unit.expected_display_count) else { throw PreviewError.invalid("Invalid access-unit boundaries or identities") }
                end += unit.length
                guard digest(payload.subdata(in: unit.offset..<end)) == unit.sha256 else { throw PreviewError.invalid("Access-unit hash mismatch") }
                let time = (Double(unit.pts ?? Int64(index)) - firstPTS) * Double(fixture.timebase.num) / Double(fixture.timebase.den) * 1_000_000_000
                guard time.isFinite, time >= 0, time <= 3_600_000_000_000 else { throw PreviewError.invalid("Fixture timeline must be monotonic and no longer than one hour") }
                let ns = UInt64(time)
                guard offsets.last == nil || ns >= offsets.last! else { throw PreviewError.invalid("Nonmonotonic synthetic arrival timeline") }
                offsets.append(ns)
            }
            guard end == payload.count else { throw PreviewError.invalid("Trailing fixture bytes are unaccounted") }
            guard fixture.codec.hardwareCandidate else { throw PreviewError.invalid("Hardware \(fixture.codec.rawValue) decoding is unavailable on this device") }
            let created = try VideoDecoder(codec: fixture.codec, maxFramesInFlight: 2)
            decoder = created
            condition.lock(); owner = created
            state.fixtureSHA256 = digest(manifestData); state.codec = fixture.codec.rawValue
            state.profileDescription = "\(fixture.bit_depth)-bit 4:2:0"; state.frameRate = framesPerSecond
            if !stopped { state.phase = "Running" }; condition.unlock()
            let framePeriod = UInt64(max(1, Double(fixture.frame_rate.den) / Double(fixture.frame_rate.num) * 1_000_000_000))
            let cycleDuration = (offsets.last ?? 0) + framePeriod
            let replayOrigin = VideoDecoder.monotonicNanoseconds
            var cycleStart = replayOrigin
            var sequence: UInt64 = 0
            var completedCycles: UInt64 = 0
            let displaysPerCycle = UInt64(fixture.access_units.reduce(0) { $0 + $1.expected_display_count })
            replay: while !stopRequested {
                for (index, unit) in fixture.access_units.enumerated() {
                    let arrival = cycleStart + offsets[index]
                    guard wait(until: arrival) else { break replay }
                    let input = CompressedFrame(bytes: payload.subdata(in: unit.offset..<(unit.offset + unit.length)), id: sequence,
                        presentationTimeNanoseconds: Int64(clamping: arrival - replayOrigin), randomAccess: unit.random_access,
                        arrivalNanoseconds: arrival)
                    var result = created.submit(input)
                    if result == .wouldBlock {
                        try created.waitForCapacity(timeoutNanoseconds: 100_000_000)
                        guard !stopRequested else { break replay }
                        result = created.submit(input)
                        if result == .wouldBlock { try created.drain(); result = created.submit(input) }
                    }
                    guard result == .accepted else { throw PreviewError.invalid("Fixture AU \(unit.frame_id) rejected: \(result)") }
                    sequence += 1
                    if let failure = created.statistics.failureDescription { throw PreviewError.invalid(failure) }
                }
                try created.drain()
                let totals = created.statistics
                completedCycles += 1
                let expectedAccepted = completedCycles * UInt64(fixture.access_units.count)
                let expectedDisplayed = completedCycles * displaysPerCycle
                guard totals.accepted == expectedAccepted, totals.completed == expectedAccepted, totals.failed == 0,
                      totals.output == expectedDisplayed, totals.noDisplay == expectedAccepted - expectedDisplayed else {
                    throw PreviewError.invalid(totals.failureDescription ?? "Terminal/display accounting failed for the completed fixture cycle")
                }
                condition.lock(); state.completedCycles = completedCycles; let again = repeating && !stopped; condition.unlock()
                if !again { break }
                cycleStart += cycleDuration
                // A severely delayed system must not burst an unbounded catch-up loop.
                cycleStart = max(cycleStart, VideoDecoder.monotonicNanoseconds)
            }
            if !stopRequested { try created.drain() }
            // A finite replay must leave its final mailbox output available to the
            // next display tick. Keep the drained owner until explicit teardown.
            condition.lock()
            if !stopped { state.phase = "Completed" }
            while !stopped { condition.wait() }
            condition.unlock()
        } catch { fail(String(describing: error)) }
        if let decoder {
            do { try decoder.close() } catch { fail(String(describing: error)) }
            condition.lock(); finalDecoder = decoder.statistics; owner = nil; condition.unlock()
        }
        condition.lock()
        if state.failure == nil { state.phase = "Stopped" }
        condition.unlock()
    }
}

@MainActor private final class ReplayPreviewModel: ObservableObject {
    @Published var selectedURL: URL?
    @Published var repeating = true
    @Published var engine: ReplayPreviewEngine?
    @Published var runID = UUID()
    @Published var latest: PreviewReport?
    @Published var message: String?
    private var ticker: Task<Void, Never>?
    private var began: Date?
    private var stopRequestedAt: Date?
    private var autoExported = false
    private var pendingStart: UUID?
    var isPlaying: Bool { pendingStart != nil || ["Loading", "Running", "Stopping"].contains(latest?.state.phase ?? (engine == nil ? "Idle" : "Loading")) }
    var canStop: Bool { pendingStart != nil || engine != nil && !["Stopped", "Failed"].contains(latest?.state.phase ?? "Loading") }
    var statusLine: String {
        guard let latest else { return engine == nil ? "Ready for a fixture" : "Loading fixture…" }
        return "\(latest.state.phase) · \(latest.state.codec.uppercased()) \(latest.state.profileDescription) · \(latest.state.completedCycles) cycles"
    }
    var countsLine: String {
        let d = latest?.decoder; let r = latest?.renderer
        return "Accepted \(d?.accepted ?? 0)  Completed \(d?.completed ?? 0)  Output \(d?.output ?? 0)  Hidden \(d?.noDisplay ?? 0)  Presented \(r?.presented ?? 0)  Skipped \(d?.skippedForPresentation ?? 0)  GPU \(r?.inFlight ?? 0)/3"
    }
    var displayLine: String {
        guard let latest else { return "No presentation timestamps observed yet." }
        let s = latest.state
        let timing = latest.callbackToPresentationMedianMilliseconds.map { String(format: " · callback → presented median %.2f ms", $0) } ?? ""
        return "\(s.decodedWidth) × \(s.decodedHeight) decoded · \(s.drawableWidth) × \(s.drawableHeight) drawable · \(s.displayName) · EDR \(String(format: "%.2f", s.currentEDRHeadroom))\(timing)"
    }
    func appear() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        if selectedURL == nil {
            let environment = ProcessInfo.processInfo.environment
            if let supplied = environment["SWIFTLIGHT_REPLAY_MANIFEST"] { selectedURL = URL(fileURLWithPath: supplied) }
            else {
                let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("fixtures/hevc-sdr8/manifest.json")
                if FileManager.default.fileExists(atPath: dev.path) { selectedURL = dev }
            }
            if selectedURL != nil { start() }
        }
    }
    func disappear() { stop(); ticker?.cancel(); ticker = nil }
    func chooseFixture() {
        let panel = NSOpenPanel(); panel.title = "Choose Video Fixture"; panel.canChooseFiles = true
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, var url = panel.url {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { url.appendPathComponent("manifest.json") }
            selectedURL = url; start()
        }
    }
    func start() {
        guard let selectedURL else { return }
        let token = UUID(); pendingStart = token
        let install: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.pendingStart == token else { return }
            self.pendingStart = nil; self.latest = nil; self.message = nil
            self.began = Date(); self.stopRequestedAt = nil; self.autoExported = false
            self.runID = UUID(); self.engine = ReplayPreviewEngine(url: selectedURL, repeating: self.repeating)
        }
        if let engine {
            engine.requestStop(); latest = engine.report()
            // Decoder destruction finishes on the old worker before a replacement
            // starts. Tokens also cancel stale queued Play/fixture selections.
            engine.whenStopped(install)
        } else { install() }
    }
    func stop() { pendingStart = nil; engine?.requestStop(); if stopRequestedAt == nil { stopRequestedAt = Date() }; refresh() }
    private func refresh() {
        guard let engine else { return }
        latest = engine.report()
        if let failure = latest?.state.failure { message = failure }
        if let failure = latest?.decoder?.failureDescription { engine.fail(failure); message = failure }
        let environment = ProcessInfo.processInfo.environment
        if let seconds = environment["SWIFTLIGHT_REPLAY_SECONDS"].flatMap(Double.init), (1...60).contains(seconds),
           let began, Date().timeIntervalSince(began) >= seconds, stopRequestedAt == nil {
            stopRequestedAt = Date(); engine.requestStop()
        }
        if !autoExported, let stopRequestedAt, Date().timeIntervalSince(stopRequestedAt) >= 0.5,
           latest?.state.phase == "Stopped", latest?.renderer?.inFlight == 0,
           let path = environment["SWIFTLIGHT_REPLAY_REPORT"], path.hasPrefix("/") {
            autoExported = true
            do { try writeReport(to: URL(fileURLWithPath: path)); message = "Saved measured presentation evidence to \(path)" }
            catch { message = String(describing: error) }
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "swiftlight-display-replay.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try writeReport(to: url); message = "Saved measured presentation evidence." }
            catch { message = String(describing: error) }
        }
    }
    private func writeReport(to url: URL) throws {
        guard let engine else { return }
        engine.refreshCalibration()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(engine.report())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private struct ReplayMetalSurface: NSViewRepresentable {
    let engine: ReplayPreviewEngine
    func makeNSView(context: Context) -> ReplayMetalView { ReplayMetalView(engine: engine) }
    func updateNSView(_ view: ReplayMetalView, context: Context) { view.synchronizeState() }
    static func dismantleNSView(_ view: ReplayMetalView, coordinator: ()) { view.stop() }
}

@MainActor private final class ReplayMetalView: NSView, @preconcurrency CAMetalDisplayLinkDelegate {
    private let engine: ReplayPreviewEngine
    private let metalLayer = CAMetalLayer()
    private var renderer: MetalVideoRenderer?
    private var displayLink: CAMetalDisplayLink?
    private var lastFrame: DecodedFrame?
    private var needsRedraw = true
    private var lastCalibrationSeconds = 0.0
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    init(engine: ReplayPreviewEngine) {
        self.engine = engine; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        do {
            let renderer = try MetalVideoRenderer(); self.renderer = renderer; engine.attachRenderer(renderer)
            metalLayer.device = renderer.device; metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.wantsExtendedDynamicRangeContent = true; metalLayer.framebufferOnly = true; metalLayer.maximumDrawableCount = 3
            layer?.addSublayer(metalLayer)
        } catch { engine.fail(String(describing: error)) }
    }
    required init?(coder: NSCoder) { fatalError("Use init(engine:)") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); displayLink?.invalidate(); displayLink = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        guard let window else { stop(); return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self; link.preferredFrameLatency = 1
        let maximum = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maximum), maximum: maximum, preferred: min(60, maximum))
        link.add(to: .main, forMode: .common); displayLink = link
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.requestStop(); self?.synchronizeState() }
            }
        }
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.frame = bounds; metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit(); needsRedraw = true
        publishDisplay()
    }
    private func publishDisplay() {
        engine.updateDisplay(width: Int(metalLayer.drawableSize.width), height: Int(metalLayer.drawableSize.height),
            scale: Double(window?.backingScaleFactor ?? 1), name: window?.screen?.localizedName ?? "Unavailable",
            currentEDR: Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
            potentialEDR: Double(window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1))
    }
    func synchronizeState() {
        if engine.stopRequested { displayLink?.isPaused = true; lastFrame = nil }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard !engine.stopRequested, let renderer else { synchronizeState(); return }
        let now = CACurrentMediaTime()
        if now - lastCalibrationSeconds >= 1 {
            engine.refreshCalibration(); publishDisplay(); lastCalibrationSeconds = now
            let maximum = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            let preferred = min(maximum, max(1, Float(engine.frameRate)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, preferred), maximum: maximum, preferred: preferred)
        }
        if now > update.targetTimestamp { engine.noteLateCallback() }
        let incoming = engine.takeLatestFrame()
        if let incoming { lastFrame = incoming; engine.noteFrame(incoming) }
        guard incoming != nil || needsRedraw, let frame = lastFrame else { return }
        if frame.color.transfer == 16 {
            metalLayer.edrMetadata = .hdr10(displayInfo: frame.color.mastering.isEmpty ? nil : Data(frame.color.mastering),
                contentInfo: frame.color.contentLight.isEmpty ? nil : Data(frame.color.contentLight), opticalOutputScale: 203)
        } else { metalLayer.edrMetadata = nil }
        let frameID = frame.id, generation = frame.generation, callback = frame.callbackNanoseconds
        let deadline = update.targetTimestamp, target = update.targetPresentationTimestamp
        let engine = engine
        update.drawable.addPresentedHandler { drawable in
            engine.presentation(frameID: frameID, generation: generation, callback: callback,
                deadline: deadline, target: target, actual: drawable.presentedTime)
        }
        do {
            if try renderer.render(frame, into: update.drawable, completion: { [engine] result in
                if !result.succeeded { engine.fail("Metal command failed while presenting the fixture") }
            }) { needsRedraw = false }
        } catch { engine.fail(String(describing: error)); synchronizeState() }
    }
    func stop() {
        displayLink?.invalidate(); displayLink = nil; lastFrame = nil; engine.requestStop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver); self.sleepObserver = nil }
    }
}
