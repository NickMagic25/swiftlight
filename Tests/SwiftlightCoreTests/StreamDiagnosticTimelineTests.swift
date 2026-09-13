import Foundation
import XCTest
@testable import SwiftlightCore

final class StreamDiagnosticTimelineTests: XCTestCase {
    func testRateLimitBoundAndFinalSample() {
        var timeline = StreamDiagnosticTimeline(startedAt: Date(timeIntervalSince1970: 100), uptime: 10)
        for tick in 0..<2800 {
            timeline.record(StreamStatisticsSnapshot(), phase: "streaming", uptime: 10 + Double(tick) / 4)
        }
        XCTAssertEqual(timeline.samples.count, 600)
        XCTAssertEqual(timeline.discardedSamples, 100)
        var final = StreamStatisticsSnapshot(); final.networkLostFrames = 42
        timeline.finish(final, outcome: "disconnecting", endedAt: Date(timeIntervalSince1970: 90), uptime: 710)
        XCTAssertEqual(timeline.durationSeconds, 700) // wall clock moved backward
        XCTAssertEqual(timeline.samples.last?.statistics.networkLostFrames, 42)
        XCTAssertEqual(timeline.samples.count, 600)
        XCTAssertEqual(timeline.discardedSamples, 101)
    }
    func testFailureBeforeFirstFrameAndFrozenCompletion() throws {
        var timeline = StreamDiagnosticTimeline(uptime: 5)
        timeline.finish(StreamStatisticsSnapshot(), outcome: "failed", uptime: 5.2)
        timeline.record(StreamStatisticsSnapshot(), phase: "streaming", uptime: 10)
        timeline.finish(StreamStatisticsSnapshot(), outcome: "disconnecting", uptime: 11)
        XCTAssertEqual(timeline.outcome, "failed")
        XCTAssertEqual(timeline.samples.count, 1)
        XCTAssertNil(timeline.samples.first?.statistics.receivedSize)
        let copy = try JSONDecoder().decode(StreamDiagnosticTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(copy.outcome, "failed")
        XCTAssertEqual(copy.samples.count, 1)
    }
    func testInvalidAndBackwardClocksDoNotPolluteMeasurements() {
        var timeline = StreamDiagnosticTimeline(uptime: 10)
        for time in [Double.nan, .infinity, 9, 10, 9.5, 10.5, 11] {
            timeline.record(StreamStatisticsSnapshot(), phase: "streaming", uptime: time)
        }
        XCTAssertEqual(timeline.samples.map(\.elapsedSeconds), [0, 1])
        timeline.finish(StreamStatisticsSnapshot(), outcome: "failed", uptime: .nan)
        XCTAssertNil(timeline.durationSeconds)
        XCTAssertEqual(timeline.samples.count, 2)
    }
}
