import Foundation
import CoreVideo
import Metal
import MoonlightAppleVideo
import CNativeVideoABI
import CPyrowaveBridge

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case hevc, av1, pyrowave
    var native: mav_codec {
        switch self {
        case .hevc: MAV_CODEC_HEVC
        case .av1: MAV_CODEC_AV1
        case .pyrowave: preconditionFailure("PyroWave uses its direct Metal backend")
        }
    }
    public var hardwareCandidate: Bool {
        if self == .pyrowave { return sp_device_is_supported() != 0 }
        var value = mav_capability()
        value.struct_size = UInt32(MemoryLayout<mav_capability>.size); value.version = UInt32(MAV_ABI_VERSION)
        return mav_query_capability(native, &value) == MAV_OK && value.hardware_decode_candidate != 0
    }
}

public struct VideoFailure: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: UInt32
    public var description: String { "\(operation): \(String(cString: mav_result_string(mav_result(rawValue: code)))) (\(code))" }
    init(_ operation: String, _ result: mav_result) { self.operation = operation; code = result.rawValue }
}

public struct CompressedFrame: Sendable {
    public var bytes: Data
    public var id: UInt64
    public var presentationTimeNanoseconds: Int64
    public var randomAccess: Bool
    /// These timestamps MUST already be in mav_monotonic_time_ns's clock domain.
    public var arrivalNanoseconds: UInt64
    public var firstPacketNanoseconds: UInt64
    /// Optional host-reported duration, not a timestamp in the host's clock domain.
    public var hostProcessingMilliseconds: Double?
    public var pyrowaveFragments: [PyrowavePacketFragment]
    public var pyrowaveCriticalPackets: UInt32
    public var color: VideoColor?
    public init(bytes: Data, id: UInt64, presentationTimeNanoseconds: Int64 = 0, randomAccess: Bool = false,
                arrivalNanoseconds: UInt64 = 0, firstPacketNanoseconds: UInt64 = 0,
                hostProcessingMilliseconds: Double? = nil,
                pyrowaveFragments: [PyrowavePacketFragment] = [], pyrowaveCriticalPackets: UInt32 = 0, color: VideoColor? = nil) {
        self.bytes = bytes; self.id = id; self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.randomAccess = randomAccess; self.arrivalNanoseconds = arrivalNanoseconds; self.firstPacketNanoseconds = firstPacketNanoseconds
        self.hostProcessingMilliseconds = hostProcessingMilliseconds
        self.pyrowaveFragments = pyrowaveFragments; self.pyrowaveCriticalPackets = pyrowaveCriticalPackets
        self.color = color
    }
}

/// Packet boundaries in the flattened access unit. Loss is distinct from zero coefficients.
public struct PyrowavePacketFragment: Sendable {
    public let offset: UInt32
    public let size: UInt32
    public let kind: UInt32
    public init(offset: UInt32, size: UInt32, kind: UInt32) {
        self.offset = offset; self.size = size; self.kind = kind
    }
}

/// Immutable GPU output. The retained C lease prevents pooled textures from being reused
/// until the last mailbox/render owner releases it, including after decoder destruction.
final class PyrowaveGPUFrame: @unchecked Sendable {
    let handle: OpaquePointer?
    let planes: [MTLTexture]
    let chromaFormat: UInt32
    init?(_ handle: OpaquePointer) {
        sp_gpu_frame_retain(handle)
        var planes: [MTLTexture] = []
        for index in 0..<3 {
            guard let pointer = sp_gpu_frame_plane(handle, UInt32(index)),
                  let texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLTexture else {
                sp_gpu_frame_release(handle); return nil
            }
            planes.append(texture)
        }
        self.handle = handle; self.planes = planes; chromaFormat = sp_gpu_frame_chroma(handle)
    }
    /// Validation constructs immutable planes without a decoder pool.
    init(planes: [MTLTexture], chromaFormat: UInt32) {
        handle = nil; self.planes = planes; self.chromaFormat = chromaFormat
    }
    deinit { if let handle { sp_gpu_frame_release(handle) } }
}

public enum SubmissionResult: Sendable, Equatable {
    case accepted, wouldBlock, needsRandomAccess, rejected(UInt32)
}

public struct VideoColor: Codable, Sendable, Equatable {
    public var primaries: UInt16
    public var transfer: UInt16
    public var matrix: UInt16
    public var fullRange: Bool
    public var chromaLocation: UInt8
    public var mastering: [UInt8]
    public var contentLight: [UInt8]
    public var hasColorDescription: Bool
    public var hasRange: Bool
    public init(primaries: UInt16 = 1, transfer: UInt16 = 1, matrix: UInt16 = 1, fullRange: Bool = false,
                chromaLocation: UInt8 = 0, mastering: [UInt8] = [], contentLight: [UInt8] = [],
                hasColorDescription: Bool = true, hasRange: Bool = true) {
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix; self.fullRange = fullRange
        self.chromaLocation = chromaLocation; self.mastering = mastering; self.contentLight = contentLight
        self.hasColorDescription = hasColorDescription; self.hasRange = hasRange
    }
    init(_ value: mav_color) {
        let described = value.valid & UInt32(MAV_COLOR_DESCRIPTION) != 0
        hasColorDescription = described; hasRange = value.valid & UInt32(MAV_COLOR_RANGE) != 0
        primaries = described ? value.primaries : 1; transfer = described ? value.transfer : 1
        matrix = described ? value.matrix : 1; fullRange = value.valid & UInt32(MAV_COLOR_RANGE) != 0 && value.full_range != 0
        chromaLocation = value.valid & UInt32(MAV_COLOR_CHROMA_LOCATION) != 0 ? value.chroma_location : 0
        var source = value
        mastering = value.valid & UInt32(MAV_COLOR_MASTERING) != 0 ? withUnsafeBytes(of: &source.mastering) { Array($0) } : []
        contentLight = value.valid & UInt32(MAV_COLOR_CONTENT_LIGHT) != 0 ? withUnsafeBytes(of: &source.content_light) { Array($0) } : []
    }
    var native: mav_color {
        var value = mav_color()
        value.valid = UInt32(MAV_COLOR_CHROMA_LOCATION)
        if hasColorDescription { value.valid |= UInt32(MAV_COLOR_DESCRIPTION) }
        if hasRange { value.valid |= UInt32(MAV_COLOR_RANGE) }
        value.primaries = primaries; value.transfer = transfer; value.matrix = matrix
        value.full_range = fullRange ? 1 : 0; value.chroma_location = chromaLocation
        if mastering.count == 24 {
            value.valid |= UInt32(MAV_COLOR_MASTERING)
            withUnsafeMutableBytes(of: &value.mastering) { $0.copyBytes(from: mastering) }
        }
        if contentLight.count == 4 {
            value.valid |= UInt32(MAV_COLOR_CONTENT_LIGHT)
            withUnsafeMutableBytes(of: &value.content_light) { $0.copyBytes(from: contentLight) }
        }
        return value
    }
}

/// Decoder-confirmed output format. Width/height describe the decoded image, while
/// negotiated frame rate and dimensions remain separate transport information.
public struct DecodedVideoFormat: Codable, Sendable, Equatable {
    public let codec: VideoCodec
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let color: VideoColor
    public init(codec: VideoCodec, frame: DecodedFrame) {
        self.codec = codec; width = frame.width; height = frame.height; bitDepth = frame.bitDepth; color = frame.color
    }
}

/// Optional, codec-neutral stages from one decoder completion. All timestamps
/// share the native monotonic clock; mapped GPU times carry their own uncertainty.
/// These scalars retain no compressed data, output storage, or native owner.
public struct DecodeStageTiming: Codable, Sendable {
    public let preparationStartNanoseconds: UInt64?
    public let preparationEndNanoseconds: UInt64?
    public let backendStartNanoseconds: UInt64?
    public let backendSubmitNanoseconds: UInt64?
    public let backendReturnNanoseconds: UInt64?
    public let gpuCommitNanoseconds: UInt64?
    public let gpuStartNanoseconds: UInt64?
    public let gpuEndNanoseconds: UInt64?
    public let gpuClockUncertaintyNanoseconds: UInt64?
    public let admissionToPreparationStartMilliseconds: Double?
    public let preparationMilliseconds: Double?
    public let preparationEndToBackendStartMilliseconds: Double?
    public let backendPreparationMilliseconds: Double?
    /// VT DecodeFrame, or PyroWave's upload and Metal encoding call; not GPU time.
    public let backendCallMilliseconds: Double?
    public let backendReturnToCallbackMilliseconds: Double?
    public let backendReturnToGPUCommitMilliseconds: Double?
    public let gpuCommitToStartMilliseconds: Double?
    public let gpuExecutionMilliseconds: Double?
    public let gpuEndToCallbackMilliseconds: Double?
    public let admissionToCallbackMilliseconds: Double?

    init?(trace: mav_trace, backend: sva_decode_trace?, internalSamples: UInt32, showExisting: Bool) {
        func interval(_ start: UInt64?, _ end: UInt64?) -> Double? {
            guard let start, let end, start != 0, end >= start else { return nil }
            return Double(end - start) / 1_000_000
        }
        let admission = trace.admission_ns
        let callback = trace.valid & UInt32(MAV_TRACE_CALLBACK) != 0 ? trace.callback_ns : 0
        func bounded(_ value: UInt64) -> UInt64? {
            guard admission != 0, value >= admission, value != 0,
                  callback == 0 || value <= callback else { return nil }
            return value
        }
        let prepared = trace.valid & UInt32(MAV_TRACE_PREPARATION) != 0
        let preparationStart = prepared ? bounded(trace.preparation_start_ns) : nil
        let preparationEnd = prepared ? bounded(trace.preparation_end_ns) : nil
        let validPreparation = interval(preparationStart, preparationEnd) != nil
        preparationStartNanoseconds = validPreparation ? preparationStart : nil
        preparationEndNanoseconds = validPreparation ? preparationEnd : nil
        // Multi-sample and show-existing completions do not describe one new GPU
        // decode. Preparation remains meaningful; backend stages stay unavailable.
        let backend = internalSamples == 1 && !showExisting ? backend.flatMap {
            $0.version == UInt32(SVA_TRACE_VERSION) && $0.struct_size >= UInt32(MemoryLayout<sva_decode_trace>.size) ? $0 : nil
        } : nil
        func stage(_ flag: UInt32, _ value: UInt64?) -> UInt64? {
            guard let backend, backend.valid & flag != 0, let value else { return nil }
            return bounded(value)
        }
        backendStartNanoseconds = stage(UInt32(SVA_BACKEND_START), backend?.backend_start_ns)
        backendSubmitNanoseconds = stage(UInt32(SVA_BACKEND_SUBMIT), backend?.backend_submit_ns)
        backendReturnNanoseconds = stage(UInt32(SVA_BACKEND_RETURN), backend?.backend_return_ns)
        gpuCommitNanoseconds = stage(UInt32(SVA_GPU_COMMIT), backend?.gpu_commit_ns)
        let start = stage(UInt32(SVA_GPU_EXECUTION), backend?.gpu_start_ns)
        let end = stage(UInt32(SVA_GPU_EXECUTION), backend?.gpu_end_ns)
        let uncertainty = backend?.gpu_clock_uncertainty_ns
        let followsCommit = gpuCommitNanoseconds == nil || interval(gpuCommitNanoseconds, start) != nil
        let validGPU = followsCommit && interval(start, end) != nil && uncertainty.map { $0 <= 1_000_000 } == true
        gpuStartNanoseconds = validGPU ? start : nil; gpuEndNanoseconds = validGPU ? end : nil
        gpuClockUncertaintyNanoseconds = validGPU ? uncertainty : nil
        admissionToPreparationStartMilliseconds = interval(admission, preparationStartNanoseconds)
        preparationMilliseconds = interval(preparationStartNanoseconds, preparationEndNanoseconds)
        preparationEndToBackendStartMilliseconds = interval(preparationEndNanoseconds, backendStartNanoseconds)
        backendPreparationMilliseconds = interval(backendStartNanoseconds, backendSubmitNanoseconds)
        backendCallMilliseconds = interval(backendSubmitNanoseconds, backendReturnNanoseconds)
        backendReturnToCallbackMilliseconds = interval(backendReturnNanoseconds, callback)
        backendReturnToGPUCommitMilliseconds = interval(backendReturnNanoseconds, gpuCommitNanoseconds)
        gpuCommitToStartMilliseconds = interval(gpuCommitNanoseconds, gpuStartNanoseconds)
        gpuExecutionMilliseconds = interval(gpuStartNanoseconds, gpuEndNanoseconds)
        gpuEndToCallbackMilliseconds = interval(gpuEndNanoseconds, callback)
        admissionToCallbackMilliseconds = interval(admission, callback)
        guard preparationStartNanoseconds != nil || backendStartNanoseconds != nil ||
              backendSubmitNanoseconds != nil || backendReturnNanoseconds != nil ||
              gpuCommitNanoseconds != nil || gpuStartNanoseconds != nil else { return nil }
    }
}

/// Immutable after construction. ARC acquires the borrowed callback buffer on assignment.
/// Decoder output pixels are immutable; only CoreVideo/Metal read them. Passing this
/// owner between the locked mailbox and render queue is safe, never raw plane pointers.
public final class DecodedFrame: @unchecked Sendable {
    private static let ownership = FrameOwnership()
    public let pixelBuffer: CVPixelBuffer?
    let gpuFrame: PyrowaveGPUFrame?
    public let id: UInt64
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let color: VideoColor
    public let callbackNanoseconds: UInt64
    /// Zero means unavailable. These share mav_monotonic_time_ns's clock domain.
    public let firstPacketNanoseconds: UInt64
    public let scheduledArrivalNanoseconds: UInt64
    public let admissionNanoseconds: UInt64
    /// Single-sample decode only; zero for aggregate or show-existing completions.
    public let vtSubmitNanoseconds: UInt64
    public let decodeStages: DecodeStageTiming?
    public let hostProcessingMilliseconds: Double?
    public let hardwareAccelerated: Bool
    /// Visible source pixels, with top-left origin to match input coordinates and Metal.
    public var contentRect: CGRect {
        guard let pixelBuffer else { return CGRect(x: 0, y: 0, width: width, height: height) }
        let raw = CVImageBufferGetCleanRect(pixelBuffer)
        let physical = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let fallback = CGRect(x: 0, y: 0, width: min(width, CVPixelBufferGetWidth(pixelBuffer)), height: min(height, CVPixelBufferGetHeight(pixelBuffer)))
        let converted = CGRect(x: raw.minX, y: CGFloat(CVPixelBufferGetHeight(pixelBuffer)) - raw.maxY, width: raw.width, height: raw.height)
        // Clean aperture is in buffer coordinates. Clipping it to visible stream
        // dimensions would crop a padded buffer twice when its aperture is offset.
        let clipped = converted.intersection(physical)
        return clipped.isEmpty || clipped.isNull || clipped == physical ? fallback : clipped
    }
    public convenience init(pixelBuffer: CVPixelBuffer?, id: UInt64, generation: UInt64 = 0, width: Int, height: Int,
                bitDepth: Int, color: VideoColor, callbackNanoseconds: UInt64 = 0, hardwareAccelerated: Bool = false,
                firstPacketNanoseconds: UInt64 = 0, admissionNanoseconds: UInt64 = 0,
                hostProcessingMilliseconds: Double? = nil,
                scheduledArrivalNanoseconds: UInt64 = 0, vtSubmitNanoseconds: UInt64 = 0,
                decodeStages: DecodeStageTiming? = nil) {
        self.init(pixelBuffer: pixelBuffer, gpuFrame: nil, id: id, generation: generation, width: width, height: height,
            bitDepth: bitDepth, color: color, callbackNanoseconds: callbackNanoseconds, hardwareAccelerated: hardwareAccelerated,
            firstPacketNanoseconds: firstPacketNanoseconds, admissionNanoseconds: admissionNanoseconds,
            hostProcessingMilliseconds: hostProcessingMilliseconds, scheduledArrivalNanoseconds: scheduledArrivalNanoseconds,
            vtSubmitNanoseconds: vtSubmitNanoseconds, decodeStages: decodeStages)
    }
    init(pixelBuffer: CVPixelBuffer?, gpuFrame: PyrowaveGPUFrame?, id: UInt64, generation: UInt64, width: Int, height: Int,
         bitDepth: Int, color: VideoColor, callbackNanoseconds: UInt64, hardwareAccelerated: Bool,
         firstPacketNanoseconds: UInt64, admissionNanoseconds: UInt64, hostProcessingMilliseconds: Double?,
         scheduledArrivalNanoseconds: UInt64, vtSubmitNanoseconds: UInt64, decodeStages: DecodeStageTiming? = nil) {
        self.pixelBuffer = pixelBuffer; self.gpuFrame = gpuFrame
        self.id = id; self.generation = generation; self.width = width; self.height = height
        self.bitDepth = bitDepth; self.color = color; self.callbackNanoseconds = callbackNanoseconds; self.hardwareAccelerated = hardwareAccelerated
        self.firstPacketNanoseconds = firstPacketNanoseconds; self.admissionNanoseconds = admissionNanoseconds
        self.scheduledArrivalNanoseconds = scheduledArrivalNanoseconds; self.vtSubmitNanoseconds = vtSubmitNanoseconds
        self.decodeStages = decodeStages
        self.hostProcessingMilliseconds = hostProcessingMilliseconds
        Self.ownership.acquire()
    }
    deinit { Self.ownership.release() }
    public static var ownershipStatistics: FrameOwnershipStatistics { ownership.snapshot }
}

public struct FrameOwnershipStatistics: Codable, Sendable {
    public var acquired: UInt64 = 0
    public var released: UInt64 = 0
    public var live: UInt64 = 0
    public var highWater: UInt64 = 0
}
/// Process-wide diagnostic counters are protected by one lock, never expose buffers.
private final class FrameOwnership: @unchecked Sendable {
    let lock = NSLock()
    var state = FrameOwnershipStatistics()
    func acquire() { lock.lock(); state.acquired += 1; state.live += 1; state.highWater = max(state.highWater, state.live); lock.unlock() }
    func release() { lock.lock(); state.released += 1; state.live -= 1; lock.unlock() }
    var snapshot: FrameOwnershipStatistics { lock.lock(); defer { lock.unlock() }; return state }
}

/// A recent bounded sample window. Empty or invalid-only windows have no duration.
/// Durations are never substituted with zero when the corresponding clock is absent.
public struct TimingSummary: Codable, Sendable, Equatable {
    public let count: Int
    public let minimumMilliseconds: Double?
    public let maximumMilliseconds: Double?
    public let averageMilliseconds: Double?
    public init(milliseconds: [Double]) {
        let valid = milliseconds.suffix(1024).filter { $0.isFinite && $0 >= 0 }
        count = valid.count; minimumMilliseconds = valid.min(); maximumMilliseconds = valid.max()
        averageMilliseconds = valid.isEmpty ? nil : valid.reduce(0) { $0 + $1 / Double(valid.count) }
    }
}

public struct DecoderStatistics: Codable, Sendable {
    public var accepted: UInt64 = 0
    public var completed: UInt64 = 0
    public var output: UInt64 = 0
    public var noDisplay: UInt64 = 0
    public var failed: UInt64 = 0
    public var cancelled: UInt64 = 0
    public var dropped: UInt64 = 0
    public var rejected: UInt64 = 0
    public var wouldBlock: UInt64 = 0
    public var skippedForPresentation: UInt64 = 0
    public var takenForPresentation: UInt64 = 0
    public var staleOutput: UInt64 = 0
    public var outstanding: UInt64 = 0
    public var outstandingHighWater: UInt64 = 0
    public var mailboxHighWater: UInt64 = 0
    public var internalSamples: UInt64 = 0
    public var showExisting: UInt64 = 0
    public var hardwareValidated: Bool = false
    public var lastBackendStatus: Int32 = 0
    public var lastResult: UInt32 = 0
    public var failureDescription: String? {
        guard failed != 0 || lastResult != 0 else { return nil }
        return "\(String(cString: mav_result_string(mav_result(rawValue: lastResult)))) (decoder \(lastResult), backend \(lastBackendStatus))"
    }
    public var terminalIDs: [UInt64] = []
    public var admissionToTerminalMilliseconds: [Double] = []
    public var singleSampleVTSubmitToCallbackMilliseconds: [Double] = []
    /// Last 1024 successful PyroWave outputs, from native admission through the
    /// GPU completion callback. Includes CPU preparation, upload and GPU queueing.
    /// Optional so older diagnostic exports without this additive field still decode.
    public var pyrowaveAdmissionToCallbackMilliseconds: [Double]?
    /// Codec-specific native decode intervals, excluding rendering/presentation.
    /// HEVC/AV1 use single-sample VT submit→callback; PyroWave includes preparation.
    public var decodeTime: TimingSummary {
        let pyrowave = pyrowaveAdmissionToCallbackMilliseconds ?? []
        return TimingSummary(milliseconds: pyrowave.isEmpty ? singleSampleVTSubmitToCallbackMilliseconds : pyrowave)
    }
    mutating func recordPyrowaveDecodeTime(admissionNanoseconds: UInt64, callbackNanoseconds: UInt64) {
        guard admissionNanoseconds != 0, callbackNanoseconds >= admissionNanoseconds else { return }
        if pyrowaveAdmissionToCallbackMilliseconds == nil { pyrowaveAdmissionToCallbackMilliseconds = [] }
        if pyrowaveAdmissionToCallbackMilliseconds?.count == 1024 { pyrowaveAdmissionToCallbackMilliseconds?.removeFirst() }
        pyrowaveAdmissionToCallbackMilliseconds?.append(Double(callbackNanoseconds - admissionNanoseconds) / 1_000_000)
    }
}

/// One extra retain is transferred to the C terminal callback only for accepted AUs.
/// Synchronous rejection releases it in submit. No buffer or compressed bytes live
/// here, and the decoder's bounded admission limits pending instances.
private final class SubmissionMetadata: Sendable {
    let hostProcessingMilliseconds: Double?
    let color: VideoColor?
    let arrivalNanoseconds: UInt64
    let firstPacketNanoseconds: UInt64
    init(_ frame: CompressedFrame, fallbackColor: VideoColor? = nil) {
        hostProcessingMilliseconds = frame.hostProcessingMilliseconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        color = frame.color ?? fallbackColor
        arrivalNanoseconds = frame.arrivalNanoseconds; firstPacketNanoseconds = frame.firstPacketNanoseconds
    }
}

/// Callback state has a single lock, held only while manipulating fixed/bounded data.
/// No decoder/control call or external closure executes under this lock.
private final class CompletionMailbox: @unchecked Sendable {
    let lock = NSLock()
    var latest: DecodedFrame?
    var statistics = DecoderStatistics()
    var suppressOutput = false
    var frameAvailableHandler: (@Sendable () -> Void)?
    func complete(_ value: mav_completion, gpuFrame: PyrowaveGPUFrame? = nil, backendTrace: sva_decode_trace? = nil) {
        let metadata = value.caller_context.map { Unmanaged<SubmissionMetadata>.fromOpaque($0).takeRetainedValue() }
        // takeUnretainedValue does not consume decoder ownership. DecodedFrame's strong
        // property performs ARC retention before returning through the C callback.
        var copied = value, backend = sva_decode_trace()
        backend.struct_size = UInt32(MemoryLayout<sva_decode_trace>.size); backend.version = UInt32(SVA_TRACE_VERSION)
        let hasBackend = backendTrace == nil && sva_completion_get_decode_trace(&copied, &backend) == MAV_OK
        let frame = value.pixel_buffer != nil || gpuFrame != nil ? DecodedFrame(pixelBuffer: value.pixel_buffer?.takeUnretainedValue(),
            gpuFrame: gpuFrame, id: value.frame_id,
            generation: value.generation, width: Int(value.width), height: Int(value.height), bitDepth: Int(value.bit_depth),
            color: VideoColor(value.color),
            callbackNanoseconds: value.trace.valid & UInt32(MAV_TRACE_CALLBACK) != 0 ? value.trace.callback_ns : 0,
            hardwareAccelerated: value.hardware_accelerated != 0,
            firstPacketNanoseconds: value.trace.valid & UInt32(MAV_TRACE_FIRST_PACKET) != 0 ? value.trace.first_packet_ns : 0,
            admissionNanoseconds: value.trace.admission_ns, hostProcessingMilliseconds: metadata?.hostProcessingMilliseconds,
            scheduledArrivalNanoseconds: value.trace.valid & UInt32(MAV_TRACE_ARRIVAL) != 0 ? value.trace.scheduled_arrival_ns : 0,
            vtSubmitNanoseconds: value.trace.valid & UInt32(MAV_TRACE_VT_SUBMIT) != 0 && value.internal_samples == 1 && value.show_existing_frame == 0 ? value.trace.vt_submit_ns : 0,
            decodeStages: DecodeStageTiming(trace: value.trace, backend: backendTrace ?? (hasBackend ? backend : nil),
                internalSamples: value.internal_samples, showExisting: value.show_existing_frame != 0)) : nil
        var available: (@Sendable () -> Void)?
        lock.lock()
        statistics.completed += 1
        let recoverableDrop = value.status == MAV_COMPLETION_DROPPED && value.result == MAV_MALFORMED_INPUT
        if !recoverableDrop && (value.result != MAV_OK || value.backend_status != 0) {
            statistics.lastBackendStatus = value.backend_status; statistics.lastResult = value.result.rawValue
        }
        statistics.internalSamples += UInt64(value.internal_samples)
        statistics.showExisting += UInt64(value.show_existing_frame)
        if statistics.terminalIDs.count == 256 { statistics.terminalIDs.removeFirst() }
        statistics.terminalIDs.append(value.frame_id)
        if value.trace.valid & UInt32(MAV_TRACE_CALLBACK) != 0,
           value.trace.callback_ns >= value.trace.admission_ns && value.trace.admission_ns != 0 {
            if statistics.admissionToTerminalMilliseconds.count == 1024 { statistics.admissionToTerminalMilliseconds.removeFirst() }
            statistics.admissionToTerminalMilliseconds.append(Double(value.trace.callback_ns - value.trace.admission_ns) / 1_000_000)
        }
        if value.trace.valid & UInt32(MAV_TRACE_CALLBACK | MAV_TRACE_VT_SUBMIT) == UInt32(MAV_TRACE_CALLBACK | MAV_TRACE_VT_SUBMIT),
           value.internal_samples == 1, value.show_existing_frame == 0,
           value.trace.callback_ns >= value.trace.vt_submit_ns && value.trace.vt_submit_ns != 0 {
            if statistics.singleSampleVTSubmitToCallbackMilliseconds.count == 1024 { statistics.singleSampleVTSubmitToCallbackMilliseconds.removeFirst() }
            statistics.singleSampleVTSubmitToCallbackMilliseconds.append(Double(value.trace.callback_ns - value.trace.vt_submit_ns) / 1_000_000)
        }
        switch value.status {
        case MAV_COMPLETION_OUTPUT:
            statistics.output += 1
            if gpuFrame != nil, value.trace.valid & UInt32(MAV_TRACE_CALLBACK) != 0 {
                statistics.recordPyrowaveDecodeTime(admissionNanoseconds: value.trace.admission_ns,
                    callbackNanoseconds: value.trace.callback_ns)
            }
            statistics.hardwareValidated = statistics.hardwareValidated || value.hardware_accelerated != 0
            if suppressOutput { statistics.staleOutput += 1 }
            else if let frame {
                if latest != nil { statistics.skippedForPresentation += 1 }
                latest = frame; statistics.mailboxHighWater = 1
                available = frameAvailableHandler
            }
        case MAV_COMPLETION_NO_DISPLAY: statistics.noDisplay += 1
        case MAV_COMPLETION_FAILED: statistics.failed += 1
        case MAV_COMPLETION_CANCELLED: statistics.cancelled += 1
        case MAV_COMPLETION_DROPPED: statistics.dropped += 1
        default: statistics.failed += 1
        }
        lock.unlock()
        available?()
    }
}

/// Copy only the producer's declared metadata prefix. Output references remain
/// borrowed during callback, including with the published ABI-1 VT package.
func copyBorrowedDecoderCompletion(_ source: UnsafePointer<mav_completion>) -> mav_completion? {
    var value = mav_completion()
    value.struct_size = UInt32(MemoryLayout<mav_completion>.size); value.version = UInt32(MAV_ABI_VERSION)
    guard sva_completion_copy(source, &value) == MAV_OK else { return nil }
    return value
}

private func decoderCompletion(_ context: UnsafeMutableRawPointer?, _ completion: UnsafePointer<mav_completion>?) {
    guard let context, let completion else { return }
    guard let value = copyBorrowedDecoderCompletion(completion) else { return }
    Unmanaged<CompletionMailbox>.fromOpaque(context).takeUnretainedValue().complete(value)
}

private func nativeResult(_ result: sp_result) -> mav_result {
    switch result {
    case SP_OK: MAV_OK
    case SP_WOULD_BLOCK: MAV_WOULD_BLOCK
    case SP_MALFORMED: MAV_MALFORMED_INPUT
    case SP_INVALID: MAV_INVALID_ARGUMENT
    case SP_CLOSED: MAV_CLOSED
    case SP_TIMEOUT: MAV_TIMEOUT
    default: MAV_DECODER_FAILED
    }
}

/// Convert metadata into the shared mailbox vocabulary; PyroWave never enters
/// MoonlightAppleVideo's decoder, parser or output ownership APIs.
private func pyrowaveCompletion(_ context: UnsafeMutableRawPointer?, _ completion: UnsafePointer<sp_completion>?) {
    guard let context, let completion else { return }
    let source = completion.pointee
    let metadata = source.context.map { Unmanaged<SubmissionMetadata>.fromOpaque($0).takeUnretainedValue() }
    var value = mav_completion()
    value.frame_id = source.frame_id; value.generation = source.generation; value.caller_context = source.context
    value.result = nativeResult(source.result); value.backend_status = source.backend_status
    switch source.status {
    case SP_OUTPUT: value.status = MAV_COMPLETION_OUTPUT
    case SP_CANCELLED: value.status = MAV_COMPLETION_CANCELLED; value.result = MAV_OK
    case SP_DROPPED: value.status = MAV_COMPLETION_DROPPED
    default: value.status = MAV_COMPLETION_FAILED
    }
    value.width = source.width; value.height = source.height; value.bit_depth = source.bit_depth
    value.hardware_accelerated = source.status == SP_OUTPUT ? 1 : 0; value.internal_samples = 1
    value.color = (metadata?.color ?? VideoColor()).native
    value.trace.valid = UInt32(MAV_TRACE_PREPARATION | MAV_TRACE_CALLBACK)
    value.trace.admission_ns = source.admission_ns
    value.trace.preparation_start_ns = source.preparation_start_ns; value.trace.preparation_end_ns = source.preparation_end_ns
    value.trace.callback_ns = source.callback_ns
    if let metadata {
        if metadata.arrivalNanoseconds != 0 { value.trace.valid |= UInt32(MAV_TRACE_ARRIVAL); value.trace.scheduled_arrival_ns = metadata.arrivalNanoseconds }
        if metadata.firstPacketNanoseconds != 0 { value.trace.valid |= UInt32(MAV_TRACE_FIRST_PACKET); value.trace.first_packet_ns = metadata.firstPacketNanoseconds }
    }
    var trace = sva_decode_trace()
    trace.struct_size = UInt32(MemoryLayout<sva_decode_trace>.size); trace.version = UInt32(SVA_TRACE_VERSION)
    trace.valid = UInt32(SVA_BACKEND_START | SVA_BACKEND_SUBMIT | SVA_BACKEND_RETURN | SVA_GPU_COMMIT)
    trace.backend_start_ns = source.backend_start_ns; trace.backend_submit_ns = source.backend_submit_ns
    trace.backend_return_ns = source.backend_return_ns; trace.gpu_commit_ns = source.gpu_commit_ns
    if source.gpu_start_ns != 0 && source.gpu_end_ns != 0 {
        trace.valid |= UInt32(SVA_GPU_EXECUTION)
        trace.gpu_start_ns = source.gpu_start_ns; trace.gpu_end_ns = source.gpu_end_ns
        trace.gpu_clock_uncertainty_ns = source.gpu_clock_uncertainty_ns
    }
    Unmanaged<CompletionMailbox>.fromOpaque(context).takeUnretainedValue().complete(value,
        gpuFrame: source.gpu_frame.flatMap { PyrowaveGPUFrame($0) }, backendTrace: trace)
}

/// Every C submit/control operation runs synchronously on worker; callers must not call
/// from that private queue. C callbacks only touch mailbox. close joins destruction
/// before mailbox can deinitialize. No pointer is exposed outside this owner.
public final class VideoDecoder: @unchecked Sendable {
    public let codec: VideoCodec
    private let worker = DispatchQueue(label: "net.swiftlight.video.decoder", qos: .userInteractive)
    private let mailbox = CompletionMailbox()
    private var handle: OpaquePointer?
    private var pyrowaveHandle: OpaquePointer?
    private let fallbackColor: VideoColor?
    public init(codec: VideoCodec, maxFramesInFlight: Int = 2, width: Int = 0, height: Int = 0,
                bitDepth: Int = 0, chromaFormat: UInt32 = 0, fallbackColor: VideoColor? = nil) throws {
        self.codec = codec; self.fallbackColor = fallbackColor
        if codec == .pyrowave {
            guard width > 0, height > 0, width <= 16384, height <= 16384,
                  bitDepth == 8 || bitDepth == 10, chromaFormat == 1 || chromaFormat == 3 else {
                throw VideoFailure("configure PyroWave", MAV_INVALID_ARGUMENT)
            }
            var config = sp_config(width: UInt32(width), height: UInt32(height), bit_depth: UInt32(bitDepth),
                chroma: chromaFormat, max_frames_in_flight: UInt32(max(1, min(maxFramesInFlight, 2))))
            let result = sp_decoder_create(&config, pyrowaveCompletion,
                Unmanaged.passUnretained(mailbox).toOpaque(), &pyrowaveHandle)
            guard result == SP_OK else { throw VideoFailure("create PyroWave Metal decoder", nativeResult(result)) }
            return
        }
        var config = mav_config(); mav_config_default(&config, codec.native)
        config.max_frames_in_flight = UInt32(max(1, min(maxFramesInFlight, 16)))
        config.hardware_policy = MAV_HARDWARE_REQUIRED
        guard width >= 0, height >= 0, width <= 16384, height <= 16384,
              bitDepth == 0 || bitDepth == 8 || bitDepth == 10 else { throw VideoFailure("configure decoder", MAV_INVALID_ARGUMENT) }
        config.width = UInt32(width); config.height = UInt32(height); config.bit_depth = UInt32(bitDepth)
        if let fallbackColor { config.fallback_color = fallbackColor.native }
        config.completion = decoderCompletion
        config.context = Unmanaged.passUnretained(mailbox).toOpaque()
        let result = mav_decoder_create(&config, &handle)
        guard result == MAV_OK else { throw VideoFailure("create hardware \(codec.rawValue) decoder", result) }
    }
    deinit { _ = try? close() }

    public func canRecoverOnNextFrame(from code: UInt32) -> Bool {
        codec == .pyrowave && code == MAV_MALFORMED_INPUT.rawValue
    }

    public func submit(_ frame: CompressedFrame) -> SubmissionResult {
        worker.sync {
            if codec == .pyrowave { return submitPyrowave(frame) }
            guard let handle else { return .rejected(MAV_CLOSED.rawValue) }
            guard !frame.bytes.isEmpty, frame.bytes.count <= 64 * 1024 * 1024 else {
                mailbox.lock.lock(); mailbox.statistics.rejected += 1; mailbox.lock.unlock()
                return .rejected(MAV_INVALID_ARGUMENT.rawValue)
            }
            let metadata = Unmanaged.passRetained(SubmissionMetadata(frame))
            let result = frame.bytes.withUnsafeBytes { bytes -> mav_result in
                var span = mav_span(data: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)
                return withUnsafePointer(to: &span) { pointer in
                    var unit = mav_access_unit(); mav_access_unit_default(&unit, codec.native)
                    unit.spans = pointer; unit.span_count = 1; unit.frame_id = frame.id
                    unit.caller_context = metadata.toOpaque()
                    unit.pts = mav_time(value: frame.presentationTimeNanoseconds, timescale: 1_000_000_000, valid: 1)
                    unit.flags = frame.randomAccess ? UInt32(MAV_INPUT_RANDOM_ACCESS) : 0
                    unit.scheduled_arrival_ns = frame.arrivalNanoseconds; unit.first_packet_ns = frame.firstPacketNanoseconds
                    if let color = frame.color { unit.color = color.native }
                    return mav_decoder_submit_copy(handle, &unit)
                }
            }
            if result != MAV_OK { metadata.release() }
            // An inline terminal may already be recorded. Never hold the mailbox lock
            // across submit; update accepted after return and reconcile under the lock.
            var nativeMetrics = mav_metrics()
            nativeMetrics.struct_size = UInt32(MemoryLayout<mav_metrics>.size); nativeMetrics.version = UInt32(MAV_ABI_VERSION)
            _ = mav_decoder_get_metrics(handle, &nativeMetrics)
            mailbox.lock.lock(); defer { mailbox.lock.unlock() }
            if result == MAV_OK { mailbox.statistics.accepted += 1 }
            else if result == MAV_WOULD_BLOCK { mailbox.statistics.wouldBlock += 1 }
            else { mailbox.statistics.rejected += 1 }
            mailbox.statistics.outstanding = mailbox.statistics.accepted >= mailbox.statistics.completed ? mailbox.statistics.accepted - mailbox.statistics.completed : 0
            mailbox.statistics.outstandingHighWater = max(mailbox.statistics.outstandingHighWater, nativeMetrics.peak_outstanding)
            switch result {
            case MAV_OK: return .accepted
            case MAV_WOULD_BLOCK: return .wouldBlock
            case MAV_NEED_RANDOM_ACCESS: return .needsRandomAccess
            default: return .rejected(result.rawValue)
            }
        }
    }

    /// The bridge borrows Data through this call and uploads validated records
    /// before return. Only immutable metadata and GPU leases survive admission.
    private func submitPyrowave(_ frame: CompressedFrame) -> SubmissionResult {
        guard let pyrowaveHandle else { return .rejected(MAV_CLOSED.rawValue) }
        let metadata = Unmanaged.passRetained(SubmissionMetadata(frame, fallbackColor: fallbackColor))
        let fragments = frame.pyrowaveFragments.map { sp_fragment(offset: $0.offset, size: $0.size, kind: $0.kind) }
        let result = frame.bytes.withUnsafeBytes { bytes in
            fragments.withUnsafeBufferPointer { packets in
                var unit = sp_access_unit(bytes: bytes.baseAddress, size: bytes.count,
                    fragments: packets.baseAddress, fragment_count: packets.count,
                    critical_packets: frame.pyrowaveCriticalPackets, frame_id: frame.id, context: metadata.toOpaque())
                return sp_decoder_submit(pyrowaveHandle, &unit)
            }
        }
        if result != SP_OK { metadata.release() }
        mailbox.lock.lock(); defer { mailbox.lock.unlock() }
        if result == SP_OK { mailbox.statistics.accepted += 1 }
        else if result == SP_WOULD_BLOCK { mailbox.statistics.wouldBlock += 1 }
        else { mailbox.statistics.rejected += 1 }
        let outstanding = mailbox.statistics.accepted >= mailbox.statistics.completed ? mailbox.statistics.accepted - mailbox.statistics.completed : 0
        mailbox.statistics.outstandingHighWater = max(mailbox.statistics.outstandingHighWater, outstanding)
        switch result {
        case SP_OK: return .accepted
        case SP_WOULD_BLOCK: return .wouldBlock
        default: return .rejected(nativeResult(result).rawValue)
        }
    }

    /// Event-driven C condition wait; use a bounded timeout on the video worker.
    /// A wake is not a reservation. Retry the same unconsumed access unit.
    public func waitForCapacity(timeoutNanoseconds: UInt64 = 50_000_000) throws {
        try control("wait for capacity", native: { mav_decoder_wait_for_capacity($0, timeoutNanoseconds) }, pyrowave: { sp_decoder_wait_for_capacity($0, timeoutNanoseconds) })
    }
    public func drain() throws { try control("drain", native: mav_decoder_drain, pyrowave: sp_decoder_drain) }
    public func reset() throws {
        try worker.sync {
            guard handle != nil || pyrowaveHandle != nil else { throw VideoFailure("reset", MAV_CLOSED) }
            mailbox.lock.lock(); mailbox.suppressOutput = true
            if mailbox.latest != nil { mailbox.statistics.skippedForPresentation += 1 }
            mailbox.latest = nil; mailbox.lock.unlock()
            let result = pyrowaveHandle.map { nativeResult(sp_decoder_reset($0)) } ?? mav_decoder_reset(handle!)
            mailbox.lock.lock(); mailbox.suppressOutput = false; mailbox.lock.unlock()
            guard result == MAV_OK else { throw VideoFailure("reset", result) }
        }
    }
    public func close() throws {
        try worker.sync {
            guard handle != nil || pyrowaveHandle != nil else { return }
            mailbox.lock.lock(); mailbox.suppressOutput = true
            mailbox.frameAvailableHandler = nil
            if mailbox.latest != nil { mailbox.statistics.skippedForPresentation += 1 }
            mailbox.latest = nil; mailbox.lock.unlock()
            let result = pyrowaveHandle.map { nativeResult(sp_decoder_destroy($0)) } ?? mav_decoder_destroy(handle!)
            if result != MAV_WOULD_BLOCK && result != MAV_REENTRANT_CALL { self.handle = nil; self.pyrowaveHandle = nil }
            guard result == MAV_OK else { throw VideoFailure("destroy", result) }
        }
    }
    private func control(_ name: String, native: (OpaquePointer) -> mav_result, pyrowave: (OpaquePointer) -> sp_result) throws {
        try worker.sync {
            guard handle != nil || pyrowaveHandle != nil else { throw VideoFailure(name, MAV_CLOSED) }
            let result = pyrowaveHandle.map { nativeResult(pyrowave($0)) } ?? native(handle!)
            guard result == MAV_OK else { throw VideoFailure(name, result) }
        }
    }
    public func takeLatestFrame() -> DecodedFrame? {
        mailbox.lock.lock(); defer { mailbox.lock.unlock() }
        let result = mailbox.latest; mailbox.latest = nil
        if result != nil { mailbox.statistics.takenForPresentation += 1 }
        return result
    }
    /// Notification only: invoked on the decoder completion thread after releasing
    /// the mailbox lock. Signal a presentation queue; never call submit/control from
    /// this closure. A notification already extracted may finish after replacement.
    public func setFrameAvailableHandler(_ handler: (@Sendable () -> Void)?) {
        mailbox.lock.lock(); mailbox.frameAvailableHandler = handler; mailbox.lock.unlock()
    }
    public var statistics: DecoderStatistics {
        mailbox.lock.lock(); defer { mailbox.lock.unlock() }
        var result = mailbox.statistics
        result.outstanding = result.accepted >= result.completed ? result.accepted - result.completed : 0
        return result
    }
    public static var monotonicNanoseconds: UInt64 { mav_monotonic_time_ns() }
}
