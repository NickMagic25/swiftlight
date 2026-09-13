import XCTest
@testable import SwiftlightVideo

final class TimingStatisticsTests: XCTestCase {
    func testCurrentPresentationUsesPresentationOrderAndExpires() throws {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        var window = PresentationTimingWindow()
        // Fill and wrap the ring, then deliver an older presentation callback.
        for id in 0..<1100 {
            window.record(FramePresentationMetadata(frameID: UInt64(id), callbackNanoseconds: 995_000_000,
                firstPacketNanoseconds: 990_000_000), presented: 100 + Double(id) / 1000, calibration: calibration)
        }
        window.record(FramePresentationMetadata(frameID: 2000, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000), presented: 100.5, calibration: calibration)
        var statistics = RenderStatistics(); statistics.presentationTimings = window.samples
        XCTAssertEqual(try XCTUnwrap(statistics.currentFirstPacketToPresentationMilliseconds(at: 102)), 1109, accuracy: 0.000001)
        XCTAssertNil(statistics.currentFirstPacketToPresentationMilliseconds(at: 106.100))
        XCTAssertNil(statistics.currentFirstPacketToPresentationMilliseconds(at: 100))
        XCTAssertNil(statistics.currentFirstPacketToPresentationMilliseconds(at: .nan))
        // The newest frame has no receive timestamp; an older valid frame must not stand in for it.
        window.record(FramePresentationMetadata(frameID: 2001, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 0), presented: 102, calibration: calibration)
        statistics.presentationTimings = window.samples
        XCTAssertNil(statistics.currentFirstPacketToPresentationMilliseconds(at: 102.1))
    }

    func testBoundedSummaryExcludesUnavailableValues() {
        let empty = TimingSummary(milliseconds: [.nan, .infinity, -1])
        XCTAssertEqual(empty.count, 0); XCTAssertNil(empty.averageMilliseconds)
        XCTAssertNil(empty.minimumMilliseconds); XCTAssertNil(empty.maximumMilliseconds)
        let summary = TimingSummary(milliseconds: (1...1040).map(Double.init))
        XCTAssertEqual(summary.count, 1024)
        XCTAssertEqual(summary.minimumMilliseconds, 17); XCTAssertEqual(summary.maximumMilliseconds, 1040)
        XCTAssertEqual(summary.averageMilliseconds, 528.5)
    }

    func testClockCalibrationMapsDifferentEpochsAndRejectsMissingOrNegativeIntervals() throws {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        XCTAssertEqual(try XCTUnwrap(calibration.milliseconds(from: 990_000_000, toPresentedSeconds: 100.004)), 14, accuracy: 0.000001)
        XCTAssertNil(calibration.milliseconds(from: 0, toPresentedSeconds: 100.004))
        XCTAssertNil(calibration.milliseconds(from: 990_000_000, toPresentedSeconds: 99.98))
        XCTAssertNil(calibration.milliseconds(from: 990_000_000, toPresentedSeconds: .nan))
        let tooUncertain = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 1_000_001)
        XCTAssertNil(tooUncertain.milliseconds(from: 990_000_000, toPresentedSeconds: 100.004))
    }

    func testPresentationDeduplicatesRedrawAndPairsHostDurationOnSameFrame() throws {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000, hostProcessingMilliseconds: 2.5)
        var window = PresentationTimingWindow()
        window.record(frame, presented: 100.006, calibration: calibration)
        window.record(frame, presented: 100.020, calibration: calibration)
        // An earlier presentation delivered out of order replaces the same frame.
        window.record(frame, presented: 100.004, calibration: calibration)
        window.record(FramePresentationMetadata(frameID: 2, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000), presented: 100.008, calibration: calibration)
        window.record(FramePresentationMetadata(frameID: 3, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 0, hostProcessingMilliseconds: 100), presented: 100.008, calibration: calibration)
        window.record(FramePresentationMetadata(frameID: 4, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 996_000_000), presented: 100.008, calibration: calibration)
        var statistics = RenderStatistics(); statistics.presentationTimings = window.samples
        XCTAssertEqual(statistics.presentationTimings.count, 4)
        XCTAssertEqual(statistics.firstPacketToPresentation.count, 2)
        XCTAssertEqual(try XCTUnwrap(statistics.firstPacketToPresentation.averageMilliseconds), 16, accuracy: 0.000001)
        XCTAssertEqual(statistics.hostProcessingAndClientPresentation.count, 1)
        XCTAssertEqual(try XCTUnwrap(statistics.hostProcessingAndClientPresentation.averageMilliseconds), 16.5, accuracy: 0.000001)
        XCTAssertEqual(statistics.presentationTimingUnavailableCount, 2)
        XCTAssertEqual(statistics.presentationClockUncertaintyNanoseconds, 50)
    }

    func testPresentationRingIsBoundedAndDecoderGenerationDoesNotAlias() {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        var window = PresentationTimingWindow()
        for id in 0..<1100 {
            window.record(FramePresentationMetadata(frameID: UInt64(id), callbackNanoseconds: 995_000_000,
                firstPacketNanoseconds: 990_000_000), presented: 100.004, calibration: calibration)
        }
        XCTAssertEqual(window.samples.count, 1024)
        XCTAssertEqual(Set(window.samples.map(\.frameID)), Set((76..<1100).map(UInt64.init)))
        window.record(FramePresentationMetadata(frameID: 1099, generation: 1, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000), presented: 100.004, calibration: calibration)
        XCTAssertEqual(window.samples.filter { $0.frameID == 1099 }.count, 2)
        XCTAssertEqual(window.samples.count, 1024)
        window.record(FramePresentationMetadata(frameID: 9999, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000), presented: 0, calibration: calibration)
        XCTAssertFalse(window.samples.contains { $0.frameID == 9999 })
    }
}
