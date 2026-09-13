import Foundation
import SwiftlightVideo
import SwiftlightTransport
import os

/// The lock protects only admission and the decoder reference. The decoder owns its
/// serialized API queue. A pull callback holds a strong owner until it has acquired
/// the AU; teardown closes admission, joins common-c, then destroys that owner.
final class StreamingPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: VideoDecoder?
    private var accepting = true
    private var failure: String?
    private var renderer: MetalVideoRenderer?
    private var latestDecodedFormat: DecodedVideoFormat?
    private var negotiatedStream: VideoStreamDescription?
    private var latestViewport = CGSize.zero
    private let signposter = OSSignposter(subsystem: "net.edrisil.swiftlight", category: "Video")
    func setup(_ description: VideoStreamDescription) -> Bool {
        let codec: VideoCodec
        switch description.videoFormat {
        case 0x100, 0x200: codec = .hevc
        case 0x1000, 0x2000: codec = .av1
        default: recordFailure("Host selected an unsupported video format. HEVC or AV1 4:2:0 is required."); return false
        }
        do {
            let newDecoder = try VideoDecoder(codec: codec, maxFramesInFlight: 2)
            lock.lock()
            guard accepting else { lock.unlock(); try newDecoder.close(); return false }
            let old = decoder; decoder = newDecoder; negotiatedStream = description; latestDecodedFormat = nil; lock.unlock()
            try old?.close(); return true
        } catch { recordFailure(String(describing: error)); return false }
    }
    func receive(_ input: CompressedVideoFrame) -> Bool {
        lock.lock(); let owner = accepting ? decoder : nil; lock.unlock()
        guard let owner else { return false }
        guard input.presentationTimeUs <= UInt64(Int64.max / 1000) else {
            recordFailure("Host supplied an invalid media timestamp."); return false
        }
        let interval = signposter.beginInterval("Acquire complete frame")
        defer { signposter.endInterval("Acquire complete frame", interval) }
        // The bridge maps common-c timestamps using its exact exported uptime epoch.
        let frame = CompressedFrame(bytes: input.data, id: input.frameID,
            presentationTimeNanoseconds: Int64(input.presentationTimeUs) * 1000,
            randomAccess: input.isIDR, arrivalNanoseconds: input.enqueueUptimeNanoseconds,
            firstPacketNanoseconds: input.receiveUptimeNanoseconds,
            hostProcessingMilliseconds: input.hostProcessingLatencyMilliseconds)
        var result = owner.submit(frame)
        if result == .wouldBlock {
            do {
                try owner.waitForCapacity(timeoutNanoseconds: 100_000_000)
                result = owner.submit(frame)
                if result == .wouldBlock {
                    // Capacity was available, so outstanding work may be holding a format
                    // change. Drain on this dedicated pull/control path, then retry same AU.
                    try owner.drain(); result = owner.submit(frame)
                }
            } catch { recordFailure("Decoder admission timed out: \(error)"); return false }
        }
        switch result {
        case .accepted: return true
        case .needsRandomAccess: return false
        case .wouldBlock: recordFailure("Decoder remained backpressured after a controlled drain."); return false
        case .rejected(let code): recordFailure("Decoder rejected the host stream (\(code)). Check the host encoder uses low-delay HEVC/AV1 without reordered HEVC B pictures."); return false
        }
    }
    func closeAdmission() { lock.lock(); accepting = false; lock.unlock() }
    func close() {
        lock.lock(); accepting = false; let owner = decoder; decoder = nil; lock.unlock()
        try? owner?.close()
    }
    func takeLatestFrame() -> DecodedFrame? {
        lock.lock(); let owner = accepting ? decoder : nil; lock.unlock()
        return owner?.takeLatestFrame()
    }
    var statistics: DecoderStatistics? {
        lock.lock(); let owner = decoder; lock.unlock(); return owner?.statistics
    }
    func reportRendererFailure() { recordFailure("Metal failed to complete video rendering. Reconnect after checking the display and GPU state.") }
    func attachRenderer(_ renderer: MetalVideoRenderer) { lock.lock(); self.renderer = renderer; lock.unlock() }
    func recordFrame(_ frame: DecodedFrame, viewport: CGSize) {
        lock.lock(); defer { lock.unlock() }
        if let codec = decoder?.codec { latestDecodedFormat = DecodedVideoFormat(codec: codec, frame: frame) }
        latestViewport = viewport
    }
    var decodedFormat: DecodedVideoFormat? { lock.lock(); defer { lock.unlock() }; return latestDecodedFormat }
    var streamDescription: VideoStreamDescription? { lock.lock(); defer { lock.unlock() }; return negotiatedStream }
    var decodedDetail: String {
        lock.lock(); let format = latestDecodedFormat, viewport = latestViewport; lock.unlock()
        guard let format else { return "Waiting for decoded output" }
        return "Decoded \(format.width) × \(format.height) · \(format.bitDepth)-bit · viewport \(Int(viewport.width)) × \(Int(viewport.height))"
    }
    var renderStatistics: RenderStatistics? { lock.lock(); let renderer = renderer; lock.unlock(); return renderer?.statistics }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    private func recordFailure(_ message: String) { lock.lock(); if failure == nil { failure = message }; lock.unlock() }
}
