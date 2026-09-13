import Foundation
import CStreamBridge

public struct TransportConfiguration: Sendable {
    public let address: String
    public let appVersion: String
    public let gfeVersion: String?
    public let rtspURL: String?
    public let serverCodecSupport: UInt32
    public let width, height, fps, bitrateKbps: Int
    public let supportedVideoFormats: UInt32
    public let inputKey: Data
    public let inputKeyID: UInt32
    public let hdr: Bool
    public let permissions: UInt32?
    public let displayRefreshHz: Double
    public init(address: String, appVersion: String, gfeVersion: String? = nil, rtspURL: String?,
                serverCodecSupport: UInt32, width: Int, height: Int, fps: Int, bitrateKbps: Int,
                supportedVideoFormats: UInt32, inputKey: Data, inputKeyID: UInt32, hdr: Bool = false, permissions: UInt32? = nil, displayRefreshHz: Double = 0) {
        self.address = address; self.appVersion = appVersion; self.gfeVersion = gfeVersion; self.rtspURL = rtspURL
        self.serverCodecSupport = serverCodecSupport; self.width = width; self.height = height; self.fps = fps
        self.bitrateKbps = bitrateKbps; self.supportedVideoFormats = supportedVideoFormats
        self.inputKey = inputKey; self.inputKeyID = inputKeyID; self.hdr = hdr
        self.permissions = permissions; self.displayRefreshHz = displayRefreshHz
    }
}

public struct VideoStreamDescription: Sendable {
    public let videoFormat: UInt32
    public let width, height, fps: Int
    public var isAV1: Bool { videoFormat & 0x3000 != 0 }
    public var bitDepth: Int { videoFormat & 0x2200 != 0 ? 10 : 8 }
}

public struct CompressedVideoFrame: Sendable {
    public let data: Data
    public let frameID, receiveTimeUs, enqueueTimeUs, presentationTimeUs: UInt64
    public let rtpTimestamp: UInt32
    /// Exact CLOCK_UPTIME_RAW domain used by mav_monotonic_time_ns, rounded down by <1us.
    public let receiveUptimeNanoseconds, enqueueUptimeNanoseconds: UInt64
    public let isIDR: Bool
}

public enum TransportEvent: Sendable {
    case stage(String)
    case started
    case terminated(Int32)
    case failed(stage: String, code: Int32)
    case qualityPoor(Bool)
    case hdr(Bool)
    case audioFailure(Int32)
    case rumble(controller: UInt16, low: UInt16, high: UInt16)
}

/// Setup and video are synchronous admission calls, not UI callbacks. `video` returns
/// true only after MoonlightAppleVideo acquired its input; false requests an IDR.
/// Event callbacks must enqueue orchestration and never synchronously stop this transport.
public struct TransportCallbacks: Sendable {
    public let setup: @Sendable (VideoStreamDescription) -> Bool
    public let video: @Sendable (CompressedVideoFrame) -> Bool
    public let event: @Sendable (TransportEvent) -> Void
    public init(setup: @escaping @Sendable (VideoStreamDescription) -> Bool,
                video: @escaping @Sendable (CompressedVideoFrame) -> Bool,
                event: @escaping @Sendable (TransportEvent) -> Void) {
        self.setup = setup; self.video = video; self.event = event
    }
}

public enum TransportError: Error, LocalizedError {
    case invalidConfiguration
    case connectionFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid HEVC/AV1 stream configuration or input encryption key."
        case .connectionFailed(let code): "Streaming connection failed (code \(code)). Check the host and network."
        }
    }
}

private final class CallbackOwner: Sendable {
    let callbacks: TransportCallbacks
    init(_ callbacks: TransportCallbacks) { self.callbacks = callbacks }
}

/// common-c has one global session. This owner serializes start/stop on `lifecycleQueue`;
/// the C API gates input and stop with a mutex. Each operation retains self until done.
/// `pointer` and `owner` are immutable; C shutdown joins media workers and retires event
/// callbacks before deinit releases owner. These invariants justify unchecked Sendable.
public final class StreamTransport: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let owner: CallbackOwner
    private let lifecycleQueue = DispatchQueue(label: "net.swiftlight.transport.lifecycle", qos: .userInitiated)

    public static var launchQueryParameters: String { String(cString: sf_stream_launch_query()) }

    public init(configuration: TransportConfiguration, callbacks: TransportCallbacks) throws {
        let allowed: UInt32 = 0x3300
        guard configuration.inputKey.count == 16, !configuration.address.isEmpty,
              !configuration.appVersion.isEmpty, configuration.supportedVideoFormats != 0,
              configuration.supportedVideoFormats & ~allowed == 0,
              (16...16384).contains(configuration.width), (16...16384).contains(configuration.height),
              (1...1000).contains(configuration.fps), (500...500000).contains(configuration.bitrateKbps)
        else { throw TransportError.invalidConfiguration }
        owner = CallbackOwner(callbacks)
        var c = SFStreamConfiguration()
        let address = strdup(configuration.address), version = strdup(configuration.appVersion)
        let gfe = configuration.gfeVersion.flatMap { strdup($0) }, rtsp = configuration.rtspURL.flatMap { strdup($0) }
        defer { free(address); free(version); free(gfe); free(rtsp) }
        c.address = UnsafePointer(address); c.app_version = UnsafePointer(version)
        c.gfe_version = UnsafePointer(gfe); c.rtsp_url = UnsafePointer(rtsp)
        c.server_codec_support = configuration.serverCodecSupport; c.video_formats = configuration.supportedVideoFormats
        c.width = Int32(configuration.width); c.height = Int32(configuration.height); c.fps = Int32(configuration.fps)
        c.has_permissions = configuration.permissions != nil; c.permissions = configuration.permissions ?? 0
        c.display_refresh_rate_x100 = configuration.displayRefreshHz.isFinite ? Int32(clamping: Int(max(0, min(1000, configuration.displayRefreshHz)) * 100)) : 0
        c.bitrate_kbps = Int32(configuration.bitrateKbps); c.input_key_id = configuration.inputKeyID; c.hdr = configuration.hdr
        _ = withUnsafeMutableBytes(of: &c.input_key) { destination in configuration.inputKey.copyBytes(to: destination) }
        var cCallbacks = SFStreamCallbacks()
        cCallbacks.setup = { context, raw in
            guard let context, let raw else { return -1 }
            let callbacks = Unmanaged<CallbackOwner>.fromOpaque(context).takeUnretainedValue().callbacks
            let d = raw.pointee
            return callbacks.setup(VideoStreamDescription(videoFormat: d.format, width: Int(d.width), height: Int(d.height), fps: Int(d.fps))) ? 0 : -1
        }
        cCallbacks.video = { context, raw in
            guard let context, let raw, let bytes = raw.pointee.bytes else { return -1 }
            let callbacks = Unmanaged<CallbackOwner>.fromOpaque(context).takeUnretainedValue().callbacks
            let f = raw.pointee
            // Acquire a value-owned Data before leaving the callback. No borrowed C pointer
            // escapes; this is bounded to one 32MiB access unit plus decoder input capacity.
            let frame = CompressedVideoFrame(data: Data(bytes: bytes, count: f.length), frameID: f.frame_id,
                receiveTimeUs: f.receive_time_us, enqueueTimeUs: f.enqueue_time_us,
                presentationTimeUs: f.presentation_time_us, rtpTimestamp: f.rtp_timestamp, receiveUptimeNanoseconds: f.receive_uptime_ns,
                enqueueUptimeNanoseconds: f.enqueue_uptime_ns, isIDR: f.is_idr)
            return callbacks.video(frame) ? 0 : -1
        }
        cCallbacks.event = { context, kind, a, b, c, message in
            guard let context else { return }
            let callback = Unmanaged<CallbackOwner>.fromOpaque(context).takeUnretainedValue().callbacks.event
            switch kind {
            case Int32(SF_STAGE): callback(.stage(message.map(String.init(cString:)) ?? "Connecting"))
            case Int32(SF_STARTED): callback(.started)
            case Int32(SF_TERMINATED): callback(.terminated(a))
            case Int32(SF_FAILED): callback(.failed(stage: message.map(String.init(cString:)) ?? "Connection", code: b))
            case Int32(SF_QUALITY): callback(.qualityPoor(a != 0))
            case Int32(SF_HDR): callback(.hdr(a != 0))
            case Int32(SF_AUDIO_ERROR): callback(.audioFailure(a))
            case Int32(SF_RUMBLE): callback(.rumble(controller: UInt16(clamping: a), low: UInt16(clamping: b), high: UInt16(clamping: c)))
            default: break
            }
        }
        guard let stream = sf_stream_create(&c, cCallbacks, Unmanaged.passUnretained(owner).toOpaque())
        else { throw TransportError.invalidConfiguration }
        pointer = stream
    }

    deinit { sf_stream_destroy(pointer) }

    public func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lifecycleQueue.async { [self] in
                    let code = sf_stream_start(pointer)
                    if code == 0 { continuation.resume() }
                    else if code == -20002 { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(throwing: TransportError.connectionFailed(code)) }
                }
            }
        } onCancel: { self.cancelStart() }
    }

    public func cancelStart() { sf_stream_cancel_start(pointer) }

    /// Close decoder admission before awaiting this method so a capacity-blocked pull
    /// callback can finish. Drain/destroy the decoder only after this join returns.
    public func stop() async {
        cancelStart()
        await withCheckedContinuation { continuation in
            lifecycleQueue.async { [self] in sf_stream_stop(pointer); continuation.resume() }
        }
    }
    public var diagnostics: TransportDiagnostics? {
        var value = SFTransportDiagnostics()
        guard sf_stream_diagnostics(pointer, &value) else { return nil }
        let local = withUnsafeBytes(of: &value.local_address) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let interface = withUnsafeBytes(of: &value.interface_name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        return TransportDiagnostics(rttMilliseconds: value.rtt_available ? value.rtt_ms : nil,
            rttVarianceMilliseconds: value.rtt_available ? value.rtt_variance_ms : nil,
            pendingVideoFrames: Int(value.pending_video_frames), pendingAudioMilliseconds: Int(value.pending_audio_ms),
            audioQueuedFrames: value.audio_queued_frames, audioUnderrunFrames: value.audio_underrun_frames,
            audioOverrunFrames: value.audio_overrun_frames, localAddress: local, interfaceName: interface)
    }
    public func requestKeyFrame() { sf_stream_request_idr(pointer) }
    public func releaseAllInputs() { sf_stream_release_inputs(pointer) }
    public func mouseMove(dx: Int16, dy: Int16) { _ = sf_stream_mouse_move(pointer, dx, dy) }
    public func mousePosition(x: Int16, y: Int16, width: Int16, height: Int16) { _ = sf_stream_mouse_position(pointer, x, y, width, height) }
    public func mouseButton(_ button: Int, pressed: Bool) { _ = sf_stream_mouse_button(pointer, Int32(clamping: button), pressed) }
    public func key(_ virtualKey: UInt16, pressed: Bool, modifiers: UInt8 = 0) { _ = sf_stream_key(pointer, virtualKey, pressed, modifiers) }
    public func scroll(vertical: Int16, horizontal: Int16 = 0) { _ = sf_stream_scroll(pointer, vertical, horizontal) }
    public func controller(index: UInt8, activeMask: UInt16, buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8,
                           leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16) {
        _ = sf_stream_controller(pointer, index, activeMask, buttons, leftTrigger, rightTrigger, leftX, leftY, rightX, rightY)
    }
}

/// Read at a low rate outside real-time callbacks. `interfaceName` is matched to the
/// actual bound video socket address; it is not inferred from a global path monitor.
public struct TransportDiagnostics: Sendable {
    public let rttMilliseconds, rttVarianceMilliseconds: UInt32?
    public let pendingVideoFrames, pendingAudioMilliseconds: Int
    public let audioQueuedFrames, audioUnderrunFrames, audioOverrunFrames: UInt64
    public let localAddress, interfaceName: String
}
