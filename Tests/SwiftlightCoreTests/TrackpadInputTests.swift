import Foundation
import XCTest
@testable import SwiftlightCore

final class TrackpadInputTests: XCTestCase {
    func testSingleFingerMovesRelativelyAndRetainsFractionalMovement() {
        var state = TrackpadInputState()
        XCTAssertEqual(state.consume([contact(1)], phase: .began, at: 0), [])
        XCTAssertEqual(state.consume([contact(1, 0.4)], phase: .moved, at: 0.01), [])
        XCTAssertEqual(state.consume([contact(1, 0.8)], phase: .moved, at: 0.02), [])
        XCTAssertEqual(state.consume([contact(1, 1.2)], phase: .moved, at: 0.03), [.move(dx: 1, dy: 0)])
        XCTAssertEqual(state.consume([contact(1, 0.5)], phase: .moved, at: 0.04), [])
        XCTAssertEqual(state.consume([contact(1, -0.1)], phase: .moved, at: 0.05), [.move(dx: -1, dy: 0)])
    }

    func testSingleTapClicksButLongHoldAndMovementDoNot() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        XCTAssertEqual(state.consume([contact(1, 1, 1)], phase: .ended, at: 0.1), leftClick)
        _ = state.consume([contact(2)], phase: .began, at: 1)
        XCTAssertEqual(state.consume([contact(2)], phase: .ended, at: 1.4), [])
        _ = state.consume([contact(3)], phase: .began, at: 2)
        XCTAssertEqual(state.consume([contact(3, 7)], phase: .moved, at: 2.05), [.move(dx: 7, dy: 0)])
        XCTAssertEqual(state.consume([contact(3, 7)], phase: .ended, at: 2.1), [])
    }

    func testDoubleTapHoldDragsAndReleasesExactlyOnceOnLift() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        XCTAssertEqual(state.consume([contact(1)], phase: .ended, at: 0.05), leftClick)
        XCTAssertEqual(state.consume([contact(2, 40, 40)], phase: .began, at: 0.2), [.button(button: 1, pressed: true)])
        XCTAssertEqual(state.consume([contact(2, 50, 45)], phase: .moved, at: 0.3), [.move(dx: 10, dy: 5)])
        XCTAssertEqual(state.consume([contact(2, 50, 45)], phase: .ended, at: 1), [.button(button: 1, pressed: false)])
        XCTAssertEqual(state.consume([contact(2)], phase: .ended, at: 1.1), [])
        XCTAssertEqual(state.reset(), [])
    }

    func testSecondShortTapClicksAndExpiredDoubleTapDoesNotHold() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        _ = state.consume([contact(1)], phase: .ended, at: 0.05)
        XCTAssertEqual(state.consume([contact(2)], phase: .began, at: 0.1), [.button(button: 1, pressed: true)])
        XCTAssertEqual(state.consume([contact(2)], phase: .ended, at: 0.15), [.button(button: 1, pressed: false)])
        _ = state.consume([contact(3)], phase: .began, at: 1)
        _ = state.consume([contact(3)], phase: .ended, at: 1.05)
        XCTAssertEqual(state.consume([contact(4)], phase: .began, at: 1.31), [])
        XCTAssertEqual(state.consume([contact(4)], phase: .ended, at: 1.35), leftClick)
    }

    func testTwoFingerTapRightClicksAfterBothLiftWithoutScrollingJitter() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        _ = state.consume([contact(2, 20)], phase: .began, at: 0.01)
        XCTAssertEqual(state.consume([contact(1, 1, 2), contact(2, 21, 2)], phase: .moved, at: 0.05), [])
        XCTAssertEqual(state.consume([contact(1, 1, 2)], phase: .ended, at: 0.1), [])
        XCTAssertEqual(state.consume([contact(2, 21, 2)], phase: .ended, at: 0.11), [
            .button(button: 3, pressed: true), .button(button: 3, pressed: false)])
    }

    func testTwoFingerCentroidScrollsWithoutPointerOrClickAfterOneFingerLifts() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1), contact(2, 20)], phase: .began, at: 0)
        XCTAssertEqual(state.consume([contact(1, 4, 10), contact(2, 24, 10)], phase: .moved, at: 0.1), [
            .scroll(vertical: 70, horizontal: -28)])
        // Only the changed finger is supplied; both contribute to the centroid.
        XCTAssertEqual(state.consume([contact(1, 6, 12)], phase: .moved, at: 0.2), [.scroll(vertical: 7, horizontal: -7)])
        XCTAssertEqual(state.consume([contact(1, 6, 12)], phase: .ended, at: 0.3), [])
        XCTAssertEqual(state.consume([contact(2, 30, 20)], phase: .moved, at: 0.4), [])
        XCTAssertEqual(state.consume([contact(2, 30, 20)], phase: .ended, at: 0.5), [])
    }

    func testScrollingAccumulatesFractionalWheelUnits() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1), contact(2, 20)], phase: .began, at: 0)
        XCTAssertEqual(state.consume([contact(1, 0, 8), contact(2, 20, 8)], phase: .moved, at: 0.1), [
            .scroll(vertical: 56, horizontal: 0)])
        XCTAssertEqual(state.consume([contact(1, 0, 8.125), contact(2, 20, 8.125)], phase: .moved, at: 0.2), [])
        XCTAssertEqual(state.consume([contact(1, 0, 8.25), contact(2, 20, 8.25)], phase: .moved, at: 0.3), [
            .scroll(vertical: 1, horizontal: 0)])
    }

    func testJoiningSecondFingerReleasesDragBeforeScrolling() {
        var state = draggingState()
        XCTAssertEqual(state.consume([contact(3, 20)], phase: .began, at: 0.2), [.button(button: 1, pressed: false)])
        XCTAssertEqual(state.consume([contact(2, 0, 10), contact(3, 20, 10)], phase: .moved, at: 0.3), [
            .scroll(vertical: 70, horizontal: 0)])
        XCTAssertEqual(state.consume([contact(2, 0, 10), contact(3, 20, 10)], phase: .ended, at: 0.4), [])
        XCTAssertEqual(state.reset(), [])
    }

    func testThreeFingerGestureIsSuppressedUntilAllContactsLift() {
        var state = draggingState()
        XCTAssertEqual(state.consume([contact(3, 20), contact(4, 40)], phase: .began, at: 0.2), [
            .button(button: 1, pressed: false)])
        XCTAssertEqual(state.consume([contact(2, 30), contact(3, 50), contact(4, 70)], phase: .moved, at: 0.3), [])
        XCTAssertEqual(state.consume([contact(4, 70)], phase: .ended, at: 0.31), [])
        XCTAssertEqual(state.consume([contact(2, 40), contact(3, 60)], phase: .moved, at: 0.32), [])
        XCTAssertEqual(state.consume([contact(2, 40), contact(3, 60)], phase: .ended, at: 0.33), [])
        XCTAssertEqual(state.consume([contact(5)], phase: .began, at: 0.4), [])
        XCTAssertEqual(state.consume([contact(5)], phase: .ended, at: 0.45), leftClick)
    }

    func testCancellationAndResetReleaseDragAndDiscardDoubleTapLatch() {
        for cancelled in [false, true] {
            var state = draggingState()
            let actions = cancelled ? state.consume([contact(2)], phase: .cancelled, at: 0.2) : state.reset()
            XCTAssertEqual(actions, [.button(button: 1, pressed: false)])
            XCTAssertEqual(state.reset(), [])
            XCTAssertEqual(state.consume([contact(2)], phase: .ended, at: 0.21), [])
            XCTAssertEqual(state.consume([contact(3)], phase: .began, at: 0.22), [])
            XCTAssertEqual(state.consume([contact(3)], phase: .ended, at: 0.25), leftClick)
        }
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        _ = state.consume([contact(1)], phase: .ended, at: 0.05)
        _ = state.reset()
        XCTAssertEqual(state.consume([contact(2)], phase: .began, at: 0.1), [])
    }

    func testUnknownAndOutOfOrderEventsCannotReleaseAnActiveDrag() {
        var state = draggingState()
        XCTAssertEqual(state.consume([contact(1)], phase: .ended, at: 0.2), [])
        XCTAssertEqual(state.consume([contact(1)], phase: .cancelled, at: 0.21), [])
        XCTAssertEqual(state.consume([contact(2)], phase: .cancelled, at: 0.05), [])
        XCTAssertEqual(state.consume([contact(2)], phase: .ended, at: 0.3), [.button(button: 1, pressed: false)])
    }

    func testInvalidOrUnboundedInputReleasesDragAndClearsState() {
        let invalid: [([TrackpadContact], TimeInterval)] = [
            ([contact(2, .nan)], 0.2), ([contact(2, .infinity)], 0.2), ([contact(2)], .nan),
            ([contact(3), contact(3)], 0.2), ((0...10).map { contact($0) }, 0.2)]
        for (contacts, timestamp) in invalid {
            var state = draggingState()
            XCTAssertEqual(state.consume(contacts, phase: .began, at: timestamp), [.button(button: 1, pressed: false)])
            XCTAssertEqual(state.consume([contact(2)], phase: .ended, at: 0.3), [])
            XCTAssertEqual(state.reset(), [])
        }
    }

    func testLargeMovementIsBoundedWithoutQueuingFutureMotion() {
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        XCTAssertEqual(state.consume([contact(1, 1_000_000, -1_000_000)], phase: .moved, at: 0.1), [
            .move(dx: .max, dy: .min)])
        XCTAssertEqual(state.consume([contact(1, 1_000_000, -1_000_000)], phase: .moved, at: 0.2), [])
    }

    private var leftClick: [TrackpadAction] { [.button(button: 1, pressed: true), .button(button: 1, pressed: false)] }
    private func contact(_ id: Int, _ x: Double = 0, _ y: Double = 0) -> TrackpadContact {
        TrackpadContact(id: id, position: CGPoint(x: x, y: y))
    }
    private func draggingState() -> TrackpadInputState {
        var state = TrackpadInputState()
        _ = state.consume([contact(1)], phase: .began, at: 0)
        _ = state.consume([contact(1)], phase: .ended, at: 0.05)
        XCTAssertEqual(state.consume([contact(2)], phase: .began, at: 0.1), [.button(button: 1, pressed: true)])
        return state
    }
}
