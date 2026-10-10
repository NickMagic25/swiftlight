import SwiftlightCore
import Testing
@testable import SwiftlightApp

struct ControllerMenuNavigationTests {
    @Test func gridMovementFollowsRowsAndShortLastRow() {
        #expect(ControllerMenuNavigation.nextIndex(current: 2, count: 8, columns: 3, direction: .right) == 2)
        #expect(ControllerMenuNavigation.nextIndex(current: 3, count: 8, columns: 3, direction: .left) == 3)
        #expect(ControllerMenuNavigation.nextIndex(current: 5, count: 8, columns: 3, direction: .down) == 7)
        #expect(ControllerMenuNavigation.nextIndex(current: 7, count: 8, columns: 3, direction: .down) == 7)
        #expect(ControllerMenuNavigation.nextIndex(current: 7, count: 8, columns: 3, direction: .up) == 4)
        #expect(ControllerMenuNavigation.nextIndex(current: 0, count: 8, columns: 3, direction: .up) == 0)
    }

    @Test func emptyStaleAndResizedSelectionsRemainBounded() {
        #expect(ControllerMenuNavigation.nextIndex(current: 0, count: 0, columns: 3, direction: .down) == nil)
        #expect(ControllerMenuNavigation.nextIndex(current: 6, count: 2, columns: 3, direction: .down) == 0)
        #expect(ControllerMenuNavigation.nextIndex(current: nil, count: 2, columns: 0, direction: .up) == 0)
        #expect(ControllerMenuNavigation.nextIndex(current: 1, count: 4, columns: 1, direction: .down) == 2)
        #expect(ControllerMenuNavigation.columnCount(width: 500, minimum: 140, spacing: 16) == 3)
        #expect(ControllerMenuNavigation.columnCount(width: 300, minimum: 140, spacing: 16) == 2)
        #expect(ControllerMenuNavigation.columnCount(width: 100, minimum: 140, spacing: 16) == 1)
        #expect(ControllerMenuNavigation.columnCount(width: .infinity, minimum: 140, spacing: 16) == 1)
    }

    @Test func regionChangesPreserveComputerSelectionAndClearOtherHostsGame() {
        var navigation = ControllerMenuNavigation()
        let computers = ["saved:a", "saved:b", "add"]
        navigation.move(.down, computers: computers, applications: [10, 20, 30, 40])
        #expect(navigation.computerID == "saved:a")
        navigation.move(.down, computers: computers, applications: [10, 20, 30, 40])
        #expect(navigation.computerID == "saved:b")
        navigation.move(.right, computers: computers, applications: [10, 20, 30, 40])
        #expect(navigation.region == .applications && navigation.applicationID == 10)
        navigation.applicationColumns = 2
        navigation.move(.right, computers: computers, applications: [10, 20, 30, 40])
        #expect(navigation.applicationID == 20)
        navigation.move(.left, computers: computers, applications: [10, 20, 30, 40])
        #expect(navigation.region == .applications && navigation.applicationID == 10)
        navigation.move(.left, computers: computers, applications: [10, 20, 30, 40])
        #expect(navigation.region == .computers && navigation.computerID == "saved:b")
        navigation.selectedComputer("saved:a")
        #expect(navigation.region == .applications && navigation.applicationID == nil)
        navigation.returnToComputers(["add"])
        #expect(navigation.region == .computers && navigation.computerID == "add")
    }
}
