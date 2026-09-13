import XCTest
@testable import SwiftlightVideo

final class TimingStatisticsTests: XCTestCase {
    func testCompletedGPUStagesRemainAvailableAfterUnconfirmedPresentation() throws {
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000, firstPacketNanoseconds: 990_000_000)
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        var submission = FrameRenderSubmissionMetadata(surface: PresentationSubmissionTiming(selectedAtSeconds: 99.997,
            drawableAcquisitionMilliseconds: 0.25), renderStartSeconds: 99.998, commitSeconds: 100)
        submission.gpuStartSeconds = 100.001; submission.gpuEndSeconds = 100.004
        submission.completedCallbackSeconds = 100.020
        var joiner = PresentationTimingJoiner()
        let id = joiner.begin(frame, submission: submission)
        XCTAssertNil(joiner.presented(id, at: 0, callbackSeconds: 100.003, calibration: nil))
        XCTAssertEqual(joiner.unconfirmedPresentation, 1)
        XCTAssertNil(joiner.completed(id, gpuStart: 100.001, gpuEnd: 100.004, at: 100.020))
        var gpuWindow = GPUFrameTimingWindow()
        gpuWindow.record(GPUFrameTiming(frame, submission: submission, succeeded: true, calibration: calibration))
        let sample = try XCTUnwrap(gpuWindow.samples.first)
        XCTAssertEqual(try XCTUnwrap(sample.firstPacketToGPUEndMilliseconds), 14, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.decodeCallbackToGPUEndMilliseconds), 9, accuracy: 0.000001)
        let stages = [sample.firstPacketToDecodeCallbackMilliseconds, sample.decodeCallbackToRenderStartMilliseconds,
            sample.renderCPUToCommitMilliseconds, sample.commitToGPUStartMilliseconds, sample.gpuExecutionMilliseconds]
        XCTAssertEqual(stages.compactMap { $0 }.count, 5)
        XCTAssertEqual(stages.compactMap { $0 }.reduce(0, +), try XCTUnwrap(sample.firstPacketToGPUEndMilliseconds), accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.gpuEndToCompletedCallbackMilliseconds), 16, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.decodeCallbackToSelectionMilliseconds), 2, accuracy: 0.000001)
        XCTAssertEqual(sample.drawableAcquisitionMilliseconds, 0.25)
        XCTAssertEqual(sample.calibrationUncertaintyNanoseconds, 50)
        // GPU-only records never fabricate a presentation timestamp or latency.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        XCTAssertNil(json["actualPresentationNanoseconds"])
        XCTAssertNil(json["firstPacketToPresentationMilliseconds"])
        XCTAssertTrue(sample.succeeded)
    }

    func testCompletedGPUWindowCountsRedrawSubmissionsAndRemainsBounded() {
        var window = GPUFrameTimingWindow()
        let submission = FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100, commitSeconds: 100)
        for id in 1...1100 {
            window.record(GPUFrameTiming(FramePresentationMetadata(frameID: 7,
                callbackNanoseconds: UInt64(id), firstPacketNanoseconds: 1), submission: submission,
                succeeded: true, calibration: nil))
        }
        XCTAssertEqual(window.samples.count, 1024)
        XCTAssertEqual(Set(window.samples.map(\.frameID)), [7])
        XCTAssertEqual(Set(window.samples.map(\.callbackNanoseconds)), Set((77...1100).map(UInt64.init)))
    }

    func testCompletedGPUWindowDoesNotInventUnavailableClockStages() {
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000, firstPacketNanoseconds: 990_000_000)
        var submission = FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 99.998, commitSeconds: 100)
        submission.gpuStartSeconds = 100.001; submission.gpuEndSeconds = 100.004
        let uncalibrated = GPUFrameTiming(frame, submission: submission, succeeded: true, calibration: nil)
        XCTAssertNil(uncalibrated.firstPacketToGPUEndMilliseconds)
        XCTAssertNil(uncalibrated.decodeCallbackToGPUEndMilliseconds)
        XCTAssertNil(uncalibrated.decodeCallbackToRenderStartMilliseconds)
        XCTAssertNil(uncalibrated.calibrationUncertaintyNanoseconds)
        XCTAssertEqual(uncalibrated.firstPacketToDecodeCallbackMilliseconds, 5)
        XCTAssertNotNil(uncalibrated.gpuExecutionMilliseconds)
        submission.gpuStartSeconds = 0; submission.gpuEndSeconds = .nan
        let failed = GPUFrameTiming(frame, submission: submission, succeeded: false, calibration: nil)
        XCTAssertFalse(failed.succeeded)
        XCTAssertNil(failed.gpuStartSeconds)
        XCTAssertNil(failed.gpuEndSeconds)
        XCTAssertNil(failed.gpuExecutionMilliseconds)
    }

    func testGPUAndPresentationJoinInEitherOrderWithoutChangingStages() throws {
        for presentationFirst in [false, true] {
            var joiner = PresentationTimingJoiner()
            let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000, firstPacketNanoseconds: 990_000_000)
            let id = joiner.begin(frame, submission: FrameRenderSubmissionMetadata(surface: nil,
                renderStartSeconds: 99.998, commitSeconds: nil))
            XCTAssertEqual(joiner.pendingPresentation, 1)
            XCTAssertEqual(joiner.pendingPresentationHighWater, 1)
            XCTAssertEqual(joiner.completedAwaitingPresentation, 0)
            joiner.committed(id, at: 100)
            joiner.scheduled(id, at: 100.001)
            let resolved: PresentationTimingJoiner.Resolved?
            if presentationFirst {
                XCTAssertNil(joiner.presented(id, at: 100.008, callbackSeconds: 100.012, calibration: nil))
                XCTAssertEqual(joiner.pendingPresentation, 0)
                XCTAssertEqual(joiner.count, 1)
                resolved = joiner.completed(id, gpuStart: 100.002, gpuEnd: 100.003, at: 100.010,
                    kernelStart: 100.0002, kernelEnd: 100.0008)
            } else {
                XCTAssertNil(joiner.completed(id, gpuStart: 100.002, gpuEnd: 100.003, at: 100.010,
                    kernelStart: 100.0002, kernelEnd: 100.0008))
                XCTAssertEqual(joiner.pendingPresentation, 1)
                XCTAssertEqual(joiner.completedAwaitingPresentation, 1)
                resolved = joiner.presented(id, at: 100.008, callbackSeconds: 100.012, calibration: nil)
            }
            XCTAssertEqual(joiner.pendingPresentation, 0)
            XCTAssertEqual(joiner.completedAwaitingPresentation, 0)
            XCTAssertEqual(joiner.count, 0)
            XCTAssertEqual(joiner.presented, 1)
            let joined = try XCTUnwrap(resolved)
            var window = PresentationTimingWindow()
            window.record(joined.frame, presented: joined.presented, calibration: joined.calibration, submission: joined.submission)
            let sample = try XCTUnwrap(window.samples.first)
            XCTAssertEqual(try XCTUnwrap(sample.commitToGPUStartMilliseconds), 2, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.gpuExecutionMilliseconds), 1, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.gpuEndToPresentationMilliseconds), 5, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.commitToPresentationMilliseconds),
                try XCTUnwrap(sample.commitToGPUStartMilliseconds) + XCTUnwrap(sample.gpuExecutionMilliseconds) + XCTUnwrap(sample.gpuEndToPresentationMilliseconds),
                accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.commitToScheduledCallbackMilliseconds), 1, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.commitToKernelStartMilliseconds), 0.2, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.kernelSchedulingMilliseconds), 0.6, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.kernelEndToScheduledCallbackMilliseconds), 0.2, accuracy: 0.000001)
            // CPU callback lag must never be included in GPU work or display wait.
            XCTAssertEqual(try XCTUnwrap(sample.gpuEndToCompletedCallbackMilliseconds), 7, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(sample.presentationToPresentedCallbackMilliseconds), 4, accuracy: 0.000001)
        }
    }

    func testUnconfirmedPresentationReleasesJoinBeforeOrAfterGPUCompletion() {
        for presentationFirst in [false, true] {
            var joiner = PresentationTimingJoiner()
            let id = joiner.begin(FramePresentationMetadata(frameID: 1, callbackNanoseconds: 1, firstPacketNanoseconds: 1),
                submission: FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100, commitSeconds: 100))
            if !presentationFirst { XCTAssertNil(joiner.completed(id, gpuStart: 100.001, gpuEnd: 100.002, at: 100.003)) }
            XCTAssertNil(joiner.presented(id, at: 0, callbackSeconds: 100.004, calibration: nil))
            XCTAssertEqual(joiner.count, 0)
            XCTAssertEqual(joiner.pendingPresentation, 0)
            XCTAssertEqual(joiner.completedAwaitingPresentation, 0)
            XCTAssertEqual(joiner.unconfirmedPresentation, 1)
            XCTAssertEqual(joiner.presented, 0)
            if presentationFirst { XCTAssertNil(joiner.completed(id, gpuStart: 100.001, gpuEnd: 100.002, at: 100.003)) }
            // A duplicate or late callback cannot resurrect or count this entry.
            XCTAssertNil(joiner.presented(id, at: 100.003, callbackSeconds: 100.004, calibration: nil))
            XCTAssertEqual(joiner.count, 0)
            XCTAssertEqual(joiner.presented, 0)
        }
    }

    func testMissingCallbacksHaveBoundedScalarStorageAndLateCallbacksCannotAlias() {
        var joiner = PresentationTimingJoiner()
        for frameID in 0..<1100 {
            let id = joiner.begin(FramePresentationMetadata(frameID: UInt64(frameID), callbackNanoseconds: 1, firstPacketNanoseconds: 1),
                submission: FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100, commitSeconds: 100))
            XCTAssertNil(joiner.completed(id, gpuStart: 100.001, gpuEnd: 100.002, at: 100.003))
        }
        XCTAssertEqual(joiner.count, 1024)
        XCTAssertEqual(joiner.pendingPresentation, 1024)
        XCTAssertEqual(joiner.pendingPresentationHighWater, 1024)
        XCTAssertEqual(joiner.completedAwaitingPresentation, 1024)
        XCTAssertEqual(joiner.evictions, 76)
        XCTAssertNil(joiner.presented(0, at: 100.004, callbackSeconds: 100.005, calibration: nil))
        XCTAssertEqual(joiner.pendingPresentation, 1024)
        let resolved = joiner.presented(1024, at: 100.004, callbackSeconds: 100.005, calibration: nil)
        XCTAssertEqual(resolved?.frame.frameID, 1024)
        XCTAssertEqual(joiner.pendingPresentation, 1023)
        XCTAssertEqual(joiner.presented, 1)
    }

    func testMissingOrInvertedGPUClocksDoNotInventStageDurations() throws {
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 1, firstPacketNanoseconds: 1)
        var window = PresentationTimingWindow()
        var submission = FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100, commitSeconds: 100)
        submission.gpuStartSeconds = 0; submission.gpuEndSeconds = .nan
        submission.scheduledCallbackSeconds = .infinity; submission.completedCallbackSeconds = 100.008
        window.record(frame, presented: 100.007, calibration: nil, submission: submission)
        var sample = try XCTUnwrap(window.samples.first)
        XCTAssertNil(sample.gpuStartSeconds)
        XCTAssertNil(sample.gpuEndSeconds)
        XCTAssertNil(sample.commitToGPUStartMilliseconds)
        XCTAssertNil(sample.gpuExecutionMilliseconds)
        XCTAssertNil(sample.gpuEndToPresentationMilliseconds)
        XCTAssertNil(sample.gpuEndToCompletedCallbackMilliseconds)
        XCTAssertNil(sample.commitToScheduledCallbackMilliseconds)
        submission.gpuStartSeconds = 100.005; submission.gpuEndSeconds = 100.004
        window.record(frame, presented: 100.003, calibration: nil, submission: submission)
        sample = try XCTUnwrap(window.samples.first)
        XCTAssertNil(sample.gpuExecutionMilliseconds)
        XCTAssertNil(sample.gpuEndToPresentationMilliseconds)
    }

    func testRedrawJoinsKeepGPUStagesPairedWithEarliestPresentation() throws {
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 1, firstPacketNanoseconds: 1)
        var joiner = PresentationTimingJoiner()
        var window = PresentationTimingWindow()
        let early = joiner.begin(frame, submission: FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100, commitSeconds: 100))
        let late = joiner.begin(frame, submission: FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100.006, commitSeconds: 100.007))
        XCTAssertNil(joiner.completed(late, gpuStart: 100.008, gpuEnd: 100.009, at: 100.010))
        let lateResult = try XCTUnwrap(joiner.presented(late, at: 100.015, callbackSeconds: 100.016, calibration: nil))
        window.record(lateResult.frame, presented: lateResult.presented, calibration: nil, submission: lateResult.submission)
        // Presentation arrives early, but its GPU completion callback is delivered
        // after the redraw's complete pair. Keep the original frame's first scanout.
        XCTAssertNil(joiner.presented(early, at: 100.004, callbackSeconds: 100.005, calibration: nil))
        let earlyResult = try XCTUnwrap(joiner.completed(early, gpuStart: 100.001, gpuEnd: 100.002, at: 100.017))
        window.record(earlyResult.frame, presented: earlyResult.presented, calibration: nil, submission: earlyResult.submission)
        XCTAssertEqual(window.samples.count, 1)
        let sample = try XCTUnwrap(window.samples.first)
        XCTAssertEqual(sample.commitSeconds, 100)
        XCTAssertEqual(sample.gpuStartSeconds, 100.001)
        XCTAssertEqual(sample.gpuEndSeconds, 100.002)
        XCTAssertEqual(try XCTUnwrap(sample.gpuEndToPresentationMilliseconds), 2, accuracy: 0.000001)
        XCTAssertEqual(joiner.presented, 2)
        XCTAssertEqual(joiner.count, 0)
    }

    func testPerFrameStagesAccountForEntireFirstPacketToPresentationInterval() throws {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000, scheduledArrivalNanoseconds: 991_000_000,
            admissionNanoseconds: 992_000_000, vtSubmitNanoseconds: 993_000_000)
        let surface = PresentationSubmissionTiming(displayCallbackSeconds: 99.996, targetDeadlineSeconds: 99.999,
            targetPresentationSeconds: 100.007, selectedAtSeconds: 99.997, drawableAcquisitionMilliseconds: 0.75)
        var window = PresentationTimingWindow()
        window.record(frame, presented: 100.008, calibration: calibration,
            submission: FrameRenderSubmissionMetadata(surface: surface, renderStartSeconds: 99.998, commitSeconds: 100))
        let sample = try XCTUnwrap(window.samples.first)
        let stages = [sample.firstPacketToArrivalMilliseconds, sample.arrivalToAdmissionMilliseconds,
            sample.admissionToVTSubmitMilliseconds, sample.vtSubmitToDecodeCallbackMilliseconds,
            sample.decodeCallbackToRenderStartMilliseconds, sample.renderCPUToCommitMilliseconds,
            sample.commitToPresentationMilliseconds]
        XCTAssertEqual(stages.compactMap { $0 }.count, 7)
        XCTAssertEqual(stages.compactMap { $0 }.reduce(0, +), try XCTUnwrap(sample.firstPacketToPresentationMilliseconds), accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.firstPacketToDecodeCallbackMilliseconds), 5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.decodeCallbackToSelectionMilliseconds), 2, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.selectionToRenderStartMilliseconds), 1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.displayCallbackToRenderStartMilliseconds), 2, accuracy: 0.000001)
        XCTAssertEqual(sample.drawableAcquisitionMilliseconds, 0.75)
        XCTAssertEqual(try XCTUnwrap(sample.deadlineToCommitMilliseconds), 1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.targetPresentationToPresentationMilliseconds), 1, accuracy: 0.000001)
    }

    func testRedrawKeepsTimingOfEarliestPresentationAndAllowsEarlyTarget() throws {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000, firstPacketNanoseconds: 990_000_000)
        var window = PresentationTimingWindow()
        let late = FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 100.002, commitSeconds: 100.003)
        let early = FrameRenderSubmissionMetadata(surface: PresentationSubmissionTiming(targetDeadlineSeconds: 100.001,
            targetPresentationSeconds: 100.006), renderStartSeconds: 99.998, commitSeconds: 100)
        window.record(frame, presented: 100.010, calibration: calibration, submission: late)
        window.record(frame, presented: 100.004, calibration: calibration, submission: early)
        window.record(frame, presented: 100.012, calibration: calibration, submission: late)
        XCTAssertEqual(window.samples.count, 1)
        let sample = try XCTUnwrap(window.samples.first)
        XCTAssertEqual(sample.commitSeconds, 100)
        XCTAssertEqual(try XCTUnwrap(sample.renderCPUToCommitMilliseconds), 2, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.commitToPresentationMilliseconds), 4, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.deadlineToCommitMilliseconds), -1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.targetPresentationToPresentationMilliseconds), -2, accuracy: 0.000001)
    }

    func testUnavailableCalibrationDoesNotInventCrossClockStages() throws {
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000, scheduledArrivalNanoseconds: 991_000_000,
            admissionNanoseconds: 992_000_000, vtSubmitNanoseconds: 993_000_000)
        var window = PresentationTimingWindow()
        window.record(frame, presented: 100.004, calibration: nil,
            submission: FrameRenderSubmissionMetadata(surface: nil, renderStartSeconds: 99.998, commitSeconds: 100))
        let sample = try XCTUnwrap(window.samples.first)
        XCTAssertNil(sample.firstPacketToPresentationMilliseconds)
        XCTAssertNil(sample.decodeCallbackToRenderStartMilliseconds)
        XCTAssertNil(sample.decodeCallbackToSelectionMilliseconds)
        XCTAssertEqual(sample.firstPacketToDecodeCallbackMilliseconds, 5)
        XCTAssertEqual(try XCTUnwrap(sample.renderCPUToCommitMilliseconds), 2, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.commitToPresentationMilliseconds), 4, accuracy: 0.000001)
    }

    func testMissingCommitAndInvalidSubmissionValuesRemainUnavailable() throws {
        let frame = FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 996_000_000, scheduledArrivalNanoseconds: 0,
            admissionNanoseconds: 992_000_000, vtSubmitNanoseconds: 991_000_000)
        var window = PresentationTimingWindow()
        window.record(frame, presented: 100.004, calibration: nil,
            submission: FrameRenderSubmissionMetadata(surface: PresentationSubmissionTiming(displayCallbackSeconds: .nan,
                targetDeadlineSeconds: .infinity, targetPresentationSeconds: -1, selectedAtSeconds: 0,
                drawableAcquisitionMilliseconds: -1), renderStartSeconds: .nan, commitSeconds: nil))
        let sample = try XCTUnwrap(window.samples.first)
        XCTAssertNil(sample.firstPacketToDecodeCallbackMilliseconds)
        XCTAssertNil(sample.firstPacketToArrivalMilliseconds)
        XCTAssertNil(sample.arrivalToAdmissionMilliseconds)
        XCTAssertNil(sample.admissionToVTSubmitMilliseconds)
        XCTAssertNil(sample.renderCPUToCommitMilliseconds)
        XCTAssertNil(sample.commitToPresentationMilliseconds)
        XCTAssertNil(sample.renderStartSeconds)
        XCTAssertNil(sample.displayCallbackSeconds)
        XCTAssertNil(sample.targetPresentationSeconds)
        XCTAssertNil(sample.targetDeadlineSeconds)
        XCTAssertNil(sample.drawableAcquisitionMilliseconds)
    }

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
