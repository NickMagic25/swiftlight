import Foundation
import CryptoKit
import Metal
import SwiftlightVideo

private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Double]] = []
    private var count = 0
    private var retained: DecodedFrame?
    func append(_ frame: DecodedFrame, warmup: UInt64) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        retained = frame
        guard frame.id > warmup else { return }
        var sample: [String: Double] = ["frame_id": Double(frame.id)]
        if frame.callbackNanoseconds >= frame.admissionNanoseconds, frame.admissionNanoseconds > 0 {
            sample["admission_to_callback_ms"] = Double(frame.callbackNanoseconds - frame.admissionNanoseconds) / 1_000_000
        }
        if let stages = frame.decodeStages {
            sample["preparation_ms"] = stages.preparationMilliseconds
            sample["backend_preparation_ms"] = stages.backendPreparationMilliseconds
            sample["backend_call_ms"] = stages.backendCallMilliseconds
            sample["gpu_queue_ms"] = stages.gpuCommitToStartMilliseconds
            sample["gpu_execution_ms"] = stages.gpuExecutionMilliseconds
            sample["gpu_end_to_callback_ms"] = stages.gpuEndToCallbackMilliseconds
        }
        values.append(sample)
    }
    var snapshot: (Int, [[String: Double]]) { lock.lock(); defer { lock.unlock() }; return (count, values) }
    var lastFrame: DecodedFrame? { lock.lock(); defer { lock.unlock() }; return retained }
}

/// Offscreen production-decoder benchmark. Admission is paced independently of
/// completion, with at most two pending decodes. No network or drawable exists.
@main struct PyrowaveBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7, let fps = Double(arguments[2]), fps > 0, fps <= 1000,
              let frames = Int(arguments[3]), frames > 0, frames <= 100_000,
              let warmup = Int(arguments[4]), warmup >= 0, warmup <= 10_000,
              let depth = Int(arguments[5]), [8, 10].contains(depth) else {
            throw NSError(domain: "PyrowaveBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture fps frames warmup depth output.json"])
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        guard bytes.count >= 8, bytes.count <= 64 * 1024 * 1024 else { throw NSError(domain: "PyrowaveBenchmark", code: 2) }
        func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) } }
        let width = Int(word(0) & 0x3FFF) + 1, height = Int((word(0) >> 14) & 0x3FFF) + 1
        let chroma: UInt32 = (word(4) >> 26) & 1 == 1 ? 3 : 1
        let color = depth == 10 ? VideoColor(primaries: 9, transfer: 16, matrix: 9, chromaLocation: 1) : VideoColor(chromaLocation: 1)
        let decoder = try VideoDecoder(codec: .pyrowave, maxFramesInFlight: 2, width: width, height: height,
            bitDepth: depth, chromaFormat: chroma, fallbackColor: color)
        defer { try? decoder.close() }
        let samples = Samples()
        decoder.setFrameAvailableHandler { [weak decoder] in
            guard let frame = decoder?.takeLatestFrame() else { return }
            samples.append(frame, warmup: UInt64(warmup))
        }
        let interval = 1_000_000_000 / fps
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let start = VideoDecoder.monotonicNanoseconds
        var lateAdmissions = 0, maximumAdmissionLateness = 0.0
        var submitMilliseconds = [Double]()
        for index in 0..<(frames + warmup) {
            let deadline = start + UInt64(Double(index) * interval)
            while VideoDecoder.monotonicNanoseconds < deadline {
                let remaining = deadline - min(deadline, VideoDecoder.monotonicNanoseconds)
                if remaining > 100_000 { Thread.sleep(forTimeInterval: Double(remaining) / 1_000_000_000) }
            }
            let now = VideoDecoder.monotonicNanoseconds
            if index >= warmup, now > deadline + 100_000 {
                lateAdmissions += 1
                maximumAdmissionLateness = max(maximumAdmissionLateness, Double(now - deadline) / 1_000_000)
            }
            let input = CompressedFrame(bytes: bytes, id: UInt64(index + 1), arrivalNanoseconds: deadline)
            let before = VideoDecoder.monotonicNanoseconds
            var result = decoder.submit(input)
            if result == .wouldBlock {
                try decoder.waitForCapacity(timeoutNanoseconds: 1_000_000_000)
                result = decoder.submit(input)
            }
            guard result == .accepted else { throw NSError(domain: "PyrowaveBenchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "Submission \(index + 1): \(result)"] ) }
            if index >= warmup { submitMilliseconds.append(Double(VideoDecoder.monotonicNanoseconds - before) / 1_000_000) }
        }
        try decoder.drain()
        let callbackDeadline = Date().addingTimeInterval(1)
        while samples.snapshot.0 < frames + warmup, Date() < callbackDeadline { Thread.sleep(forTimeInterval: 0.001) }
        decoder.setFrameAvailableHandler(nil)
        let statistics = decoder.statistics, snapshot = samples.snapshot
        guard snapshot.0 == frames + warmup, statistics.accepted == statistics.completed,
              statistics.failed == 0, statistics.outstandingHighWater <= 2,
              statistics.singleSampleVTSubmitToCallbackMilliseconds.isEmpty else { throw NSError(domain: "PyrowaveBenchmark", code: 4) }
        func summary(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [:] }
            return ["count": Double(sorted.count), "mean": sorted.reduce(0, +) / Double(sorted.count),
                "median": sorted[sorted.count / 2], "p95": sorted[min(sorted.count - 1, sorted.count * 95 / 100)], "maximum": sorted.last!]
        }
        var summaries: [String: [String: Double]] = ["submit_ms": summary(submitMilliseconds)]
        for key in ["admission_to_callback_ms", "preparation_ms", "backend_preparation_ms", "backend_call_ms", "gpu_queue_ms", "gpu_execution_ms", "gpu_end_to_callback_ms"] {
            summaries[key] = summary(snapshot.1.compactMap { $0[key] })
        }
        // Correctness checksum is outside the timed loop. It uses the production
        // renderer and validates that both compared builds produce identical RGB.
        guard let last = samples.lastFrame else { throw NSError(domain: "PyrowaveBenchmark", code: 5) }
        let renderer = try MetalVideoRenderer()
        let target = try renderer.makeReadbackTarget(width: width, height: height)
        guard try renderer.render(last, into: target) else { throw NSError(domain: "PyrowaveBenchmark", code: 6) }
        try renderer.waitUntilIdleForValidation()
        var pixels = Data(count: width * height * 16)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 16,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let report: [String: Any] = ["scope": "offscreen production decoder timing; renderer checksum after timing; no network, display, or input-to-photon measurement",
            "fixture_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "rendered_rgba32float_sha256": SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined(),
            "compressed_bytes": bytes.count, "width": width, "height": height, "chroma": chroma == 3 ? "444" : "420", "bit_depth": depth,
            "requested_fps": fps, "measured_frames": frames, "warmup_frames": warmup, "capacity": 2,
            "late_admissions_over_0_1_ms": lateAdmissions, "maximum_admission_lateness_ms": maximumAdmissionLateness,
            "accepted": statistics.accepted, "completed": statistics.completed, "would_block": statistics.wouldBlock,
            "outstanding_high_water": statistics.outstandingHighWater, "mailbox_high_water": statistics.mailboxHighWater,
            "thermal_state_before": thermalBefore, "thermal_state_after": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power_mode": lowPower, "gpu_device": renderer.device.name,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "vt_timing_samples": statistics.singleSampleVTSubmitToCallbackMilliseconds.count, "summaries_ms": summaries, "samples": snapshot.1]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: arguments[6]))
        print("\(width)x\(height) \(fps) FPS, \(frames) samples: \(summaries["admission_to_callback_ms"] ?? [:])")
    }
}
