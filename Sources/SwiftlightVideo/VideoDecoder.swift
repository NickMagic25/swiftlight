import Foundation
import CoreVideo
import MoonlightAppleVideo

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case hevc, av1
    var native: mav_codec { self == .hevc ? MAV_CODEC_HEVC : MAV_CODEC_AV1 }
    public var hardwareCandidate: Bool {
        var value = mav_capability()
        value.struct_size = UInt32(MemoryLayout<mav_capability>.size); value.version = 1
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
    public init(bytes: Data, id: UInt64, presentationTimeNanoseconds: Int64 = 0, randomAccess: Bool = false,
                arrivalNanoseconds: UInt64 = 0, firstPacketNanoseconds: UInt64 = 0,
                hostProcessingMilliseconds: Double? = nil) {
        self.bytes = bytes; self.id = id; self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.randomAccess = randomAccess; self.arrivalNanoseconds = arrivalNanoseconds; self.firstPacketNanoseconds = firstPacketNanoseconds
        self.hostProcessingMilliseconds = hostProcessingMilliseconds
    }
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

/// Immutable after construction. ARC acquires the borrowed callback buffer on assignment.
/// Decoder output pixels are immutable; only CoreVideo/Metal read them. Passing this
/// owner between the locked mailbox and render queue is safe, never raw plane pointers.
public final class DecodedFrame: @unchecked Sendable {
    private static let ownership = FrameOwnership()
    public let pixelBuffer: CVPixelBuffer
    public let id: UInt64
    public let generation: UInt64
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let color: VideoColor
    public let callbackNanoseconds: UInt64
    /// Zero means unavailable. These share mav_monotonic_time_ns's clock domain.
    public let firstPacketNanoseconds: UInt64
    public let admissionNanoseconds: UInt64
    public let hostProcessingMilliseconds: Double?
    public let hardwareAccelerated: Bool
    /// Visible source pixels, with top-left origin to match input coordinates and Metal.
    public var contentRect: CGRect {
        let raw = CVImageBufferGetCleanRect(pixelBuffer)
        let physical = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let fallback = CGRect(x: 0, y: 0, width: min(width, CVPixelBufferGetWidth(pixelBuffer)), height: min(height, CVPixelBufferGetHeight(pixelBuffer)))
        let converted = CGRect(x: raw.minX, y: CGFloat(CVPixelBufferGetHeight(pixelBuffer)) - raw.maxY, width: raw.width, height: raw.height)
        // Clean aperture is in buffer coordinates. Clipping it to visible stream
        // dimensions would crop a padded buffer twice when its aperture is offset.
        let clipped = converted.intersection(physical)
        return clipped.isEmpty || clipped.isNull || clipped == physical ? fallback : clipped
    }
    public init(pixelBuffer: CVPixelBuffer, id: UInt64, generation: UInt64 = 0, width: Int, height: Int,
                bitDepth: Int, color: VideoColor, callbackNanoseconds: UInt64 = 0, hardwareAccelerated: Bool = false,
                firstPacketNanoseconds: UInt64 = 0, admissionNanoseconds: UInt64 = 0,
                hostProcessingMilliseconds: Double? = nil) {
        self.pixelBuffer = pixelBuffer; self.id = id; self.generation = generation; self.width = width; self.height = height
        self.bitDepth = bitDepth; self.color = color; self.callbackNanoseconds = callbackNanoseconds; self.hardwareAccelerated = hardwareAccelerated
        self.firstPacketNanoseconds = firstPacketNanoseconds; self.admissionNanoseconds = admissionNanoseconds
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
        return "\(String(cString: mav_result_string(mav_result(rawValue: lastResult)))) (decoder \(lastResult), VideoToolbox \(lastBackendStatus))"
    }
    public var terminalIDs: [UInt64] = []
    public var admissionToTerminalMilliseconds: [Double] = []
    public var singleSampleVTSubmitToCallbackMilliseconds: [Double] = []
    /// Last 1024 single-sample VT submit→callback intervals. AV1 show-existing and
    /// multi-sample aggregate completions are excluded; this is not GPU/display time.
    public var decodeTime: TimingSummary { TimingSummary(milliseconds: singleSampleVTSubmitToCallbackMilliseconds) }
}

/// One extra retain is transferred to the C terminal callback only for accepted AUs.
/// Synchronous rejection releases it in submit. No buffer or compressed bytes live
/// here, and the decoder's bounded admission limits pending instances.
private final class SubmissionMetadata: Sendable {
    let hostProcessingMilliseconds: Double?
    init(_ value: Double?) { hostProcessingMilliseconds = value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
}

/// Callback state has a single lock, held only while manipulating fixed/bounded data.
/// No decoder/control call or external closure executes under this lock.
private final class CompletionMailbox: @unchecked Sendable {
    let lock = NSLock()
    var latest: DecodedFrame?
    var statistics = DecoderStatistics()
    var suppressOutput = false
    func complete(_ value: mav_completion) {
        let metadata = value.caller_context.map { Unmanaged<SubmissionMetadata>.fromOpaque($0).takeRetainedValue() }
        // takeUnretainedValue does not consume decoder ownership. DecodedFrame's strong
        // property performs ARC retention before returning through the C callback.
        let frame = value.pixel_buffer.map { DecodedFrame(pixelBuffer: $0.takeUnretainedValue(), id: value.frame_id,
            generation: value.generation, width: Int(value.width), height: Int(value.height), bitDepth: Int(value.bit_depth),
            color: VideoColor(value.color),
            callbackNanoseconds: value.trace.valid & UInt32(MAV_TRACE_CALLBACK) != 0 ? value.trace.callback_ns : 0,
            hardwareAccelerated: value.hardware_accelerated != 0,
            firstPacketNanoseconds: value.trace.valid & UInt32(MAV_TRACE_FIRST_PACKET) != 0 ? value.trace.first_packet_ns : 0,
            admissionNanoseconds: value.trace.admission_ns, hostProcessingMilliseconds: metadata?.hostProcessingMilliseconds) }
        lock.lock(); defer { lock.unlock() }
        statistics.completed += 1
        if value.result != MAV_OK || value.backend_status != 0 {
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
            statistics.hardwareValidated = statistics.hardwareValidated || value.hardware_accelerated != 0
            if suppressOutput { statistics.staleOutput += 1 }
            else if let frame {
                if latest != nil { statistics.skippedForPresentation += 1 }
                latest = frame; statistics.mailboxHighWater = 1
            }
        case MAV_COMPLETION_NO_DISPLAY: statistics.noDisplay += 1
        case MAV_COMPLETION_FAILED: statistics.failed += 1
        case MAV_COMPLETION_CANCELLED: statistics.cancelled += 1
        case MAV_COMPLETION_DROPPED: statistics.dropped += 1
        default: statistics.failed += 1
        }
    }
}

private func decoderCompletion(_ context: UnsafeMutableRawPointer?, _ completion: UnsafePointer<mav_completion>?) {
    guard let context, let completion else { return }
    Unmanaged<CompletionMailbox>.fromOpaque(context).takeUnretainedValue().complete(completion.pointee)
}

/// Every C submit/control operation runs synchronously on worker; callers must not call
/// from that private queue. C callbacks only touch mailbox. close joins destruction
/// before mailbox can deinitialize. No pointer is exposed outside this owner.
public final class VideoDecoder: @unchecked Sendable {
    public let codec: VideoCodec
    private let worker = DispatchQueue(label: "net.swiftlight.video.decoder", qos: .userInteractive)
    private let mailbox = CompletionMailbox()
    private var handle: OpaquePointer?
    public init(codec: VideoCodec, maxFramesInFlight: Int = 2) throws {
        self.codec = codec
        var config = mav_config(); mav_config_default(&config, codec.native)
        config.max_frames_in_flight = UInt32(max(1, min(maxFramesInFlight, 16)))
        config.hardware_policy = MAV_HARDWARE_REQUIRED
        config.completion = decoderCompletion
        config.context = Unmanaged.passUnretained(mailbox).toOpaque()
        let result = mav_decoder_create(&config, &handle)
        guard result == MAV_OK else { throw VideoFailure("create hardware \(codec.rawValue) decoder", result) }
    }
    deinit { _ = try? close() }

    public func submit(_ frame: CompressedFrame) -> SubmissionResult {
        worker.sync {
            guard let handle else { return .rejected(MAV_CLOSED.rawValue) }
            guard !frame.bytes.isEmpty, frame.bytes.count <= 64 * 1024 * 1024 else {
                mailbox.lock.lock(); mailbox.statistics.rejected += 1; mailbox.lock.unlock()
                return .rejected(MAV_INVALID_ARGUMENT.rawValue)
            }
            let metadata = Unmanaged.passRetained(SubmissionMetadata(frame.hostProcessingMilliseconds))
            let result = frame.bytes.withUnsafeBytes { bytes -> mav_result in
                var span = mav_span(data: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)
                return withUnsafePointer(to: &span) { pointer in
                    var unit = mav_access_unit(); mav_access_unit_default(&unit, codec.native)
                    unit.spans = pointer; unit.span_count = 1; unit.frame_id = frame.id
                    unit.caller_context = metadata.toOpaque()
                    unit.pts = mav_time(value: frame.presentationTimeNanoseconds, timescale: 1_000_000_000, valid: 1)
                    unit.flags = frame.randomAccess ? UInt32(MAV_INPUT_RANDOM_ACCESS) : 0
                    unit.scheduled_arrival_ns = frame.arrivalNanoseconds; unit.first_packet_ns = frame.firstPacketNanoseconds
                    return mav_decoder_submit_copy(handle, &unit)
                }
            }
            if result != MAV_OK { metadata.release() }
            // An inline terminal may already be recorded. Never hold the mailbox lock
            // across submit; update accepted after return and reconcile under the lock.
            var nativeMetrics = mav_metrics()
            nativeMetrics.struct_size = UInt32(MemoryLayout<mav_metrics>.size); nativeMetrics.version = 1
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

    /// Event-driven C condition wait; use a bounded timeout on the video worker.
    /// A wake is not a reservation. Retry the same unconsumed access unit.
    public func waitForCapacity(timeoutNanoseconds: UInt64 = 50_000_000) throws {
        try control("wait for capacity") { mav_decoder_wait_for_capacity($0, timeoutNanoseconds) }
    }
    public func drain() throws { try control("drain", mav_decoder_drain) }
    public func reset() throws {
        try worker.sync {
            guard let handle else { throw VideoFailure("reset", MAV_CLOSED) }
            mailbox.lock.lock(); mailbox.suppressOutput = true
            if mailbox.latest != nil { mailbox.statistics.skippedForPresentation += 1 }
            mailbox.latest = nil; mailbox.lock.unlock()
            let result = mav_decoder_reset(handle)
            mailbox.lock.lock(); mailbox.suppressOutput = false; mailbox.lock.unlock()
            guard result == MAV_OK else { throw VideoFailure("reset", result) }
        }
    }
    public func close() throws {
        try worker.sync {
            guard let handle else { return }
            mailbox.lock.lock(); mailbox.suppressOutput = true
            if mailbox.latest != nil { mailbox.statistics.skippedForPresentation += 1 }
            mailbox.latest = nil; mailbox.lock.unlock()
            let result = mav_decoder_destroy(handle)
            if result != MAV_WOULD_BLOCK && result != MAV_REENTRANT_CALL { self.handle = nil }
            guard result == MAV_OK else { throw VideoFailure("destroy", result) }
        }
    }
    private func control(_ name: String, _ body: (OpaquePointer) -> mav_result) throws {
        try worker.sync {
            guard let handle else { throw VideoFailure(name, MAV_CLOSED) }
            let result = body(handle)
            guard result == MAV_OK else { throw VideoFailure(name, result) }
        }
    }
    public func takeLatestFrame() -> DecodedFrame? {
        mailbox.lock.lock(); defer { mailbox.lock.unlock() }
        let result = mailbox.latest; mailbox.latest = nil
        if result != nil { mailbox.statistics.takenForPresentation += 1 }
        return result
    }
    public var statistics: DecoderStatistics {
        mailbox.lock.lock(); defer { mailbox.lock.unlock() }
        var result = mailbox.statistics
        result.outstanding = result.accepted >= result.completed ? result.accepted - result.completed : 0
        return result
    }
    public static var monotonicNanoseconds: UInt64 { mav_monotonic_time_ns() }
}
