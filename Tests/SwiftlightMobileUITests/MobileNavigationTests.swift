import XCTest

@MainActor final class MobileNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
    }

    func testAddComputerRejectsInvalidAddressAndCanCancel() throws {
        launch()
        revealAddHost()
        app.buttons["addComputer"].tap()
        let address = app.textFields["computerAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("https://invalid.example/path")
        app.buttons["confirmAddComputer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["addComputerError"].firstMatch.waitForExistence(timeout: 5))
        attachScreenshot("Invalid address stays in Add Computer")
        app.buttons["cancelAddComputer"].tap()
        XCTAssertTrue(app.buttons["addComputer"].waitForExistence(timeout: 5))
        XCTAssertFalse(address.exists)
        attachScreenshot("Computer navigation after cancelling")
    }

    func testSettingsCancelDiscardsAndSavePersists() throws {
        launch()
        openSettings()
        let bitrate = app.switches["automaticBitrate"]
        XCTAssertTrue(bitrate.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(bitrate.value as? String)
        let changed = original == "1" ? "0" : "1"
        setAutomaticBitrate(to: changed)
        app.buttons["cancelStreamSettings"].tap()
        openSettings()
        XCTAssertEqual(app.switches["automaticBitrate"].value as? String, original)
        setAutomaticBitrate(to: changed)
        app.buttons["saveStreamSettings"].tap()
        app.terminate()
        launch()
        openSettings()
        XCTAssertEqual(app.switches["automaticBitrate"].value as? String, changed)
        attachScreenshot("Saved stream settings")
        // Restore the original setting so another run starts from the same state.
        setAutomaticBitrate(to: original)
        app.buttons["saveStreamSettings"].tap()
    }

    func testLargeTextAndRotationKeepPrimaryActionsReachable() async throws {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launch()
        revealAddHost()
        attachScreenshot("Large text portrait computers")
        try await rotate(to: .landscapeLeft)
        revealAddHost()
        attachScreenshot("Large text landscape computers")
        app.buttons["addComputer"].tap()
        XCTAssertTrue(app.textFields["computerAddress"].waitForExistence(timeout: 5))
        app.buttons["cancelAddComputer"].tap()
        openSettings()
        XCTAssertTrue(app.buttons["cancelStreamSettings"].isHittable)
        XCTAssertTrue(app.buttons["saveStreamSettings"].isHittable)
        attachScreenshot("Large text landscape settings")
        try await rotate(to: .portrait)
        XCTAssertTrue(app.buttons["cancelStreamSettings"].waitForExistence(timeout: 5))
        app.buttons["cancelStreamSettings"].tap()
    }

    func testSavedComputerLibraryGridWhenPaired() async throws {
        launch()
        try openSavedLibrary()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "appCard-"))
        try XCTSkipUnless(cards.count >= 2, "Grid layout requires a paired computer with at least two applications")
        let first = cards.element(boundBy: 0)
        let second = cards.element(boundBy: 1)
        XCTAssertTrue(first.isHittable)
        XCTAssertGreaterThanOrEqual(first.frame.width, 44)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2)
        XCTAssertGreaterThan(second.frame.minX, first.frame.minX)
        // Artwork is asynchronous and optional. Retain a settled screenshot for
        // visual inspection; a titled fallback is valid if the host has no cover.
        try await Task.sleep(for: .seconds(3))
        attachScreenshot("Paired library portrait cover grid")
        try await rotate(to: .landscapeLeft)
        XCTAssertTrue(first.isHittable)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2)
        attachScreenshot("Paired library landscape cover grid")

        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launch()
        try openSavedLibrary()
        XCTAssertTrue(first.isHittable)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 2)
        XCTAssertGreaterThan(second.frame.minY, first.frame.maxY)
        try await Task.sleep(for: .seconds(3))
        attachScreenshot("Paired library large text cover grid")
    }

    private func openSavedLibrary() throws {
        let computer = app.buttons["savedComputer"].firstMatch
        try XCTSkipUnless(computer.waitForExistence(timeout: 5), "No saved computer is available for live library inspection")
        computer.tap()
        let grid = app.descendants(matching: .any)["appLibraryGrid"].firstMatch
        if !grid.waitForExistence(timeout: 20) {
            attachScreenshot("Saved library unavailable for inspection")
            if app.buttons["Pair Computer"].exists || app.buttons["Try Again"].exists || app.alerts.firstMatch.exists
                || app.staticTexts["No Applications"].exists {
                throw XCTSkip("Live library inspection requires an already paired, reachable computer with applications")
            }
            XCTFail("A paired computer must present its application grid")
        }
    }

    private func launch() {
        app.launch()
        // A local network permission dialog can appear on the first clean install.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            let alert = springboard.alerts.firstMatch
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap() }
            else if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
        }
        XCTAssertTrue(app.buttons["streamSettings"].waitForExistence(timeout: 10))
    }

    private func revealAddHost() {
        let list = app.descendants(matching: .any)["computerList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let add = app.buttons["addComputer"]
        // This action now follows the saved computers in a native scrolling
        // list. At accessibility text sizes it can start below the viewport.
        for _ in 0..<8 {
            if add.exists && add.isHittable { return }
            list.swipeUp()
        }
        XCTAssertTrue(add.exists && add.isHittable, "Add Host must be reachable by scrolling the computer list")
    }

    private func openSettings() {
        let settings = app.buttons["streamSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["cancelStreamSettings"].waitForExistence(timeout: 5))
    }

    private func setAutomaticBitrate(to value: String) {
        let toggle = app.switches["automaticBitrate"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // SwiftUI exposes the whole Form row as this switch's accessibility
        // frame. The native switch is at its trailing edge; tapping the row's
        // center lands on the label and doesn't change the control.
        if toggle.value as? String != value {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                       "The automatic bitrate switch must reach the requested value")
        attachScreenshot("Automatic bitrate changed to \(value)")
    }

    private func attachScreenshot(_ name: String) {
        // The full display avoids XCUIApplication's landscape crop producing a
        // portrait-width image padded with black on the simulator.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rotate(to orientation: UIDeviceOrientation) async throws {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var previousSize: CGSize?
        while ContinuousClock.now < deadline {
            let size = app.windows.firstMatch.frame.size
            if (landscape ? size.width > size.height : size.height > size.width), size == previousSize {
                return
            }
            previousSize = size
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The application window did not settle in the requested orientation")
    }
}
