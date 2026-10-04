import XCTest
@testable import SwiftlightVideo

final class TransportStageTimingTests: XCTestCase {
    private func timing(partial: Bool = false, last: UInt64 = 4_000_000,
                        fec: UInt64 = 5_000_000, handoff: UInt64 = 8_000_000) -> TransportStageTiming {
        TransportStageTiming(TransportFrameTiming(lastRequiredPacketNanoseconds: last,
            fecReadyNanoseconds: fec, queueOfferNanoseconds: 7_000_000,
            handoffNanoseconds: handoff, payloadBytes: 1_000_000, partialFrame: partial),
            firstPacket: 1_000_000, enqueue: 6_000_000, admission: 9_000_000)
    }

    func testTransportPathReconcilesAndSurvivesRenderPopulations() throws {
        let stages = timing()
        let path = [stages.firstPacketToLastRequiredPacketMilliseconds, stages.lastRequiredPacketToFECReadyMilliseconds,
            stages.fecReadyToEnqueueMilliseconds, stages.enqueueToQueueOfferMilliseconds,
            stages.queueOfferToHandoffMilliseconds, stages.handoffToAdmissionMilliseconds]
        XCTAssertEqual(path.compactMap { $0 }.count, 6)
        XCTAssertEqual(path.compactMap { $0 }.reduce(0, +), stages.firstPacketToAdmissionMilliseconds)
        let frame = DecodedFrame(pixelBuffer: nil, id: 11, generation: 7, width: 16, height: 16,
            bitDepth: 8, color: VideoColor(), callbackNanoseconds: 10_000_000,
            firstPacketNanoseconds: 1_000_000, admissionNanoseconds: 9_000_000,
            scheduledArrivalNanoseconds: 6_000_000, transportStages: stages)
        let metadata = FramePresentationMetadata(frame)
        let submission = FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 1, commitSeconds: 1.001)
        let completed = GPUFrameTiming(metadata, submission: submission, succeeded: true, calibration: nil)
        var window = PresentationTimingWindow()
        window.record(metadata, presented: 1.003, calibration: nil, submission: submission)
        XCTAssertEqual(completed.transportStages?.payloadBytes, 1_000_000)
        XCTAssertEqual(window.samples.first?.transportStages?.lastRequiredPacketNanoseconds, 4_000_000)
        let encoded = try JSONEncoder().encode(window.samples)
        let decoded = try JSONDecoder().decode([FramePresentationTiming].self, from: encoded)
        XCTAssertEqual(decoded.first?.transportStages?.firstPacketToAdmissionMilliseconds, 8)
    }

    func testPartialMissingAndInvalidMeasurementsStayUnavailable() {
        let partial = timing(partial: true)
        XCTAssertNil(partial.lastRequiredPacketNanoseconds)
        XCTAssertNil(partial.firstPacketToLastRequiredPacketMilliseconds)
        XCTAssertNil(partial.lastRequiredPacketToFECReadyMilliseconds)
        XCTAssertEqual(partial.fecReadyToEnqueueMilliseconds, 1)
        let missing = timing(last: 0, fec: 0, handoff: 0)
        XCTAssertNil(missing.lastRequiredPacketNanoseconds)
        XCTAssertNil(missing.fecReadyToEnqueueMilliseconds)
        XCTAssertNil(missing.queueOfferToHandoffMilliseconds)
        let invalid = timing(last: 500_000, fec: 7_500_000, handoff: 10_000_000)
        XCTAssertNil(invalid.firstPacketToLastRequiredPacketMilliseconds)
        XCTAssertNil(invalid.fecReadyToEnqueueMilliseconds)
        XCTAssertNil(invalid.handoffToAdmissionMilliseconds)
    }

    func testOldRecordsCanOmitTransportObject() throws {
        var window = PresentationTimingWindow()
        window.record(FramePresentationMetadata(frameID: 1, callbackNanoseconds: 0, firstPacketNanoseconds: 0),
            presented: 1, calibration: nil)
        let encoded = try JSONEncoder().encode(window.samples)
        let decoded = try JSONDecoder().decode([FramePresentationTiming].self, from: encoded)
        XCTAssertNil(decoded.first?.transportStages)
    }
}
