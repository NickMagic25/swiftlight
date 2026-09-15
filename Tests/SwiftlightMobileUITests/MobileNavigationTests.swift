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
        revealSetting(bitrate)
        let original = try XCTUnwrap(bitrate.value as? String)
        let changed = original == "1" ? "0" : "1"
        setAutomaticBitrate(to: changed)
        app.buttons["cancelStreamSettings"].tap()
        openSettings()
        revealSetting(bitrate)
        XCTAssertEqual(app.switches["automaticBitrate"].value as? String, original)
        setAutomaticBitrate(to: changed)
        app.buttons["saveStreamSettings"].tap()
        app.terminate()
        launch()
        openSettings()
        revealSetting(bitrate)
        XCTAssertEqual(app.switches["automaticBitrate"].value as? String, changed)
        attachScreenshot("Saved stream settings")
        // Restore the original setting so another run starts from the same state.
        setAutomaticBitrate(to: original)
        app.buttons["saveStreamSettings"].tap()
    }

    func testCustomVideoSettingsCancelSaveAndRejectInvalidValues() throws {
        launch()
        openSettings()
        let original = try inspectNumericSettingsDraft()
        app.buttons["cancelStreamSettings"].tap()
        addTeardownBlock { @MainActor [self] in
            app.terminate()
            launch()
            openSettings()
            try applyNumericSettings(original)
            app.buttons["saveStreamSettings"].tap()
            XCTAssertTrue(app.buttons["cancelStreamSettings"].waitForNonExistence(timeout: 5))
            openSettings()
            XCTAssertEqual(try inspectNumericSettingsDraft(), original, "Restore the original saved numeric settings")
            app.buttons["cancelStreamSettings"].tap()
        }
        let changed = NumericSettingsState(
            resolution: "Custom", width: original.width == "1600" ? "1680" : "1600",
            height: original.height == "900" ? "1050" : "900",
            fps: original.fps == "75" ? "77" : "75",
            automaticBitrate: "0", bitrate: original.bitrate == "37.5" ? "42.5" : "37.5")

        openSettings()
        try applyNumericSettings(changed)
        app.buttons["cancelStreamSettings"].tap()
        openSettings()
        XCTAssertEqual(try inspectNumericSettingsDraft(), original, "Cancel must discard all numeric edits")

        try applyNumericSettings(changed)
        // The bitrate field is still editing: Save must capture its final text
        // without relying on Return or an explicit keyboard-dismiss action.
        app.buttons["saveStreamSettings"].tap()
        XCTAssertTrue(app.buttons["cancelStreamSettings"].waitForNonExistence(timeout: 5))
        app.terminate()
        launch()
        openSettings()
        XCTAssertEqual(try inspectNumericSettingsDraft(), changed)
        revealSetting(app.textFields["customWidth"])
        attachScreenshot("Saved custom resolution and frame rate")
        revealSetting(app.textFields["customBitrate"])
        attachScreenshot("Saved fractional bitrate")

        let invalidCases = [
            ("customWidth", "63", "Custom dimensions must be between 64 and 16384 pixels.", changed.width),
            ("customFrameRate", "241", "Frame rate must be automatic or between 1 and 240 FPS.", changed.fps),
            ("customBitrate", "501", "Bitrate must be between 1 and 500 Mbps.", changed.bitrate)
        ]
        for (identifier, invalid, message, valid) in invalidCases {
            try replaceSettingNumber(identifier, with: invalid, submit: false)
            app.buttons["saveStreamSettings"].tap()
            let alert = app.alerts["Settings could not be saved"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts[message].exists)
            attachScreenshot("Rejected invalid \(identifier)")
            alert.buttons["OK"].tap()
            try replaceSettingNumber(identifier, with: valid)
        }
        app.buttons["cancelStreamSettings"].tap()
        app.terminate()
        launch()
        openSettings()
        XCTAssertEqual(try inspectNumericSettingsDraft(), changed,
                       "Rejected edits must not overwrite the last saved numeric settings")
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

    func testPerformanceAndStatisticsSettingsPersist() throws {
        launch()
        openSettings()
        let pacing = app.buttons["videoPacing"]
        revealSetting(pacing)
        let originalPacing = try XCTUnwrap(pacing.value as? String)
        let changedPacing = originalPacing == "Display paced" ? "On decoded frame" : "Display paced"
        chooseSetting(pacing, option: changedPacing)
        let buffers = app.buttons["maximumDrawableCount"]
        revealSetting(buffers)
        let originalBuffers = try XCTUnwrap(buffers.value as? String)
        let changedBuffers = originalBuffers == "2" ? "3 (default)" : "2"
        chooseSetting(buffers, option: changedBuffers)
        let statistics = app.switches["showStatisticsByDefault"]
        revealSetting(statistics)
        let originalStatistics = try XCTUnwrap(statistics.value as? String)
        let changedStatistics = originalStatistics == "1" ? "0" : "1"
        setSwitch(statistics, to: changedStatistics)
        attachScreenshot("Performance and statistics settings")
        app.buttons["cancelStreamSettings"].tap()
        openSettings()
        revealSetting(pacing)
        XCTAssertEqual(pacing.value as? String, originalPacing)
        revealSetting(buffers)
        XCTAssertEqual(buffers.value as? String, originalBuffers)
        revealSetting(statistics)
        XCTAssertEqual(statistics.value as? String, originalStatistics)
        chooseSetting(pacing, option: changedPacing)
        chooseSetting(buffers, option: changedBuffers)
        revealSetting(statistics)
        setSwitch(statistics, to: changedStatistics)
        app.buttons["saveStreamSettings"].tap()
        app.terminate()
        launch()
        openSettings()
        revealSetting(pacing)
        XCTAssertEqual(pacing.value as? String, changedPacing)
        revealSetting(buffers)
        XCTAssertEqual(buffers.value as? String, changedBuffers)
        revealSetting(statistics)
        XCTAssertEqual(statistics.value as? String, changedStatistics)
        chooseSetting(pacing, option: originalPacing)
        chooseSetting(buffers, option: originalBuffers)
        revealSetting(statistics)
        setSwitch(statistics, to: originalStatistics)
        app.buttons["saveStreamSettings"].tap()
    }

    func testHDRAndAudioSettingsCancelAndPersist() throws {
        launch()
        openSettings()
        let hdr = app.buttons["hdrPreference"]
        let channels = app.buttons["audioChannels"]
        let output = app.buttons["audioOutput"]
        let hostAudio = app.switches["playAudioOnComputer"]
        func hdrValue() throws -> String {
            revealSetting(hdr)
            // Native menu pickers may include their selection in the label.
            let value = hdr.value as? String
            let label = hdr.label
            return try XCTUnwrap(["Automatic", "On", "Off"].first {
                value == $0 || label == "HDR, \($0)"
            }, "HDR must expose its selected value")
        }
        func chooseHDR(_ option: String) throws {
            revealSetting(hdr)
            hdr.tap()
            let item = app.buttons[option]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.tap()
            XCTAssertEqual(try hdrValue(), option)
        }
        let originalHDR = try hdrValue()
        revealSetting(channels)
        let originalChannels = try XCTUnwrap(channels.value as? String)
        revealSetting(output)
        let originalOutput = try XCTUnwrap(output.value as? String)
        revealSetting(hostAudio)
        let originalHostAudio = try XCTUnwrap(hostAudio.value as? String)
        addTeardownBlock { @MainActor [self] in
            // XCTest teardown still runs when continueAfterFailure is false;
            // a Swift defer can be bypassed by its assertion interruption.
            // A fresh sheet also discards any unsaved draft or open menu.
            app.terminate()
            launch()
            openSettings()
            let hdr = app.buttons["hdrPreference"]
            revealSetting(hdr)
            hdr.tap()
            XCTAssertTrue(app.buttons[originalHDR].waitForExistence(timeout: 5))
            app.buttons[originalHDR].tap()
            chooseSetting(app.buttons["audioChannels"], option: originalChannels)
            chooseSetting(app.buttons["audioOutput"], option: originalOutput)
            let hostAudio = app.switches["playAudioOnComputer"]
            revealSetting(hostAudio)
            setSwitch(hostAudio, to: originalHostAudio)
            app.buttons["saveStreamSettings"].tap()
        }
        let changedHDR = originalHDR == "On" ? "Off" : "On"
        let changedChannels = originalChannels == "5.1 Surround" ? "7.1 Surround" : "5.1 Surround"
        let changedOutput = originalOutput == "System Spatial Audio" ? "Direct" : "System Spatial Audio"
        let changedHostAudio = originalHostAudio == "1" ? "0" : "1"
        func changeDraft() throws {
            try chooseHDR(changedHDR)
            chooseSetting(channels, option: changedChannels)
            chooseSetting(output, option: changedOutput)
            revealSetting(hostAudio)
            setSwitch(hostAudio, to: changedHostAudio)
        }
        try changeDraft()
        attachScreenshot("Staged HDR and surround audio settings")
        app.buttons["cancelStreamSettings"].tap()
        openSettings()
        XCTAssertEqual(try hdrValue(), originalHDR)
        revealSetting(channels)
        XCTAssertEqual(channels.value as? String, originalChannels)
        revealSetting(output)
        XCTAssertEqual(output.value as? String, originalOutput)
        revealSetting(hostAudio)
        XCTAssertEqual(hostAudio.value as? String, originalHostAudio)

        try changeDraft()
        app.buttons["saveStreamSettings"].tap()
        app.terminate()
        launch()
        openSettings()
        XCTAssertEqual(try hdrValue(), changedHDR)
        attachScreenshot("Saved HDR preference after relaunch")
        revealSetting(channels)
        XCTAssertEqual(channels.value as? String, changedChannels)
        revealSetting(output)
        XCTAssertEqual(output.value as? String, changedOutput)
        revealSetting(hostAudio)
        XCTAssertEqual(hostAudio.value as? String, changedHostAudio)

        chooseSetting(output, option: "System Spatial Audio")
        chooseSetting(channels, option: "Stereo")
        revealSetting(output)
        XCTAssertEqual(output.value as? String, "Direct", "Stereo must select the effective Direct output")
        output.tap()
        let spatial = app.buttons["System Spatial Audio"]
        XCTAssertFalse(spatial.exists, "Stereo must not offer a spatial-output choice")
        app.buttons["Direct"].tap()
        attachScreenshot("Stereo uses Direct audio output")
        app.buttons["saveStreamSettings"].tap()
        app.terminate()
        launch()
        openSettings()
        revealSetting(channels)
        XCTAssertEqual(channels.value as? String, "Stereo")
        revealSetting(output)
        XCTAssertEqual(output.value as? String, "Direct")
    }

    func testRunningApplicationActionsRequireConfirmation() throws {
        try requireLiveTesting()
        launch()
        try openSavedLibrary()
        let running = try revealRunningApplication()
        let runningID = running.identifier
        running.press(forDuration: 1)
        let quitMenu = app.buttons["Quit Remote Application…"]
        XCTAssertTrue(quitMenu.waitForExistence(timeout: 5))
        quitMenu.tap()
        let quit = app.buttons["Quit Remote Application"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        attachScreenshot("Remote quit requires confirmation")
        cancelConfirmation(quit)
        // Never confirm a host quit in UI tests: the current app can contain
        // unsaved user work. Exercise both confirmation routes and cancel.
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<20 {
            let other = app.buttons.matching(NSPredicate(format:
                "identifier BEGINSWITH %@ AND identifier != %@", "appCard-", runningID)).firstMatch
            if other.exists && other.isHittable {
                other.tap()
                let switchApp = app.buttons["Quit and Start"]
                XCTAssertTrue(switchApp.waitForExistence(timeout: 15))
                attachScreenshot("Switching applications requires confirmation")
                cancelConfirmation(switchApp)
                XCTAssertEqual(try revealRunningApplication().identifier, runningID)
                return
            }
            scroll.swipeDown()
        }
        XCTFail("A different application must be reachable in the library")
    }

    func testLiveStreamStatisticsAndEdgeDisconnect() async throws {
        let (surface, runningID) = try await resumeRunningStream()
        let statistics = app.descendants(matching: .any)["streamStatistics"].firstMatch
        let initiallyVisible = surface.value as? String == "Statistics shown"
        if initiallyVisible {
            surface.tap(withNumberOfTaps: 1, numberOfTouches: 3)
            XCTAssertTrue(statistics.waitForNonExistence(timeout: 5))
        }
        attachScreenshot("Live stream with system chrome and statistics hidden")
        surface.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(statistics.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "statistic-")).firstMatch.exists)
        try await Task.sleep(for: .seconds(3))
        attachScreenshot("Live stream statistics shown by three finger tap")
        surface.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(statistics.waitForNonExistence(timeout: 5))
        XCTAssertTrue(surface.exists)
        attachScreenshot("Live stream statistics hidden again")
        try disconnectRunningStreamFromEdge(surface, runningID: runningID)
    }

    func testLiveStreamKeyboardControls() async throws {
        let (surface, runningID) = try await resumeRunningStream()
        let statistics = app.descendants(matching: .any)["streamStatistics"].firstMatch
        surface.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: .command)
        let inStreamToggle = app.switches["inStreamStatistics"]
        guard inStreamToggle.waitForExistence(timeout: 5) else {
            attachScreenshot("Stream Controls shortcut unavailable")
            XCTFail("Command–Escape must open Stream Controls")
            return
        }
        setSwitch(inStreamToggle, to: "1")
        attachScreenshot("Stream Controls keyboard alternative")
        app.buttons["Close"].tap()
        XCTAssertTrue(inStreamToggle.waitForNonExistence(timeout: 5))
        surface.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: .command)
        XCTAssertTrue(inStreamToggle.waitForExistence(timeout: 5),
                      "The stream must regain keyboard shortcuts after closing its controls")
        attachScreenshot("Stream Controls reopened from the keyboard")
        app.buttons["Close"].tap()
        XCTAssertTrue(inStreamToggle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(statistics.waitForExistence(timeout: 5))
        surface.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertTrue(statistics.waitForNonExistence(timeout: 5))
        try disconnectRunningStreamFromEdge(surface, runningID: runningID)
    }

    private func resumeRunningStream() async throws -> (XCUIElement, String) {
        try requireLiveTesting()
        launch()
        try openSavedLibrary()
        let running = try revealRunningApplication()
        let runningID = running.identifier
        try await rotate(to: .landscapeLeft)
        running.tap() // Resume only; never launch a different application.
        let surface = app.descendants(matching: .any)["streamSurface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Cancel"].waitForNonExistence(timeout: 30), "A decoded frame must arrive")
        return (surface, runningID)
    }

    private func disconnectRunningStreamFromEdge(_ surface: XCUIElement, runningID: String) throws {
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
        let middle = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: middle)
        XCTAssertTrue(surface.waitForNonExistence(timeout: 20))
        XCTAssertEqual(try revealRunningApplication().identifier, runningID,
                       "Local disconnect must leave the remote application running")
        attachScreenshot("Edge disconnect returns to the running application")
    }

    func testLiveLatencyCapture() async throws {
        try requireLiveTesting()
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SWIFTLIGHT_LATENCY_CAPTURE"] == "1",
                          "Opt in with TEST_RUNNER_SWIFTLIGHT_LATENCY_CAPTURE=1")
        #if targetEnvironment(simulator)
        throw XCTSkip("Confirmed presentation latency capture requires a physical device")
        #else
        let trial = try XCTUnwrap(environment["SWIFTLIGHT_LATENCY_TRIAL"], "A latency trial label is required")
        guard ["baseline-off", "baseline-on", "candidate-off", "candidate-on"].contains(trial) else {
            XCTFail("Use a supported baseline/candidate and off/on trial label")
            return
        }
        app.launchEnvironment["SWIFTLIGHT_LATENCY_CAPTURE"] = "1"
        app.launchEnvironment["SWIFTLIGHT_LATENCY_TRIAL"] = trial
        for key in ["SWIFTLIGHT_LATENCY_SOURCE_REVISION", "SWIFTLIGHT_LATENCY_SOURCE_TREE_SHA256"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        launch()
        try openSavedLibrary()
        let running = try revealRunningApplication()
        let runningID = running.identifier
        try await rotate(to: .landscapeLeft)
        running.tap() // Resume only; keep the saved request, pacing and buffer count.
        let surface = app.descendants(matching: .any)["streamSurface"].firstMatch
        guard surface.waitForExistence(timeout: 30), app.buttons["Cancel"].waitForNonExistence(timeout: 30) else {
            XCTFail("The existing remote application must resume and deliver video")
            return
        }
        let statistics = app.descendants(matching: .any)["streamStatistics"].firstMatch
        let wantsStatistics = trial.hasSuffix("-on")
        // Let an enabled saved default finish installing before deciding whether
        // to toggle it. This changes session visibility, never the saved default.
        let initiallyVisible = statistics.waitForExistence(timeout: 3)
        if initiallyVisible != wantsStatistics { surface.tap(withNumberOfTaps: 1, numberOfTouches: 3) }
        let visibilityReady = wantsStatistics ? statistics.waitForExistence(timeout: 10)
                                             : statistics.waitForNonExistence(timeout: 5)
        guard visibilityReady else { XCTFail("Statistics must match the requested capture trial"); return }
        XCTAssertEqual(surface.value as? String, wantsStatistics ? "Statistics shown" : "Statistics hidden")

        // The app captures at 20/30/40 seconds after its first confirmed frame.
        // Do not query the UI, take screenshots, rotate or inject input here.
        try await Task.sleep(for: .seconds(45))

        guard surface.exists, !app.alerts.firstMatch.exists else {
            XCTFail("The stream must remain active throughout the capture window")
            return
        }
        XCTAssertEqual(surface.value as? String, wantsStatistics ? "Statistics shown" : "Statistics hidden")
        attachScreenshot("Latency capture completed — \(trial)")
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
        let middle = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: middle)
        XCTAssertTrue(surface.waitForNonExistence(timeout: 20))
        // Keep the app alive while local teardown and queued capture writes finish.
        // The caller separately verifies and retrieves the actual JSON files.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(try revealRunningApplication().identifier, runningID,
                       "Latency testing must leave the remote application running")
        #endif
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

    private func requireLiveTesting() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTLIGHT_LIVE_UI_TESTS"] == "1",
                          "Opt in with TEST_RUNNER_SWIFTLIGHT_LIVE_UI_TESTS=1; requires an already running, paired host app")
    }

    private func revealRunningApplication() throws -> XCUIElement {
        let running = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@", "appCard-", "Running")).firstMatch
        for _ in 0..<25 {
            if running.exists && running.isHittable { return running }
            app.scrollViews.firstMatch.swipeUp()
        }
        throw XCTSkip("This test only resumes an already running remote application")
    }

    private func cancelConfirmation(_ action: XCUIElement) {
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap() }
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
    }

    private func revealSetting(_ element: XCUIElement) {
        let form = app.descendants(matching: .any)["streamSettingsForm"].firstMatch
        // Form virtualizes offscreen rows on compact devices. Search both
        // directions rather than requiring an offscreen accessibility frame.
        for upward in [true, false] {
            for _ in 0..<6 {
                if element.exists && element.isHittable {
                    // A partly clipped row can still report hittable, while its
                    // default tap lands below the screen or under the toolbar.
                    let visible = form.frame.intersection(app.windows.firstMatch.frame)
                    let top = max(visible.minY, app.navigationBars["Stream Settings"].frame.maxY) + 8
                    let bottom = visible.maxY - 44
                    if element.frame.minY < top || element.frame.maxY > bottom {
                        // Keep the scroll correction shorter than the visible
                        // sheet, and stop momentum before checking it again.
                        let upward = element.frame.maxY > bottom
                        let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.35))
                        let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.35 : 0.65))
                        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
                        continue
                    }
                    return
                }
                if upward { form.swipeUp() } else { form.swipeDown() }
            }
        }
        XCTFail("Could not fully reveal setting \(element.identifier)")
    }

    private func chooseSetting(_ picker: XCUIElement, option: String, title: String? = nil) {
        revealSetting(picker)
        picker.tap()
        let item = app.buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        if let title { XCTAssertEqual(selectedSetting(picker, title: title), option) }
        else { XCTAssertEqual(picker.value as? String, option) }
    }

    private func selectedSetting(_ picker: XCUIElement, title: String) -> String {
        revealSetting(picker)
        if let value = picker.value as? String, !value.isEmpty { return value }
        let prefix = title + ", "
        XCTAssertTrue(picker.label.hasPrefix(prefix), "A menu picker must expose its selection")
        return String(picker.label.dropFirst(prefix.count))
    }

    private struct NumericSettingsState: Equatable, Sendable {
        let resolution: String
        let width: String
        let height: String
        let fps: String
        let automaticBitrate: String
        let bitrate: String
    }

    /// Temporarily reveals latent values in this draft. The caller must cancel
    /// or explicitly apply its intended state before saving.
    private func inspectNumericSettingsDraft() throws -> NumericSettingsState {
        let resolution = selectedSetting(app.buttons["resolution"], title: "Resolution")
        chooseSetting(app.buttons["resolution"], option: "Custom", title: "Resolution")
        func number(_ identifier: String) throws -> String {
            let field = app.textFields[identifier]
            revealSetting(field)
            return try XCTUnwrap(field.value as? String)
        }
        let width = try number("customWidth"), height = try number("customHeight")
        let fps = try number("customFrameRate")
        let automatic = app.switches["automaticBitrate"]
        revealSetting(automatic)
        let originalAutomatic = try XCTUnwrap(automatic.value as? String)
        setSwitch(automatic, to: "0")
        return try NumericSettingsState(resolution: resolution, width: width, height: height,
                                        fps: fps, automaticBitrate: originalAutomatic,
                                        bitrate: number("customBitrate"))
    }

    private func applyNumericSettings(_ settings: NumericSettingsState) throws {
        chooseSetting(app.buttons["resolution"], option: "Custom", title: "Resolution")
        try replaceSettingNumber("customWidth", with: settings.width)
        try replaceSettingNumber("customHeight", with: settings.height)
        try replaceSettingNumber("customFrameRate", with: settings.fps)
        let automatic = app.switches["automaticBitrate"]
        revealSetting(automatic)
        setSwitch(automatic, to: "0")
        let hasTrailingChoices = settings.resolution != "Custom" || settings.automaticBitrate != "0"
        try replaceSettingNumber("customBitrate", with: settings.bitrate, submit: hasTrailingChoices)
        if settings.resolution != "Custom" {
            chooseSetting(app.buttons["resolution"], option: settings.resolution, title: "Resolution")
        }
        if settings.automaticBitrate != "0" {
            revealSetting(automatic)
            setSwitch(automatic, to: settings.automaticBitrate)
        }
    }

    private enum NumericEditingError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let message): message } }
    }

    private func replaceSettingNumber(_ identifier: String, with text: String, submit: Bool = true) throws {
        let field = app.textFields[identifier]
        revealSetting(field)
        // Focus first: the initial tap can enter editing without participating
        // in text selection. Then use native selection rather than Command-A.
        let number = field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        number.tap()
        number.doubleTap()
        let selectAll = app.menuItems["Select All"]
        if selectAll.exists { selectAll.tap() }
        else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        let clearedValue = field.value as? String
        guard clearedValue == "" || clearedValue == field.placeholderValue else {
            attachScreenshot("Numeric field selection did not clear \(identifier)")
            throw NumericEditingError.failed("Could not clear \(identifier) before replacement")
        }
        field.typeText(text)
        guard field.value as? String == text else {
            attachScreenshot("Numeric field did not match \(identifier)")
            throw NumericEditingError.failed("Could not replace \(identifier) with the intended number")
        }
        if submit { field.typeText("\n") }
    }

    private func setSwitch(_ toggle: XCUIElement, to value: String) {
        if toggle.value as? String != value {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
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
        revealSetting(toggle)
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
