import Testing
@testable import SwiftlightApp
@testable import SwiftlightCore
@testable import SwiftlightTransport
@testable import SwiftlightVideo

@Suite @MainActor struct StreamStatisticsSamplerTests {
    @Test func requestedAndSetupValuesNeverStandInForObservedVideo() {
        var sampler = StreamStatisticsSampler()
        let request = StreamRequest(size: PixelSize(3840, 2160), fps: 120, bitrateKbps: 40_000)
        let selection = CodecSelection(codec: .hevc, hdr: true, explanation: "Fixture")
        let negotiated = VideoStreamDescription(videoFormat: 0x200, width: 3840, height: 2160, fps: 120)
        let snapshot = sampler.sample(request: request, selection: selection, negotiated: negotiated,
            decodedFormat: nil, diagnostics: nil, decoder: nil, renderer: nil, uptime: 10, presentationTime: 100)
        #expect(snapshot.requestedVideo == "3840 × 2160 · 120 Hz")
        #expect(snapshot.requestedFormat.contains("HDR10 · 10-bit · Rec.2020"))
        #expect(snapshot.negotiatedVideo == "HEVC · 10-bit")
        #expect(snapshot.receivedSize == nil && snapshot.receivedFramesPerSecond == nil)
        #expect(snapshot.networkRoundTrip == nil && snapshot.decodeTime == nil)
        #expect(snapshot.currentFirstPacketToPresentationMilliseconds == nil)
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 10)
            .first { $0.id == "client" }?.value == "Unavailable")
    }

    @Test func presentationFreshnessUsesItsOwnClockAndKeepsMissingLatestMeasurementMissing() throws {
        let calibration = PresentationClockCalibration(sampledAtDecoderNanoseconds: 1_000_000_000,
            coreAnimationSeconds: 100, uncertaintyNanoseconds: 50)
        var presented = PresentationTimingWindow()
        presented.record(FramePresentationMetadata(frameID: 1, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 990_000_000, hostProcessingMilliseconds: 2), presented: 100, calibration: calibration)
        var renderer = RenderStatistics()
        renderer.presentationTimings = presented.samples
        var sampler = StreamStatisticsSampler()
        let fresh = sampler.sample(request: nil, selection: nil, negotiated: nil, decodedFormat: nil,
            diagnostics: nil, decoder: nil, renderer: renderer, uptime: 10_000, presentationTime: 100.5)
        let current = try #require(fresh.currentFirstPacketToPresentationMilliseconds)
        let paired = try #require(fresh.hostProcessingAndClientPresentation?.averageMilliseconds)
        #expect(abs(current - 10) < 0.000001)
        #expect(abs(paired - 12) < 0.000001)
        let stale = sampler.sample(request: nil, selection: nil, negotiated: nil, decodedFormat: nil,
            diagnostics: nil, decoder: nil, renderer: renderer, uptime: 10_000.5, presentationTime: 106)
        #expect(stale.currentFirstPacketToPresentationMilliseconds == nil)
        #expect(stale.firstPacketToPresentation == fresh.firstPacketToPresentation)

        presented.record(FramePresentationMetadata(frameID: 2, callbackNanoseconds: 995_000_000,
            firstPacketNanoseconds: 0), presented: 101, calibration: calibration)
        renderer.presentationTimings = presented.samples
        let missingLatest = sampler.sample(request: nil, selection: nil, negotiated: nil, decodedFormat: nil,
            diagnostics: nil, decoder: nil, renderer: renderer, uptime: 10_001, presentationTime: 101.1)
        #expect(missingLatest.currentFirstPacketToPresentationMilliseconds == nil)
        #expect(missingLatest.firstPacketToPresentation == fresh.firstPacketToPresentation)
    }

    @Test func simpleHoldDoesNotAlterRawOrDetailedSnapshotsAndResetDropsTheHold() {
        var sampler = StreamStatisticsSampler()
        var snapshot = StreamStatisticsSnapshot()
        snapshot.currentFirstPacketToPresentationMilliseconds = 12
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 10)
            .first { $0.id == "client" }?.value == "12.00 ms")
        snapshot.currentFirstPacketToPresentationMilliseconds = 24
        snapshot.firstPacketToPresentation = StreamTimingSummary(samples: [20, 24])
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 14.9)
            .first { $0.id == "client" }?.value == "12.00 ms")
        #expect(snapshot.currentFirstPacketToPresentationMilliseconds == 24)
        #expect(sampler.rows(for: snapshot, detail: .detailed, uptime: 14.9)
            .first { $0.id == "client" }?.value == "20.00 / 24.00 / 22.00 ms")
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 15)
            .first { $0.id == "client" }?.value == "24.00 ms")
        sampler.resetPresentationSample()
        snapshot.currentFirstPacketToPresentationMilliseconds = nil
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 15.1)
            .first { $0.id == "client" }?.value == "Unavailable")
        // A clock reset must not keep a sample from the previous epoch.
        snapshot.currentFirstPacketToPresentationMilliseconds = 8
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 1)
            .first { $0.id == "client" }?.value == "8.00 ms")
    }
}
