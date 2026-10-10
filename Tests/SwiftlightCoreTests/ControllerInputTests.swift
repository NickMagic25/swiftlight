import XCTest
@testable import SwiftlightCore

final class ControllerInputTests: XCTestCase {
    func testGuideUsesHostSpecialFlagAndDoesNotActivateMenuCommands() {
        XCTAssertEqual(ControllerButtons.guide.rawValue, 0x0400)
        let buttons: ControllerButtons = [.a, .menu, .guide]
        XCTAssertEqual(buttons.rawValue, 0x1410)
        var menu = ControllerMenuInputState()
        XCTAssertEqual(menu.consume(.init(buttons: [.guide]), at: 0), [])
        XCTAssertEqual(menu.consume(.neutral, at: 1), [])
        XCTAssertEqual(menu.consume(.init(buttons: [.guide, .menu]), at: 2), [.settings])
        XCTAssertEqual(menu.consume(.init(buttons: [.guide]), at: 3), [])
        XCTAssertEqual(menu.consume(.init(buttons: [.guide, .a]), at: 4), [.activate])
    }

    func testWireValuesAreBoundedWithoutAddingAStreamingDeadZone() {
        let input = ControllerInputState(buttons: [.a, .menu], leftTrigger: 1, rightTrigger: 0.5,
            leftX: -1, leftY: 1, rightX: 0.001, rightY: -0.001)
        XCTAssertEqual(input.buttons.rawValue, 0x1010)
        XCTAssertEqual(input.leftTrigger, 255); XCTAssertEqual(input.rightTrigger, 127)
        XCTAssertEqual(input.leftX, -32767); XCTAssertEqual(input.leftY, 32767)
        XCTAssertEqual(input.rightX, 32); XCTAssertEqual(input.rightY, -32)
        let bounded = ControllerInputState(leftTrigger: -2, rightTrigger: 3, leftX: -4, leftY: 4,
                                           rightX: .nan, rightY: .infinity)
        XCTAssertEqual(bounded.leftTrigger, 0); XCTAssertEqual(bounded.rightTrigger, 255)
        XCTAssertEqual(bounded.leftX, -32767); XCTAssertEqual(bounded.leftY, 32767)
        XCTAssertEqual(bounded.rightX, 0); XCTAssertEqual(bounded.rightY, 0)
    }

    func testSelectingAGameAndResumingCaptureCannotReplayHeldControls() {
        let held = ControllerInputState(buttons: [.a, .leftShoulder], leftTrigger: 0.7, leftX: 0.8, rightY: -0.8)
        var admission = ControllerInputState.Admission(held: held)
        XCTAssertEqual(admission.admit(held), .neutral)
        // A new control can be used while the launch/capture buttons remain held.
        let next = admission.admit(.init(buttons: [.a, .b], leftTrigger: 1, leftX: 0.5, rightY: -0.5))
        XCTAssertEqual(next.buttons, [.b]); XCTAssertEqual(next.leftTrigger, 0)
        XCTAssertEqual(next.leftX, 0); XCTAssertEqual(next.rightY, 0)
        XCTAssertEqual(admission.admit(.neutral), .neutral)
        XCTAssertEqual(admission.admit(held), held)
    }

    func testMenuFaceButtonsAreEdgesAndConflictingPressesDoNotActivate() {
        var menu = ControllerMenuInputState()
        XCTAssertEqual(menu.consume(.init(buttons: [.a]), at: 0), [.activate])
        XCTAssertEqual(menu.consume(.init(buttons: [.a], rightTrigger: 1), at: 1), [])
        XCTAssertEqual(menu.consume(.neutral, at: 2), [])
        XCTAssertEqual(menu.consume(.init(buttons: [.a, .b]), at: 3), [.back])
        _ = menu.consume(.neutral, at: 4)
        XCTAssertEqual(menu.consume(.init(buttons: [.menu]), at: 5), [.settings])
    }

    func testNewMenuRouteDoesNotActivateOrRepeatButtonsAlreadyHeld() {
        let held = ControllerInputState(buttons: [.a, .up])
        var menu = ControllerMenuInputState(held: held)
        XCTAssertEqual(menu.consume(held, at: 1), [])
        XCTAssertNil(menu.repeatAction(at: 2))
        XCTAssertFalse(menu.isRepeating)
        _ = menu.consume(.neutral, at: 3)
        XCTAssertEqual(menu.consume(held, at: 4), [.move(.up), .activate])
    }

    func testMenuDirectionRepeatIsBoundedAndStopsAtNeutral() {
        var menu = ControllerMenuInputState()
        XCTAssertEqual(menu.consume(.init(buttons: [.right]), at: 1), [.move(.right)])
        XCTAssertNil(menu.repeatAction(at: 1.39))
        XCTAssertEqual(menu.repeatAction(at: 1.4), .move(.right))
        // A stalled UI produces a single step, never an accumulated burst.
        XCTAssertEqual(menu.repeatAction(at: 10), .move(.right))
        XCTAssertNil(menu.repeatAction(at: 10.01))
        XCTAssertEqual(menu.consume(.neutral, at: 11), [])
        XCTAssertNil(menu.repeatAction(at: 12))
        XCTAssertFalse(menu.isRepeating)
    }

    func testMenuStickHysteresisAndDPadPriority() {
        var menu = ControllerMenuInputState()
        XCTAssertEqual(menu.consume(.init(leftX: 0.3), at: 0), [])
        XCTAssertEqual(menu.consume(.init(leftX: 0.6), at: 1), [.move(.right)])
        XCTAssertEqual(menu.consume(.init(leftX: 0.4), at: 1.1), [])
        XCTAssertEqual(menu.consume(.init(leftX: 0.3), at: 1.2), [])
        XCTAssertFalse(menu.isRepeating)
        XCTAssertEqual(menu.consume(.init(buttons: [.down], leftX: 1), at: 2), [.move(.down)])
        XCTAssertEqual(menu.consume(.init(leftX: -0.8, leftY: 0.2), at: 3), [.move(.left)])
    }
}
