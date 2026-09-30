import XCTest
import MoonlightAppleVideo
@testable import SwiftlightVideo

final class DecodeStageTimingTests: XCTestCase {
    private func traces() -> (mav_trace, mav_decode_trace) {
        var trace = mav_trace()
        trace.valid = UInt32(MAV_TRACE_PREPARATION | MAV_TRACE_CALLBACK)
        trace.admission_ns = 10_000_000; trace.preparation_start_ns = 10_000_000
        trace.preparation_end_ns = 11_000_000; trace.callback_ns = 20_000_000
        var backend = mav_decode_trace()
        backend.struct_size = UInt32(MemoryLayout<mav_decode_trace>.size); backend.version = UInt32(MAV_ABI_VERSION)
        backend.valid = UInt32(MAV_DECODE_TRACE_BACKEND_START | MAV_DECODE_TRACE_BACKEND_SUBMIT |
            MAV_DECODE_TRACE_BACKEND_RETURN | MAV_DECODE_TRACE_GPU_COMMIT | MAV_DECODE_TRACE_GPU_EXECUTION)
        backend.backend_start_ns = 12_000_000; backend.backend_submit_ns = 13_000_000
        backend.backend_return_ns = 14_000_000; backend.gpu_commit_ns = 15_000_000
        backend.gpu_start_ns = 16_000_000; backend.gpu_end_ns = 18_000_000
        backend.gpu_clock_uncertainty_ns = 25
        return (trace, backend)
    }

    func testSameFrameDecodeStagesReconcileAndReachBothRendererPopulations() throws {
        let (trace, backend) = traces()
        let stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
        let decodePath = [stages.admissionToPreparationStartMilliseconds, stages.preparationMilliseconds,
            stages.preparationEndToBackendStartMilliseconds, stages.backendPreparationMilliseconds,
            stages.backendCallMilliseconds, stages.backendReturnToGPUCommitMilliseconds,
            stages.gpuCommitToStartMilliseconds, stages.gpuExecutionMilliseconds, stages.gpuEndToCallbackMilliseconds]
        XCTAssertEqual(decodePath.compactMap { $0 }.count, 9)
        XCTAssertEqual(decodePath.compactMap { $0 }.reduce(0, +), 10)
        XCTAssertEqual(stages.admissionToCallbackMilliseconds, 10)
        XCTAssertEqual(stages.backendReturnToCallbackMilliseconds, 6)
        let frame = FramePresentationMetadata(frameID: 31, generation: 9, callbackNanoseconds: 20_000_000,
            firstPacketNanoseconds: 5_000_000, scheduledArrivalNanoseconds: 8_000_000,
            admissionNanoseconds: 10_000_000, decodeStages: stages)
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 20_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        var submission = FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100.001, commitSeconds: 100.002)
        submission.gpuStartSeconds = 100.003; submission.gpuEndSeconds = 100.004
        submission.completedCallbackSeconds = 100.005
        let gpu = GPUFrameTiming(frame, submission: submission, succeeded: true, calibration: calibration)
        var window = PresentationTimingWindow()
        window.record(frame, presented: 100.006, calibration: calibration, submission: submission)
        let presented = try XCTUnwrap(window.samples.first)
        for value in [gpu.decodeGPUEndToRenderStartMilliseconds, presented.decodeGPUEndToRenderStartMilliseconds] {
            XCTAssertEqual(try XCTUnwrap(value), 3, accuracy: 0.000001)
        }
        XCTAssertEqual(gpu.decodeGPUToRenderCalibrationUncertaintyNanoseconds, 75)
        XCTAssertEqual(presented.decodeGPUToRenderCalibrationUncertaintyNanoseconds, 75)
        XCTAssertEqual(gpu.decodeStages?.gpuClockUncertaintyNanoseconds, 25)
        XCTAssertEqual(presented.decodeStages?.preparationMilliseconds, 1)
        XCTAssertEqual(gpu.firstPacketToArrivalMilliseconds, 3)
        XCTAssertEqual(gpu.arrivalToAdmissionMilliseconds, 2)
        let beforeRender = 3.0 + 2.0 + decodePath.compactMap { $0 }.reduce(0, +)
        let rendered = [presented.decodeCallbackToRenderStartMilliseconds, presented.renderCPUToCommitMilliseconds,
            presented.commitToGPUStartMilliseconds, presented.gpuExecutionMilliseconds, presented.gpuEndToPresentationMilliseconds]
        XCTAssertEqual(beforeRender + rendered.compactMap { $0 }.reduce(0, +),
            try XCTUnwrap(presented.firstPacketToPresentationMilliseconds), accuracy: 0.000001)
        XCTAssertNil(presented.admissionToVTSubmitMilliseconds)
        XCTAssertNil(presented.vtSubmitToDecodeCallbackMilliseconds)
        let uncalibrated = GPUFrameTiming(frame, submission: submission, succeeded: true, calibration: nil)
        XCTAssertNil(uncalibrated.decodeGPUEndToRenderStartMilliseconds)
        XCTAssertNil(uncalibrated.decodeGPUToRenderCalibrationUncertaintyNanoseconds)
        XCTAssertEqual(uncalibrated.decodeStages?.gpuExecutionMilliseconds, 2)
    }

    func testMissingValidityFlagsDoNotExposePopulatedTimestampBytes() {
        var (trace, backend) = traces()
        trace.valid = 0; backend.valid = 0
        XCTAssertNil(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
    }

    func testInvertedOutOfBoundsAndUncertainStagesRemainUnavailable() throws {
        var (trace, backend) = traces()
        trace.preparation_end_ns = trace.preparation_start_ns - 1
        backend.backend_return_ns = backend.backend_submit_ns - 1
        backend.gpu_start_ns = backend.gpu_end_ns + 1
        var stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
        XCTAssertNil(stages.preparationMilliseconds)
        XCTAssertNil(stages.backendCallMilliseconds)
        XCTAssertNil(stages.gpuExecutionMilliseconds)
        XCTAssertNil(stages.gpuClockUncertaintyNanoseconds)
        (trace, backend) = traces(); backend.gpu_clock_uncertainty_ns = 1_000_001
        stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
        XCTAssertNil(stages.gpuStartNanoseconds)
        XCTAssertNil(stages.gpuEndToCallbackMilliseconds)
        (trace, backend) = traces(); backend.backend_start_ns = trace.admission_ns - 1
        backend.backend_return_ns = trace.callback_ns + 1
        backend.gpu_start_ns = backend.gpu_commit_ns - 1
        stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
        XCTAssertNil(stages.backendStartNanoseconds)
        XCTAssertNil(stages.backendReturnNanoseconds)
        XCTAssertNil(stages.gpuExecutionMilliseconds)
        (trace, backend) = traces(); backend.version = 0
        stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
        XCTAssertEqual(stages.preparationMilliseconds, 1)
        XCTAssertNil(stages.backendStartNanoseconds)
        backend.version = UInt32(MAV_ABI_VERSION); backend.struct_size = 8
        stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: 1, showExisting: false))
        XCTAssertNil(stages.backendStartNanoseconds)
    }

    func testAggregateAndShowExistingCompletionsPreserveOnlyPreparation() throws {
        let (trace, backend) = traces()
        for (count, existing) in [(UInt32(2), false), (UInt32(1), true)] {
            let stages = try XCTUnwrap(DecodeStageTiming(trace: trace, backend: backend, internalSamples: count, showExisting: existing))
            XCTAssertEqual(stages.preparationMilliseconds, 1)
            XCTAssertNil(stages.backendCallMilliseconds)
            XCTAssertNil(stages.gpuExecutionMilliseconds)
        }
    }

    func testLegacyCompletionCopyPreservesProducerSizeAndIgnoresPoisonedTail() throws {
        let legacySize = try XCTUnwrap(MemoryLayout<mav_completion>.offset(of: \.decode_trace))
        var source = mav_completion()
        source.struct_size = UInt32(legacySize); source.version = UInt32(MAV_ABI_VERSION)
        source.frame_id = 31; source.generation = 9
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<mav_completion>.size,
            alignment: MemoryLayout<mav_completion>.alignment)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0xa5, count: MemoryLayout<mav_completion>.size)
        withUnsafeBytes(of: source) { pointer.copyMemory(from: $0.baseAddress!, byteCount: legacySize) }
        var copied = try XCTUnwrap(copyBorrowedDecoderCompletion(pointer.assumingMemoryBound(to: mav_completion.self)))
        XCTAssertEqual(copied.struct_size, UInt32(legacySize))
        XCTAssertEqual(copied.frame_id, 31); XCTAssertEqual(copied.generation, 9)
        XCTAssertEqual(copied.decode_trace.version, 0)
        var backend = mav_decode_trace()
        backend.struct_size = UInt32(MemoryLayout<mav_decode_trace>.size); backend.version = UInt32(MAV_ABI_VERSION)
        XCTAssertEqual(mav_completion_get_decode_trace(&copied, &backend), MAV_API_UNAVAILABLE)
        source.struct_size = 8
        withUnsafePointer(to: &source) { XCTAssertNil(copyBorrowedDecoderCompletion($0)) }
    }
}
