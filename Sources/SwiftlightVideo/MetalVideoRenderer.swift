import Foundation
import Metal
import QuartzCore
import CoreVideo
import simd

public struct RenderStatistics: Codable, Sendable {
    public var submitted = 0
    public var completed = 0
    public var presented = 0
    public var unconfirmedPresentation = 0
    public var skippedGPUCapacity = 0
    public var inFlight = 0
    public var inFlightHighWater = 0
    /// Submitted drawables for which no presentation callback has arrived. This
    /// includes GPU work and completed GPU work awaiting Core Animation.
    public var pendingPresentation = 0
    public var pendingPresentationHighWater = 0
    public var completedAwaitingPresentation = 0
    /// Scalar diagnostic entries discarded by the 1024-submission bound, not a
    /// count of dropped frames. Late callbacks for these entries are ignored.
    public var presentationTimingJoinEvictions = 0
    public var overlayUploads = 0
    public var overlayDraws = 0
    public var gpuMilliseconds: [Double] = []
    /// At most 1024 completed render submissions, including redraws and frames
    /// without confirmed presentation. GPU completion is not display latency.
    public var completedFrameTimings: [GPUFrameTiming] = []
    public var actualPresentationNanoseconds: [UInt64] = []
    /// At most 1024 distinct frames with a confirmed drawable presentation. Redraws
    /// update an earlier timestamp, if one arrives out of order, instead of counting twice.
    public var presentationTimings: [FramePresentationTiming] = []
    public var firstPacketToPresentation: TimingSummary {
        TimingSummary(milliseconds: presentationTimings.compactMap(\.firstPacketToPresentationMilliseconds))
    }
    /// The newest distinct frame by actual presentation time, not ring position
    /// or callback arrival order. Never substitute an older frame's valid timing.
    public func currentFirstPacketToPresentationMilliseconds(at presentationTime: TimeInterval = CACurrentMediaTime()) -> Double? {
        guard presentationTime.isFinite,
              let latest = presentationTimings.max(by: { $0.actualPresentationNanoseconds < $1.actualPresentationNanoseconds }) else { return nil }
        let age = presentationTime - Double(latest.actualPresentationNanoseconds) / 1_000_000_000
        guard age >= 0, age <= 5 else { return nil }
        return latest.firstPacketToPresentationMilliseconds
    }
    /// Host duration and client interval are paired on the same frame. Adding half
    /// an independently sampled RTT remains an estimate, not host/display clock sync.
    public var hostProcessingAndClientPresentation: TimingSummary {
        TimingSummary(milliseconds: presentationTimings.compactMap { sample in
            guard let client = sample.firstPacketToPresentationMilliseconds, let host = sample.hostProcessingMilliseconds else { return nil }
            return client + host
        })
    }
    public var presentationTimingUnavailableCount: Int {
        presentationTimings.filter { $0.firstPacketToPresentationMilliseconds == nil }.count
    }
    public var presentationClockUncertaintyNanoseconds: UInt64? {
        presentationTimings.compactMap(\.calibrationUncertaintyNanoseconds).max()
    }
}

/// Public clock-domain bridge for diagnostics. Bracketing CACurrentMediaTime with
/// decoder-clock reads measures the local offset; the half bracket is uncertainty
/// from sampling only, not physical display accuracy. Both clocks must remain
/// locally unit-rate. A fresh calibration is taken for each presentation callback.
public struct PresentationClockCalibration: Codable, Sendable {
    public let sampledAtDecoderNanoseconds: UInt64
    public let coreAnimationSeconds: Double
    public let uncertaintyNanoseconds: UInt64

    public static func measure() -> Self? {
        var best: Self?
        for _ in 0..<3 {
            let before = VideoDecoder.monotonicNanoseconds
            let ca = CACurrentMediaTime()
            let after = VideoDecoder.monotonicNanoseconds
            guard after >= before, before != 0, ca.isFinite, ca > 0 else { continue }
            let span = after - before
            let candidate = Self(sampledAtDecoderNanoseconds: before + span / 2, coreAnimationSeconds: ca,
                uncertaintyNanoseconds: span / 2 + span % 2)
            if best == nil || candidate.uncertaintyNanoseconds < best!.uncertaintyNanoseconds { best = candidate }
        }
        return best
    }

    func milliseconds(from decoderNanoseconds: UInt64, toPresentedSeconds presented: Double) -> Double? {
        guard decoderNanoseconds != 0, sampledAtDecoderNanoseconds != 0, uncertaintyNanoseconds <= 1_000_000,
              coreAnimationSeconds.isFinite, coreAnimationSeconds > 0, presented.isFinite, presented > 0 else { return nil }
        // Subtract integer clock values before converting to Double to preserve
        // precision after long uptimes; never subtract uncalibrated clock epochs.
        let decoderDelta = sampledAtDecoderNanoseconds >= decoderNanoseconds ?
            Double(sampledAtDecoderNanoseconds - decoderNanoseconds) : -Double(decoderNanoseconds - sampledAtDecoderNanoseconds)
        let delta = decoderDelta + (presented - coreAnimationSeconds) * 1_000_000_000
        guard delta.isFinite, delta >= 0 else { return nil }
        return delta / 1_000_000
    }
}

/// Surface timestamps use the Core Animation media clock, including display-link
/// deadlines. Decoder clock values must not be supplied here without calibration.
public struct PresentationSubmissionTiming: Codable, Sendable {
    public let displayCallbackSeconds: Double?
    public let targetDeadlineSeconds: Double?
    public let targetPresentationSeconds: Double?
    public let selectedAtSeconds: Double?
    public let drawableAcquisitionMilliseconds: Double?

    public init(displayCallbackSeconds: Double? = nil, targetDeadlineSeconds: Double? = nil,
                targetPresentationSeconds: Double? = nil, selectedAtSeconds: Double? = nil,
                drawableAcquisitionMilliseconds: Double? = nil) {
        self.displayCallbackSeconds = displayCallbackSeconds; self.targetDeadlineSeconds = targetDeadlineSeconds
        self.targetPresentationSeconds = targetPresentationSeconds; self.selectedAtSeconds = selectedAtSeconds
        self.drawableAcquisitionMilliseconds = drawableAcquisitionMilliseconds
    }
}

public struct FramePresentationTiming: Codable, Sendable {
    public let frameID: UInt64
    public let generation: UInt64
    public let callbackNanoseconds: UInt64
    public let actualPresentationNanoseconds: UInt64
    public let firstPacketToPresentationMilliseconds: Double?
    public let hostProcessingMilliseconds: Double?
    public let calibrationUncertaintyNanoseconds: UInt64?
    public let firstPacketToArrivalMilliseconds: Double?
    public let arrivalToAdmissionMilliseconds: Double?
    public let admissionToVTSubmitMilliseconds: Double?
    public let vtSubmitToDecodeCallbackMilliseconds: Double?
    public let firstPacketToDecodeCallbackMilliseconds: Double?
    public let decodeCallbackToSelectionMilliseconds: Double?
    public let decodeCallbackToRenderStartMilliseconds: Double?
    public let displayCallbackToRenderStartMilliseconds: Double?
    public let selectionToRenderStartMilliseconds: Double?
    public let drawableAcquisitionMilliseconds: Double?
    /// CPU time from render entry until immediately before command.commit().
    public let renderCPUToCommitMilliseconds: Double?
    public let commitToPresentationMilliseconds: Double?
    /// All Metal execution timestamps use system Mach time in seconds, the same
    /// clock as CACurrentMediaTime. Read GPU timestamps only after completion.
    public let commitToScheduledCallbackMilliseconds: Double?
    public let commitToKernelStartMilliseconds: Double?
    public let kernelSchedulingMilliseconds: Double?
    public let kernelEndToScheduledCallbackMilliseconds: Double?
    public let commitToGPUStartMilliseconds: Double?
    public let gpuExecutionMilliseconds: Double?
    public let gpuEndToPresentationMilliseconds: Double?
    public let gpuEndToCompletedCallbackMilliseconds: Double?
    public let presentationToPresentedCallbackMilliseconds: Double?
    /// Signed: a positive value means commit missed the display-link deadline.
    public let deadlineToCommitMilliseconds: Double?
    /// Signed: a positive value means presentation followed the display-link target.
    public let targetPresentationToPresentationMilliseconds: Double?
    public let displayCallbackSeconds: Double?
    public let targetDeadlineSeconds: Double?
    public let targetPresentationSeconds: Double?
    public let selectedAtSeconds: Double?
    public let renderStartSeconds: Double?
    public let commitSeconds: Double?
    public let scheduledCallbackSeconds: Double?
    public let kernelStartSeconds: Double?
    public let kernelEndSeconds: Double?
    public let gpuStartSeconds: Double?
    public let gpuEndSeconds: Double?
    public let completedCallbackSeconds: Double?
    public let presentedCallbackSeconds: Double?
}

/// A single render submission through GPU completion. This deliberately contains
/// no presentation timestamp: an unavailable drawable callback cannot make GPU
/// completion stand in for display. Redraw submissions are recorded separately.
public struct GPUFrameTiming: Codable, Sendable {
    public let frameID: UInt64
    public let generation: UInt64
    public let callbackNanoseconds: UInt64
    public let succeeded: Bool
    public let calibrationUncertaintyNanoseconds: UInt64?
    public let firstPacketToDecodeCallbackMilliseconds: Double?
    public let firstPacketToGPUEndMilliseconds: Double?
    public let decodeCallbackToGPUEndMilliseconds: Double?
    public let decodeCallbackToSelectionMilliseconds: Double?
    public let decodeCallbackToRenderStartMilliseconds: Double?
    public let selectionToRenderStartMilliseconds: Double?
    public let drawableAcquisitionMilliseconds: Double?
    public let renderCPUToCommitMilliseconds: Double?
    public let commitToKernelStartMilliseconds: Double?
    public let kernelSchedulingMilliseconds: Double?
    public let kernelEndToScheduledCallbackMilliseconds: Double?
    public let commitToScheduledCallbackMilliseconds: Double?
    public let commitToGPUStartMilliseconds: Double?
    public let gpuExecutionMilliseconds: Double?
    public let gpuEndToCompletedCallbackMilliseconds: Double?
    public let selectedAtSeconds: Double?
    public let renderStartSeconds: Double?
    public let commitSeconds: Double?
    public let scheduledCallbackSeconds: Double?
    public let kernelStartSeconds: Double?
    public let kernelEndSeconds: Double?
    public let gpuStartSeconds: Double?
    public let gpuEndSeconds: Double?
    public let completedCallbackSeconds: Double?

    init(_ frame: FramePresentationMetadata, submission: FrameRenderSubmissionMetadata,
         succeeded: Bool, calibration: PresentationClockCalibration?) {
        func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        func interval(_ start: Double?, _ end: Double?) -> Double? {
            guard let start = valid(start), let end = valid(end), end >= start else { return nil }
            return (end - start) * 1000
        }
        frameID = frame.frameID; generation = frame.generation; callbackNanoseconds = frame.callbackNanoseconds
        self.succeeded = succeeded
        selectedAtSeconds = valid(submission.surface?.selectedAtSeconds)
        renderStartSeconds = valid(submission.renderStartSeconds); commitSeconds = valid(submission.commitSeconds)
        scheduledCallbackSeconds = valid(submission.scheduledCallbackSeconds)
        kernelStartSeconds = valid(submission.kernelStartSeconds); kernelEndSeconds = valid(submission.kernelEndSeconds)
        gpuStartSeconds = valid(submission.gpuStartSeconds); gpuEndSeconds = valid(submission.gpuEndSeconds)
        completedCallbackSeconds = valid(submission.completedCallbackSeconds)
        let validReceive = frame.firstPacketNanoseconds != 0 && frame.callbackNanoseconds >= frame.firstPacketNanoseconds
        firstPacketToDecodeCallbackMilliseconds = validReceive ? Double(frame.callbackNanoseconds - frame.firstPacketNanoseconds) / 1_000_000 : nil
        firstPacketToGPUEndMilliseconds = validReceive ? gpuEndSeconds.flatMap {
            calibration?.milliseconds(from: frame.firstPacketNanoseconds, toPresentedSeconds: $0)
        } : nil
        decodeCallbackToGPUEndMilliseconds = gpuEndSeconds.flatMap {
            calibration?.milliseconds(from: frame.callbackNanoseconds, toPresentedSeconds: $0)
        }
        decodeCallbackToSelectionMilliseconds = selectedAtSeconds.flatMap {
            calibration?.milliseconds(from: frame.callbackNanoseconds, toPresentedSeconds: $0)
        }
        decodeCallbackToRenderStartMilliseconds = renderStartSeconds.flatMap {
            calibration?.milliseconds(from: frame.callbackNanoseconds, toPresentedSeconds: $0)
        }
        calibrationUncertaintyNanoseconds = decodeCallbackToGPUEndMilliseconds == nil ? nil : calibration?.uncertaintyNanoseconds
        selectionToRenderStartMilliseconds = interval(selectedAtSeconds, renderStartSeconds)
        drawableAcquisitionMilliseconds = submission.surface?.drawableAcquisitionMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        renderCPUToCommitMilliseconds = interval(renderStartSeconds, commitSeconds)
        commitToKernelStartMilliseconds = interval(commitSeconds, kernelStartSeconds)
        kernelSchedulingMilliseconds = interval(kernelStartSeconds, kernelEndSeconds)
        kernelEndToScheduledCallbackMilliseconds = interval(kernelEndSeconds, scheduledCallbackSeconds)
        commitToScheduledCallbackMilliseconds = interval(commitSeconds, scheduledCallbackSeconds)
        commitToGPUStartMilliseconds = interval(commitSeconds, gpuStartSeconds)
        gpuExecutionMilliseconds = interval(gpuStartSeconds, gpuEndSeconds)
        gpuEndToCompletedCallbackMilliseconds = interval(gpuEndSeconds, completedCallbackSeconds)
    }
}

struct GPUFrameTimingWindow {
    private(set) var samples: [GPUFrameTiming] = []
    private var nextIndex = 0
    mutating func record(_ sample: GPUFrameTiming) {
        if samples.count < 1024 { samples.append(sample) }
        else { samples[nextIndex] = sample; nextIndex = (nextIndex + 1) % 1024 }
    }
}

/// Scalar-only metadata prevents presentation notifications from retaining decoder
/// buffers after GPU completion. The callback may arrive after a subsequent redraw.
struct FramePresentationMetadata: Sendable {
    let frameID: UInt64
    let generation: UInt64
    let callbackNanoseconds: UInt64
    let firstPacketNanoseconds: UInt64
    let scheduledArrivalNanoseconds: UInt64
    let admissionNanoseconds: UInt64
    let vtSubmitNanoseconds: UInt64
    let hostProcessingMilliseconds: Double?
    init(_ frame: DecodedFrame) {
        frameID = frame.id; generation = frame.generation; callbackNanoseconds = frame.callbackNanoseconds
        firstPacketNanoseconds = frame.firstPacketNanoseconds; hostProcessingMilliseconds = frame.hostProcessingMilliseconds
        scheduledArrivalNanoseconds = frame.scheduledArrivalNanoseconds
        admissionNanoseconds = frame.admissionNanoseconds; vtSubmitNanoseconds = frame.vtSubmitNanoseconds
    }
    init(frameID: UInt64, generation: UInt64 = 0, callbackNanoseconds: UInt64,
         firstPacketNanoseconds: UInt64, hostProcessingMilliseconds: Double? = nil,
         scheduledArrivalNanoseconds: UInt64 = 0, admissionNanoseconds: UInt64 = 0, vtSubmitNanoseconds: UInt64 = 0) {
        self.frameID = frameID; self.generation = generation; self.callbackNanoseconds = callbackNanoseconds
        self.firstPacketNanoseconds = firstPacketNanoseconds; self.hostProcessingMilliseconds = hostProcessingMilliseconds
        self.scheduledArrivalNanoseconds = scheduledArrivalNanoseconds
        self.admissionNanoseconds = admissionNanoseconds; self.vtSubmitNanoseconds = vtSubmitNanoseconds
    }
}

struct FrameRenderSubmissionMetadata: Sendable {
    let surface: PresentationSubmissionTiming?
    let renderStartSeconds: Double
    var commitSeconds: Double?
    var scheduledCallbackSeconds: Double? = nil
    var kernelStartSeconds: Double? = nil
    var kernelEndSeconds: Double? = nil
    var gpuStartSeconds: Double? = nil
    var gpuEndSeconds: Double? = nil
    var completedCallbackSeconds: Double? = nil
    var presentedCallbackSeconds: Double? = nil
}

/// Scalar state shared only through the renderer metrics lock, retained by the
/// scheduled/completed command handlers. Independent of presentation joins so
/// zero presentedTime callbacks cannot discard CPU/GPU stage metadata.
private final class GPUFrameSubmissionStamp: @unchecked Sendable {
    var timing: FrameRenderSubmissionMetadata
    init(_ timing: FrameRenderSubmissionMetadata) { self.timing = timing }
}

/// Join GPU and presentation callbacks in either order, under the renderer's
/// metrics lock. No object here owns a frame, texture, drawable, or command buffer.
/// Missing callbacks cannot grow the storage beyond 1024 submitted drawables.
struct PresentationTimingJoiner {
    struct Resolved {
        let frame: FramePresentationMetadata
        let presented: Double
        let calibration: PresentationClockCalibration?
        let submission: FrameRenderSubmissionMetadata
    }
    private struct Entry {
        let frame: FramePresentationMetadata
        var submission: FrameRenderSubmissionMetadata
        var presentation: (seconds: Double, calibration: PresentationClockCalibration?)?
    }
    private var entries: [UInt64: Entry] = [:]
    private var slots = [UInt64?](repeating: nil, count: 1024)
    private var nextID: UInt64 = 0
    private(set) var pendingPresentation = 0
    private(set) var pendingPresentationHighWater = 0
    private(set) var evictions = 0
    private(set) var presented = 0
    private(set) var unconfirmedPresentation = 0
    var count: Int { entries.count }
    var completedAwaitingPresentation: Int {
        entries.values.filter { $0.presentation == nil && $0.submission.completedCallbackSeconds != nil }.count
    }

    mutating func begin(_ frame: FramePresentationMetadata, submission: FrameRenderSubmissionMetadata) -> UInt64 {
        let id = nextID; nextID &+= 1
        let index = Int(id % 1024)
        if let old = slots[index], let removed = entries.removeValue(forKey: old) {
            evictions += 1
            if removed.presentation == nil { pendingPresentation -= 1 }
        }
        slots[index] = id
        entries[id] = Entry(frame: frame, submission: submission)
        pendingPresentation += 1
        pendingPresentationHighWater = max(pendingPresentationHighWater, pendingPresentation)
        return id
    }
    mutating func committed(_ id: UInt64, at seconds: Double) {
        entries[id]?.submission.commitSeconds = seconds
    }
    mutating func scheduled(_ id: UInt64, at seconds: Double) {
        entries[id]?.submission.scheduledCallbackSeconds = seconds
    }
    mutating func completed(_ id: UInt64, gpuStart: Double, gpuEnd: Double, at seconds: Double,
                            kernelStart: Double = 0, kernelEnd: Double = 0) -> Resolved? {
        guard entries[id] != nil else { return nil }
        entries[id]?.submission.gpuStartSeconds = gpuStart
        entries[id]?.submission.gpuEndSeconds = gpuEnd
        entries[id]?.submission.completedCallbackSeconds = seconds
        entries[id]?.submission.kernelStartSeconds = kernelStart
        entries[id]?.submission.kernelEndSeconds = kernelEnd
        return resolve(id)
    }
    mutating func presented(_ id: UInt64, at seconds: Double, callbackSeconds: Double,
                            calibration: PresentationClockCalibration?) -> Resolved? {
        guard var entry = entries[id], entry.presentation == nil else { return nil }
        pendingPresentation -= 1
        guard seconds.isFinite, seconds > 0, seconds * 1_000_000_000 < Double(UInt64.max) else {
            unconfirmedPresentation += 1
            entries.removeValue(forKey: id)
            return nil
        }
        presented += 1
        entry.presentation = (seconds, calibration)
        entry.submission.presentedCallbackSeconds = callbackSeconds
        entries[id] = entry
        return resolve(id)
    }
    private mutating func resolve(_ id: UInt64) -> Resolved? {
        guard let entry = entries[id], let presentation = entry.presentation,
              entry.submission.completedCallbackSeconds != nil else { return nil }
        entries.removeValue(forKey: id)
        return Resolved(frame: entry.frame, presented: presentation.seconds,
            calibration: presentation.calibration, submission: entry.submission)
    }
}

/// Caller holds the renderer metrics lock. Ring indices and identity map never
/// exceed 1024 entries; no API calls or externally supplied closures run here.
struct PresentationTimingWindow {
    private struct Identity: Hashable {
        let frameID: UInt64
        let generation: UInt64
        let callbackNanoseconds: UInt64
    }
    private(set) var samples: [FramePresentationTiming] = []
    private var indices: [Identity: Int] = [:]
    private var nextIndex = 0
    mutating func record(_ frame: FramePresentationMetadata, presented: Double, calibration: PresentationClockCalibration?,
                         submission: FrameRenderSubmissionMetadata? = nil) {
        guard presented.isFinite, presented > 0, presented * 1_000_000_000 < Double(UInt64.max) else { return }
        let actual = UInt64(presented * 1_000_000_000)
        let key = Identity(frameID: frame.frameID, generation: frame.generation, callbackNanoseconds: frame.callbackNanoseconds)
        if let index = indices[key], samples[index].actualPresentationNanoseconds <= actual { return }
        let latency = frame.callbackNanoseconds >= frame.firstPacketNanoseconds && frame.callbackNanoseconds != 0 ?
            calibration?.milliseconds(from: frame.firstPacketNanoseconds, toPresentedSeconds: presented) : nil
        let host = frame.hostProcessingMilliseconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let renderStart = validTimestamp(submission?.renderStartSeconds)
        let committed = validTimestamp(submission?.commitSeconds)
        let scheduled = validTimestamp(submission?.scheduledCallbackSeconds)
        let kernelStart = validTimestamp(submission?.kernelStartSeconds)
        let kernelEnd = validTimestamp(submission?.kernelEndSeconds)
        let gpuStart = validTimestamp(submission?.gpuStartSeconds)
        let gpuEnd = validTimestamp(submission?.gpuEndSeconds)
        let completed = validTimestamp(submission?.completedCallbackSeconds)
        let presentedCallback = validTimestamp(submission?.presentedCallbackSeconds)
        let surface = submission?.surface
        let selected = validTimestamp(surface?.selectedAtSeconds)
        let displayCallback = validTimestamp(surface?.displayCallbackSeconds)
        let deadline = validTimestamp(surface?.targetDeadlineSeconds)
        let target = validTimestamp(surface?.targetPresentationSeconds)
        let sample = FramePresentationTiming(frameID: frame.frameID, generation: frame.generation,
            callbackNanoseconds: frame.callbackNanoseconds, actualPresentationNanoseconds: actual,
            firstPacketToPresentationMilliseconds: latency, hostProcessingMilliseconds: host,
            calibrationUncertaintyNanoseconds: latency == nil ? nil : calibration?.uncertaintyNanoseconds,
            firstPacketToArrivalMilliseconds: decoderInterval(frame.firstPacketNanoseconds, frame.scheduledArrivalNanoseconds),
            arrivalToAdmissionMilliseconds: decoderInterval(frame.scheduledArrivalNanoseconds, frame.admissionNanoseconds),
            admissionToVTSubmitMilliseconds: decoderInterval(frame.admissionNanoseconds, frame.vtSubmitNanoseconds),
            vtSubmitToDecodeCallbackMilliseconds: decoderInterval(frame.vtSubmitNanoseconds, frame.callbackNanoseconds),
            firstPacketToDecodeCallbackMilliseconds: decoderInterval(frame.firstPacketNanoseconds, frame.callbackNanoseconds),
            decodeCallbackToSelectionMilliseconds: selected.flatMap { calibration?.milliseconds(from: frame.callbackNanoseconds, toPresentedSeconds: $0) },
            decodeCallbackToRenderStartMilliseconds: renderStart.flatMap { calibration?.milliseconds(from: frame.callbackNanoseconds, toPresentedSeconds: $0) },
            displayCallbackToRenderStartMilliseconds: caInterval(displayCallback, renderStart),
            selectionToRenderStartMilliseconds: caInterval(selected, renderStart),
            drawableAcquisitionMilliseconds: surface?.drawableAcquisitionMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            renderCPUToCommitMilliseconds: caInterval(renderStart, committed),
            commitToPresentationMilliseconds: caInterval(committed, presented),
            commitToScheduledCallbackMilliseconds: caInterval(committed, scheduled),
            commitToKernelStartMilliseconds: caInterval(committed, kernelStart),
            kernelSchedulingMilliseconds: caInterval(kernelStart, kernelEnd),
            kernelEndToScheduledCallbackMilliseconds: caInterval(kernelEnd, scheduled),
            commitToGPUStartMilliseconds: caInterval(committed, gpuStart),
            gpuExecutionMilliseconds: caInterval(gpuStart, gpuEnd),
            gpuEndToPresentationMilliseconds: caInterval(gpuEnd, presented),
            gpuEndToCompletedCallbackMilliseconds: caInterval(gpuEnd, completed),
            presentationToPresentedCallbackMilliseconds: caInterval(presented, presentedCallback),
            deadlineToCommitMilliseconds: caInterval(deadline, committed, signed: true),
            targetPresentationToPresentationMilliseconds: caInterval(target, presented, signed: true),
            displayCallbackSeconds: displayCallback, targetDeadlineSeconds: deadline, targetPresentationSeconds: target,
            selectedAtSeconds: selected, renderStartSeconds: renderStart, commitSeconds: committed,
            scheduledCallbackSeconds: scheduled, kernelStartSeconds: kernelStart, kernelEndSeconds: kernelEnd,
            gpuStartSeconds: gpuStart, gpuEndSeconds: gpuEnd,
            completedCallbackSeconds: completed, presentedCallbackSeconds: presentedCallback)
        if let index = indices[key] { samples[index] = sample }
        else if samples.count < 1024 { indices[key] = samples.count; samples.append(sample) }
        else {
            let old = samples[nextIndex]
            indices.removeValue(forKey: Identity(frameID: old.frameID, generation: old.generation, callbackNanoseconds: old.callbackNanoseconds))
            samples[nextIndex] = sample; indices[key] = nextIndex; nextIndex = (nextIndex + 1) % 1024
        }
    }

    private func validTimestamp(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
    private func decoderInterval(_ start: UInt64, _ end: UInt64) -> Double? {
        guard start != 0, end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }
    private func caInterval(_ start: Double?, _ end: Double?, signed: Bool = false) -> Double? {
        guard let start = validTimestamp(start), let end = validTimestamp(end), signed || end >= start else { return nil }
        return (end - start) * 1000
    }
}
public struct RenderResult: Sendable {
    public let succeeded: Bool
    public let gpuMilliseconds: Double?
}
public enum VideoScaleMode: Sendable { case fit, fill, integer }
/// Describes the values written by the shader. The surface must tag its Metal
/// layer with the matching color space before acquiring a drawable.
public enum VideoOutputColorSpace: Sendable {
    /// Extended linear sRGB; PQ content uses 203 nits as reference white.
    case linearSRGB
    /// BT.2020 RGB retaining the source PQ transfer function. The surface uses
    /// BGR10A2Unorm and the ITU-R 2100 PQ color space for this experimental path.
    case rec2020PQ
}
public enum RendererFailure: Error, CustomStringConvertible {
    case unavailable(String), unsupportedFormat(OSType), unsupportedColor(String)
    public var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .unsupportedFormat(let format): return "Unsupported canonical pixel format: \(format)"
        case .unsupportedColor(let reason): return "Unsupported color signaling: \(reason)"
        }
    }
}

/// Strong ownership spans GPU completion, including CoreVideo wrappers. Populated
/// before commit, cleared only by its single completion handler after GPU execution;
/// no other thread accesses fields after commit. MTLTexture alone is insufficient.
private final class TextureLease: @unchecked Sendable {
    private var frame: DecodedFrame?
    private var y: CVMetalTexture?
    private var uv: CVMetalTexture?
    private var overlay: MTLTexture?
    init(frame: DecodedFrame, y: CVMetalTexture, uv: CVMetalTexture) { self.frame = frame; self.y = y; self.uv = uv }
    func retainOverlay(_ texture: MTLTexture) { overlay = texture }
    func releaseAfterGPUCompletion() { overlay = nil; uv = nil; y = nil; frame = nil }
}

private struct OverlayTexture {
    let bitmap: VideoOverlayBitmap
    let texture: MTLTexture
}

private struct OverlayUniforms {
    var rectangle: SIMD4<Float>
    var mode: SIMD4<UInt32>
}

private struct ShaderUniforms {
    var yScaleOffset: SIMD4<Float>
    var chromaScaleOffset: SIMD4<Float>
    var sampleScale: SIMD4<Float>
    var chromaPosition: SIMD4<Float>
    var sourceOrigin: SIMD4<Float>
    var coefficients: SIMD4<Float>
    var mode: SIMD4<UInt32>
}

/// Encoding/cache access is serialized separately from bounded metrics. No Core
/// Animation or Metal call runs under the metrics lock acquired by callbacks. Drawable
/// registration/presentation and commit also run outside the encoding lock: Core
/// Animation may invoke presented handlers while holding its own drawable lock.
/// No synchronous GPU waits are performed here. Default SDR/HDR output is extended
/// linear sRGB, where 1.0 represents 203 nits for PQ and SDR reference white for SDR.
public final class MetalVideoRenderer: @unchecked Sendable {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var cache: CVMetalTextureCache
    private var pipelines: [UInt: MTLRenderPipelineState] = [:]
    private var overlayPipelines: [UInt: MTLRenderPipelineState] = [:]
    private var overlay: OverlayTexture?
    private let encodingLock = NSLock()
    private let lock = NSLock()
    private var counters = RenderStatistics()
    private var presentationWindow = PresentationTimingWindow()
    private var presentationJoiner = PresentationTimingJoiner()
    private var gpuTimingWindow = GPUFrameTimingWindow()
    private let maximumInFlight: Int
    private let captureScheduledCallback: Bool
    private let idle = DispatchGroup()

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), maximumInFlight: Int = 3, captureScheduledCallback: Bool = true) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RendererFailure.unavailable("Metal device/queue unavailable") }
        self.captureScheduledCallback = captureScheduledCallback
        self.device = device; self.queue = queue; self.maximumInFlight = max(1, min(maximumInFlight, 3))
        library = try device.makeLibrary(source: Self.shader, options: nil)
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard status == kCVReturnSuccess, let textureCache else { throw RendererFailure.unavailable("CVMetalTextureCacheCreate: \(status)") }
        cache = textureCache
    }
    public var statistics: RenderStatistics {
        lock.lock(); defer { lock.unlock() }
        var result = counters
        result.presentationTimings = presentationWindow.samples
        result.completedFrameTimings = gpuTimingWindow.samples
        result.presented = presentationJoiner.presented
        result.unconfirmedPresentation = presentationJoiner.unconfirmedPresentation
        result.pendingPresentation = presentationJoiner.pendingPresentation
        result.pendingPresentationHighWater = presentationJoiner.pendingPresentationHighWater
        result.completedAwaitingPresentation = presentationJoiner.completedAwaitingPresentation
        result.presentationTimingJoinEvictions = presentationJoiner.evictions
        return result
    }

    /// Replaces an immutable texture only when bitmap content changes. Existing
    /// commands keep their previous texture through GPU completion. This adds no
    /// render pass, command buffer, drawable, or Core Animation layer.
    public func setOverlay(_ bitmap: VideoOverlayBitmap?) throws {
        encodingLock.lock(); defer { encodingLock.unlock() }
        guard let bitmap else { overlay = nil; return }
        try bitmap.validate()
        if let old = overlay, old.bitmap.width == bitmap.width, old.bitmap.height == bitmap.height,
           old.bitmap.rgba8 == bitmap.rgba8 {
            overlay = OverlayTexture(bitmap: bitmap, texture: old.texture)
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: bitmap.width, height: bitmap.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererFailure.unavailable("Overlay texture allocation failed")
        }
        bitmap.rgba8.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bitmap.width * 4)
        }
        overlay = OverlayTexture(bitmap: bitmap, texture: texture)
        lock.lock(); counters.overlayUploads += 1; lock.unlock()
    }

    /// Called under encodingLock. Each drawable format gets one cached blend
    /// pipeline; premultiplication happens after color conversion in the shader.
    private func overlayPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipeline = overlayPipelines[format.rawValue] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "overlayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "overlayFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = format; color.isBlendingEnabled = true
        color.rgbBlendOperation = .add; color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        overlayPipelines[format.rawValue] = pipeline
        return pipeline
    }
    /// Correctness/teardown diagnostic only; the display path never calls this.
    public func waitUntilIdleForValidation(timeoutSeconds: Double = 10) throws {
        guard idle.wait(timeout: .now() + timeoutSeconds) == .success else { throw RendererFailure.unavailable("GPU completion timeout") }
    }

    /// Uses the display-link supplied drawable. A nil/missing drawable is handled by
    /// the surface before taking the latest frame. No second drawable is acquired.
    @discardableResult
    public func render(_ frame: DecodedFrame, into drawable: CAMetalDrawable,
                       scaleMode: VideoScaleMode = .fit,
                       outputColorSpace: VideoOutputColorSpace = .linearSRGB,
                       submissionTiming: PresentationSubmissionTiming? = nil,
                       completion: (@Sendable (RenderResult) -> Void)? = nil) throws -> Bool {
        let renderStart = CACurrentMediaTime()
        return try encode(frame, target: drawable.texture, drawable: drawable, present: { $0.present(drawable) }, scaleMode: scaleMode,
            completion: completion, outputColorSpace: outputColorSpace,
            submissionTiming: submissionTiming, renderStartSeconds: renderStart)
    }

    /// Validation uses this exact import, pipeline and shader, with a shared float target.
    public func makeReadbackTarget(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RendererFailure.unavailable("Readback target allocation failed") }
        return texture
    }
    @discardableResult
    public func render(_ frame: DecodedFrame, into target: MTLTexture,
                       scaleMode: VideoScaleMode = .fit,
                       outputColorSpace: VideoOutputColorSpace = .linearSRGB,
                       completion: (@Sendable (RenderResult) -> Void)? = nil) throws -> Bool {
        try encode(frame, target: target, drawable: nil, present: nil, scaleMode: scaleMode,
            completion: completion, outputColorSpace: outputColorSpace)
    }

    // Separate the presentation action from callback registration so a deterministic
    // test can exercise the real lock ordering without opening a display surface.
    func encode(_ frame: DecodedFrame, target: MTLTexture, drawable: MTLDrawable?,
                present: ((MTLCommandBuffer) -> Void)?, scaleMode: VideoScaleMode,
                completion: (@Sendable (RenderResult) -> Void)?, outputColorSpace: VideoOutputColorSpace = .linearSRGB,
                submissionTiming: PresentationSubmissionTiming? = nil,
                renderStartSeconds: Double? = nil) throws -> Bool {
        let renderStart = renderStartSeconds ?? CACurrentMediaTime()
        encodingLock.lock()
        var encodingLocked = true
        defer { if encodingLocked { encodingLock.unlock() } }
        lock.lock()
        guard counters.inFlight < maximumInFlight else {
            counters.skippedGPUCapacity += 1; lock.unlock(); return false
        }
        lock.unlock()
        switch outputColorSpace {
        case .linearSRGB:
            guard target.pixelFormat == .rgba16Float || target.pixelFormat == .rgba32Float else {
                throw RendererFailure.unavailable("Linear floating-point drawable required")
            }
        case .rec2020PQ:
            guard frame.color.transfer == 16, frame.color.primaries == 9, frame.color.matrix == 9 else {
                throw RendererFailure.unsupportedColor("Native PQ output requires BT.2020 primaries/matrix and PQ transfer")
            }
            guard target.pixelFormat == .bgr10a2Unorm || target.pixelFormat == .rgba32Float else {
                throw RendererFailure.unavailable("Native PQ output requires BGR10A2Unorm or a floating-point readback target")
            }
        }
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let tenBit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: tenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: tenBit = true
        default: throw RendererFailure.unsupportedFormat(format)
        }
        guard CVPixelBufferGetPlaneCount(frame.pixelBuffer) == 2 else { throw RendererFailure.unsupportedFormat(format) }
        guard [UInt16(1), 5, 6, 9].contains(frame.color.matrix), [UInt16(1), 6, 13, 16].contains(frame.color.transfer),
              [UInt16(1), 9].contains(frame.color.primaries) else {
            throw RendererFailure.unsupportedColor("matrix \(frame.color.matrix), transfer \(frame.color.transfer), primaries \(frame.color.primaries)")
        }
        var wrappers: [CVMetalTexture] = []
        var textures: [MTLTexture] = []
        for plane in 0..<2 {
            var wrapper: CVMetalTexture?
            let pixelFormat: MTLPixelFormat = plane == 0 ? (tenBit ? .r16Unorm : .r8Unorm) : (tenBit ? .rg16Unorm : .rg8Unorm)
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, frame.pixelBuffer, nil, pixelFormat,
                CVPixelBufferGetWidthOfPlane(frame.pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(frame.pixelBuffer, plane), plane, &wrapper)
            guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
                throw RendererFailure.unavailable("CoreVideo Metal plane \(plane) import failed: \(status)")
            }
            wrappers.append(wrapper); textures.append(texture)
        }
        let lease = TextureLease(frame: frame, y: wrappers[0], uv: wrappers[1])
        let frameOverlay = overlay
        let pipeline: MTLRenderPipelineState
        if let cached = pipelines[target.pixelFormat.rawValue] { pipeline = cached }
        else {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "videoFragment")
            descriptor.colorAttachments[0].pixelFormat = target.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[target.pixelFormat.rawValue] = pipeline
            // Compile both pipelines at stream/format startup so opening the HUD
            // cannot synchronously compile a new Metal pipeline on a video frame.
            _ = try overlayPipeline(for: target.pixelFormat)
        }
        let frameOverlayPipeline = try frameOverlay.map { _ in try overlayPipeline(for: target.pixelFormat) }
        let denominator: Float = tenBit ? 65535.0 / 64.0 : 255
        let codeMax: Float = tenBit ? 1023 : 255
        let low: Float = frame.color.fullRange ? 0 : (tenBit ? 64 : 16)
        let span: Float = frame.color.fullRange ? codeMax : (tenBit ? 876 : 219)
        let chromaSpan: Float = frame.color.fullRange ? codeMax : (tenBit ? 896 : 224)
        let chromaCenter: Float = tenBit ? 512 : 128
        let kr: Float = frame.color.matrix == 9 ? 0.2627 : ([5, 6].contains(frame.color.matrix) ? 0.299 : 0.2126)
        let kb: Float = frame.color.matrix == 9 ? 0.0593 : ([5, 6].contains(frame.color.matrix) ? 0.114 : 0.0722)
        let location = frame.color.chromaLocation
        let shiftX: Float = [UInt8(0), 2, 4].contains(location) ? 0.5 : 0
        let shiftY: Float = [UInt8(2), 3].contains(location) ? 0.5 : ([UInt8(4), 5].contains(location) ? -0.5 : 0)
        var source = frame.contentRect
        if scaleMode == .fill {
            let ratio = CGFloat(target.width) / CGFloat(target.height)
            if source.width / source.height > ratio {
                let width = source.height * ratio; source.origin.x += (source.width - width) / 2; source.size.width = width
            } else {
                let height = source.width / ratio; source.origin.y += (source.height - height) / 2; source.size.height = height
            }
        }
        var uniforms = ShaderUniforms(
            yScaleOffset: SIMD4(denominator / span, -low / span, 0, 0),
            chromaScaleOffset: SIMD4(denominator / chromaSpan, -chromaCenter / chromaSpan, 0, 0),
            sampleScale: SIMD4(Float(source.width) / Float(textures[0].width), Float(source.height) / Float(textures[0].height),
                Float(source.width) / Float(textures[1].width * 2), Float(source.height) / Float(textures[1].height * 2)),
            chromaPosition: SIMD4(shiftX / Float(textures[1].width * 2), shiftY / Float(textures[1].height * 2), 0, 0),
            sourceOrigin: SIMD4(Float(source.minX) / Float(textures[0].width), Float(source.minY) / Float(textures[0].height),
                Float(source.minX) / Float(textures[1].width * 2), Float(source.minY) / Float(textures[1].height * 2)),
            coefficients: SIMD4(kr, kb, 0, 0), mode: SIMD4(UInt32(frame.color.transfer), UInt32(frame.color.primaries),
                outputColorSpace == .rec2020PQ ? 1 : 0, 0))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererFailure.unavailable("Metal command allocation failed")
        }
        let fit = min(Double(target.width) / Double(source.width), Double(target.height) / Double(source.height))
        let scale = scaleMode == .integer && fit >= 1 ? floor(fit) : fit
        let width = Double(source.width) * scale, height = Double(source.height) * scale
        encoder.setViewport(MTLViewport(originX: (Double(target.width) - width) / 2, originY: (Double(target.height) - height) / 2,
            width: width, height: height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(textures[0], index: 0); encoder.setFragmentTexture(textures[1], index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let frameOverlay, let frameOverlayPipeline {
            let bitmap = frameOverlay.bitmap
            let insetX = min(bitmap.insetPixels, max(0, target.width - bitmap.width))
            let insetY = min(bitmap.insetPixels, max(0, target.height - bitmap.height))
            let originX: Int
            switch bitmap.position {
            case .topLeft: originX = insetX
            case .topCenter: originX = max(0, (target.width - bitmap.width) / 2)
            case .topRight: originX = max(0, target.width - bitmap.width - insetX)
            }
            var overlayUniforms = OverlayUniforms(rectangle: SIMD4(
                Float(originX) / Float(target.width), Float(insetY) / Float(target.height),
                Float(bitmap.width) / Float(target.width), Float(bitmap.height) / Float(target.height)),
                mode: SIMD4(outputColorSpace == .rec2020PQ ? 1 : 0, 0, 0, 0))
            encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width),
                height: Double(target.height), znear: 0, zfar: 1))
            encoder.setRenderPipelineState(frameOverlayPipeline)
            encoder.setVertexBytes(&overlayUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&overlayUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            encoder.setFragmentTexture(frameOverlay.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            lease.retainOverlay(frameOverlay.texture)
        }
        encoder.endEncoding()
        let frameTiming = FramePresentationMetadata(frame)
        let gpuStamp = GPUFrameSubmissionStamp(FrameRenderSubmissionMetadata(surface: submissionTiming,
            renderStartSeconds: renderStart, commitSeconds: nil))
        lock.lock()
        counters.submitted += 1; counters.inFlight += 1; counters.inFlightHighWater = max(counters.inFlightHighWater, counters.inFlight)
        if frameOverlay != nil { counters.overlayDraws += 1 }
        let presentationID = drawable == nil ? nil : presentationJoiner.begin(frameTiming, submission: gpuStamp.timing)
        lock.unlock()
        idle.enter()
        // Preserve command ordering for concurrent callers before releasing encoding
        // serialization. No callback can need this lock, and metrics are unlocked.
        command.enqueue()
        encodingLock.unlock(); encodingLocked = false
        if let drawable, let presentationID {
            drawable.addPresentedHandler { [weak self] presented in
                guard let self else { return }
                let callbackSeconds = CACurrentMediaTime()
                let presentedTime = presented.presentedTime
                // Core Animation owns callback invocation. Read all clocks and API
                // properties before taking our metrics lock (the live lock-cycle fix).
                let calibration = presentedTime.isFinite && presentedTime > 0 ? PresentationClockCalibration.measure() : nil
                self.lock.lock(); defer { self.lock.unlock() }
                self.recordResolvedPresentation(self.presentationJoiner.presented(presentationID, at: presentedTime,
                    callbackSeconds: callbackSeconds, calibration: calibration))
            }
            present?(command)
        }
        if captureScheduledCallback { command.addScheduledHandler { [weak self] _ in
            let callbackSeconds = CACurrentMediaTime()
            guard let self else { return }
            self.lock.lock()
            gpuStamp.timing.scheduledCallbackSeconds = callbackSeconds
            if let presentationID { self.presentationJoiner.scheduled(presentationID, at: callbackSeconds) }
            self.lock.unlock()
        } }
        command.addCompletedHandler { [self, lease] command in
            let callbackSeconds = CACurrentMediaTime()
            let gpuStart = command.gpuStartTime, gpuEnd = command.gpuEndTime
            let kernelStart = command.kernelStartTime, kernelEnd = command.kernelEndTime
            let succeeded = command.status == .completed
            let duration = gpuStart.isFinite && gpuEnd.isFinite && gpuStart > 0 && gpuEnd >= gpuStart ? (gpuEnd - gpuStart) * 1000 : nil
            let calibration = PresentationClockCalibration.measure()
            self.lock.lock()
            self.counters.completed += 1; self.counters.inFlight -= 1
            gpuStamp.timing.gpuStartSeconds = gpuStart; gpuStamp.timing.gpuEndSeconds = gpuEnd
            gpuStamp.timing.kernelStartSeconds = kernelStart; gpuStamp.timing.kernelEndSeconds = kernelEnd
            gpuStamp.timing.completedCallbackSeconds = callbackSeconds
            self.gpuTimingWindow.record(GPUFrameTiming(frameTiming, submission: gpuStamp.timing,
                succeeded: succeeded, calibration: calibration))
            if let presentationID {
                self.recordResolvedPresentation(self.presentationJoiner.completed(presentationID,
                    gpuStart: gpuStart, gpuEnd: gpuEnd, at: callbackSeconds, kernelStart: kernelStart, kernelEnd: kernelEnd))
            }
            if let duration {
                if self.counters.gpuMilliseconds.count == 1024 { self.counters.gpuMilliseconds.removeFirst() }
                self.counters.gpuMilliseconds.append(duration)
            }
            self.lock.unlock()
            withExtendedLifetime(lease) { completion?(RenderResult(succeeded: succeeded, gpuMilliseconds: duration)) }
            lease.releaseAfterGPUCompletion()
            self.idle.leave()
        }
        let commitSeconds = CACurrentMediaTime()
        lock.lock()
        gpuStamp.timing.commitSeconds = commitSeconds
        if let presentationID { presentationJoiner.committed(presentationID, at: commitSeconds) }
        lock.unlock()
        command.commit()
        return true
    }

    /// Caller holds only the metrics lock. The join carries scalar values only.
    private func recordResolvedPresentation(_ resolved: PresentationTimingJoiner.Resolved?) {
        guard let resolved else { return }
        if counters.actualPresentationNanoseconds.count == 1024 { counters.actualPresentationNanoseconds.removeFirst() }
        counters.actualPresentationNanoseconds.append(UInt64(resolved.presented * 1_000_000_000))
        presentationWindow.record(resolved.frame, presented: resolved.presented, calibration: resolved.calibration,
            submission: resolved.submission)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4 y; float4 c; float4 scale; float4 chroma; float4 origin; float4 coefficients; uint4 mode; };
    struct OverlayUniforms { float4 rectangle; uint4 mode; };
    vertex Vertex overlayVertex(uint id [[vertex_id]], constant OverlayUniforms& u [[buffer(0)]]) {
        constexpr float2 corners[6] = {float2(0,0),float2(0,1),float2(1,0),float2(1,0),float2(0,1),float2(1,1)};
        float2 uv = corners[id];
        float2 position = u.rectangle.xy + uv * u.rectangle.zw;
        return {float4(position * float2(2,-2) + float2(-1,1),0,1), uv};
    }
    fragment float4 overlayFragment(Vertex input [[stage_in]], texture2d<float> bitmap [[texture(0)]],
        constant OverlayUniforms& u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        float4 pixel = bitmap.sample(s,input.uv);
        if(pixel.a <= 0) return float4(0);
        // CPU rasters are premultiplied in sRGB code space. Undo premultiplication
        // before EOTF, then premultiply in the drawable's output color space.
        float3 rgb = clamp(pixel.rgb / pixel.a, 0.0f, 1.0f);
        rgb = select(rgb / 12.92f, pow((rgb + 0.055f) / 1.055f, 2.4f), rgb > 0.04045f);
        if(u.mode.x == 1) {
            rgb = float3(dot(rgb,float3(0.627404,0.329283,0.043313)),
                dot(rgb,float3(0.069097,0.919540,0.011363)),dot(rgb,float3(0.016391,0.088013,0.895596)));
            constexpr float m1=2610.0/16384.0, m2=2523.0/32.0, c1=3424.0/4096.0, c2=2413.0/128.0, c3=2392.0/128.0;
            float3 p = pow(max(rgb,0.0f) * (203.0f / 10000.0f), m1);
            rgb = pow((c1 + c2 * p) / (1 + c3 * p), m2);
            // Native PQ blending occurs in nonlinear code space. This is intended
            // for monochrome text/panels; antialiased edges are approximate.
        }
        return float4(rgb * pixel.a, pixel.a);
    }
    vertex Vertex videoVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
        return {float4(p,0,1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
    }
    float3 linearize(float3 v, uint transfer) {
        v = max(v, 0.0f);
        if (transfer == 16) {
            constexpr float m1=2610.0/16384.0, m2=2523.0/32.0, c1=3424.0/4096.0, c2=2413.0/128.0, c3=2392.0/128.0;
            float3 p=pow(v, 1.0/m2);
            return pow(max(p-c1,0.0f)/max(c2-c3*p,1e-7f),1.0/m1)*(10000.0/203.0);
        }
        if (transfer == 13) return select(v/12.92,pow((v+0.055)/1.055,2.4),v>0.04045);
        return select(v/4.5,pow((v+0.099)/1.099,1.0/0.45),v>=0.081);
    }
    fragment float4 videoFragment(Vertex input [[stage_in]], texture2d<float> yTex [[texture(0)]],
        texture2d<float> uvTex [[texture(1)]], constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float y = yTex.sample(s,input.uv*u.scale.xy+u.origin.xy).r*u.y.x+u.y.y;
        float2 c = uvTex.sample(s,input.uv*u.scale.zw+u.origin.zw+u.chroma.xy).rg*u.c.x+u.c.y;
        float kr=u.coefficients.x, kb=u.coefficients.y, kg=1-kr-kb;
        float3 rgb=float3(y+2*(1-kr)*c.y, y-2*kb*(1-kb)/kg*c.x-2*kr*(1-kr)/kg*c.y, y+2*(1-kb)*c.x);
        // Native PQ drawables carry nonlinear BT.2020 components. Core Animation
        // applies the layer's ITU-R 2100 PQ color space; do not apply EOTF or gamut
        // conversion here a second time. Keep float readbacks unquantized.
        if(u.mode.z == 1) return float4(rgb,1);
        rgb=linearize(rgb,u.mode.x);
        if(u.mode.y == 9) rgb=float3(dot(rgb,float3(1.660491,-0.587641,-0.072850)),
            dot(rgb,float3(-0.124550,1.132900,-0.008349)),dot(rgb,float3(-0.018151,-0.100579,1.118730)));
        return float4(rgb,1);
    }
    """
}
