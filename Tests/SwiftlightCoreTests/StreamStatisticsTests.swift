import XCTest
@testable import SwiftlightCore

final class StreamStatisticsTests: XCTestCase {
    func testShortcutsConsumeRepeatsAndLateKeyUpWithoutForwarding() {
        var state = StreamShortcutState()
        XCTAssertEqual(state.keyDown("s", chordMatches: true, isRepeat: false), .consume(.toggleStatistics))
        XCTAssertEqual(state.keyDown("s", chordMatches: false, isRepeat: true), .consume(nil))
        XCTAssertEqual(state.keyUp("s"), .consume(nil))
        XCTAssertEqual(state.keyDown("s", chordMatches: false, isRepeat: false), .forward)
        XCTAssertEqual(state.keyUp("s"), .forward)
        XCTAssertEqual(state.keyDown("q", chordMatches: true, isRepeat: false), .consume(.disconnect))
        XCTAssertEqual(state.keyDown("z", chordMatches: true, isRepeat: false), .consume(.releaseInput))
        XCTAssertEqual(state.keyDown("x", chordMatches: true, isRepeat: false), .forward)
    }
    func testAlreadyForwardedKeyKeepsItsRepeatAndReleaseWhenModifiersChange() {
        var state = StreamShortcutState()
        XCTAssertEqual(state.keyDown("s", chordMatches: false, isRepeat: false), .forward)
        XCTAssertEqual(state.keyDown("s", chordMatches: true, isRepeat: true), .forward)
        XCTAssertEqual(state.keyUp("s"), .forward)
        XCTAssertEqual(state.keyDown("s", chordMatches: true, isRepeat: false), .consume(.toggleStatistics))
    }
    func testTimingMissingInvalidAndStaleSamples() {
        var window = StreamTimingWindow()
        XCTAssertNil(window.record(nil, at: 1))
        XCTAssertNil(window.record(.nan, at: 1.1))
        XCTAssertEqual(window.record(0, at: 2)?.averageMilliseconds, 0)
        XCTAssertEqual(window.record(4, at: 3)?.averageMilliseconds, 2)
        XCTAssertNil(window.record(nil, at: 9))
        XCTAssertNil(StreamTimingSummary(sampleCount: 1, minimum: 5, maximum: 3, average: 4))
    }
    func testRateUsesFrameDeltasAndResetsAcrossSessions() {
        var window = StreamFrameRateWindow()
        XCTAssertNil(window.record(receivedFrames: 900, at: 10))
        XCTAssertEqual(window.record(receivedFrames: 930, at: 10.5), 60)
        XCTAssertEqual(window.record(receivedFrames: 960, at: 11), 60)
        XCTAssertNil(window.record(receivedFrames: 0, at: 12))
        XCTAssertEqual(window.record(receivedFrames: 0, at: 13), 0)
        XCTAssertNil(window.record(receivedFrames: 300, at: 25))
        XCTAssertNil(window.record(receivedFrames: 5, at: 1))
    }
    func testUnavailableStatisticsNeverBecomeZeroOrRequestedFPS() {
        var snapshot = StreamStatisticsSnapshot()
        snapshot.requestedVideo = "3440 × 1440 · 165 Hz"
        let simple = snapshot.lines(detail: .simple)
        XCTAssertTrue(simple.contains { $0.id == "received" && $0.value.contains("Measuring FPS") })
        XCTAssertEqual(simple.first { $0.id == "decode" }?.value, "Unavailable")
        XCTAssertFalse(simple.contains { $0.id == "end-to-end" })
        XCTAssertNil(snapshot.estimatedHostToDisplayMilliseconds)
        snapshot.hostProcessingAndClientPresentation = StreamTimingSummary(samples: [5, 7])
        XCTAssertNil(snapshot.estimatedHostToDisplayMilliseconds)
        snapshot.networkRoundTrip = StreamTimingSummary(samples: [4, 4])
        XCTAssertEqual(snapshot.estimatedHostToDisplayMilliseconds, 8)
        let detailed = snapshot.lines(detail: .detailed)
        XCTAssertEqual(detailed.first { $0.id == "network" }?.value, "4.00 / 4.00 / 4.00 ms")
        XCTAssertEqual(detailed.first { $0.id == "end-to-end" }?.label, "Host → display (estimated)")
        snapshot.firstPacketToPresentation = StreamTimingSummary(samples: [5, 25])
        snapshot.currentFirstPacketToPresentationMilliseconds = 25
        XCTAssertEqual(snapshot.lines(detail: .simple).first { $0.id == "client" }?.value, "25.00 ms")
        XCTAssertEqual(snapshot.lines(detail: .detailed).first { $0.id == "client" }?.value, "5.00 / 25.00 / 15.00 ms")
        snapshot.currentFirstPacketToPresentationMilliseconds = nil
        XCTAssertEqual(snapshot.lines(detail: .simple).first { $0.id == "client" }?.value, "Unavailable")
    }
}
