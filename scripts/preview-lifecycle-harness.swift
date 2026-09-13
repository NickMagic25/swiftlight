// Appended to the exact production source by validate-preview-lifecycle.py so its
// private engine/model can be exercised without exposing app internals or a window.
@main private struct PreviewLifecycleHarness {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PreviewError.invalid(message) }
    }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw PreviewError.invalid("Lifecycle wait timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func stopped(_ engine: ReplayPreviewEngine) async {
        engine.requestStop()
        await withCheckedContinuation { continuation in
            engine.whenStopped { continuation.resume() }
        }
    }
    @MainActor static func main() async {
        do {
            guard VideoCodec.hevc.hardwareCandidate else {
                print("{\"status\":\"BLOCKED\",\"reason\":\"Hardware HEVC unavailable\"}")
                exit(77)
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let engine = ReplayPreviewEngine(url: url, repeating: false)
            defer { engine.requestStop() }
            try await until { ["Completed", "Failed"].contains(engine.report().state.phase) }
            let completed = engine.report()
            try require(completed.state.phase == "Completed", completed.state.failure ?? "Single-frame replay did not complete")
            try require(completed.decoder?.accepted == 1 && completed.decoder?.completed == 1 && completed.decoder?.output == 1,
                        "Single-frame terminal accounting mismatch")
            try require(completed.terminalAccountingStatus == "PASS" && completed.presentationStatus == "UNCONFIRMED",
                        "Drained accounting must not claim visible presentation")
            try require(completed.processWideFrameOwnership.live == 1, "Completed must retain its final mailbox frame")
            try await Task.sleep(for: .milliseconds(100))
            var finalFrame = engine.takeLatestFrame()
            try require(finalFrame?.width == 128 && finalFrame?.height == 72, "Final frame was lost before display could take it")
            engine.noteLateCallback()
            let data = try JSONEncoder().encode(engine.report())
            let reportText = String(decoding: data, as: UTF8.self)
            try require(reportText.contains("lateDisplayLinkCallbacks") && !reportText.contains("lateSubmissionDeadlines"),
                        "Export must name callback-entry lateness accurately")
            await stopped(engine)
            try require(engine.report().state.phase == "Stopped", "Stop callback preceded decoder teardown")
            try require(finalFrame?.width == 128, "Retained final output became invalid during teardown")
            finalFrame = nil
            try require(DecodedFrame.ownershipStatistics.live == 0, "Final frame did not release after teardown")

            let model = ReplayPreviewModel()
            model.selectedURL = url; model.repeating = false; model.start()
            let first = model.engine!
            try await until { first.report().state.phase == "Completed" || first.report().state.phase == "Failed" }
            try require(first.report().state.phase == "Completed", first.report().state.failure ?? "Model replay failed")
            model.latest = first.report()
            try require(model.canStop && !model.isPlaying, "Completed must offer both Stop and Play")
            model.start()
            try require(model.engine === first, "New Play replaced its owner before the asynchronous stop barrier")
            try await until { model.engine !== first }
            try require(first.report().state.phase == "Stopped", "Replacement started before old decoder destruction")
            let second = model.engine!
            try await until { second.report().state.phase == "Completed" || second.report().state.phase == "Failed" }
            try require(second.report().state.phase == "Completed", second.report().state.failure ?? "Replacement replay failed")
            model.start(); model.stop()
            await stopped(second)
            try await Task.sleep(for: .milliseconds(100))
            try require(model.engine === second, "Stop did not cancel a queued replacement")
            try require(DecodedFrame.ownershipStatistics.live == 0, "Stopped model retained decoded output")

            let evidence: [String: Any] = ["status": "PASS", "mode": "preview-lifecycle-no-window",
                "sourceSHA256": ProcessInfo.processInfo.environment["SWIFTLIGHT_PREVIEW_SOURCE_SHA256"] ?? "",
                "checks": ["finite final mailbox retention", "terminal/presentation status separation",
                           "honest callback metric export", "retained frame after teardown",
                           "Completed Stop affordance", "restart destruction barrier", "queued restart cancellation"],
                "hardwareValidated": completed.decoder?.hardwareValidated == true,
                "liveFramesAfterStop": DecodedFrame.ownershipStatistics.live,
                "visiblePresentationMeasured": false]
            let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
        } catch {
            let encoded = try! JSONSerialization.data(withJSONObject: ["status": "FAIL", "reason": String(describing: error)], options: [.sortedKeys])
            print(String(decoding: encoded, as: UTF8.self)); exit(1)
        }
    }
}
