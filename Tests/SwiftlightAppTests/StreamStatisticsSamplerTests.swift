import Foundation
import Testing
@testable import SwiftlightApp
@testable import SwiftlightCore
@testable import SwiftlightTransport
@testable import SwiftlightVideo

@Suite @MainActor struct StreamStatisticsSamplerTests {
    @Test func pyrowaveDecodeSummaryAndRowsUseItsMeasuredPopulation() throws {
        var sampler = StreamStatisticsSampler()
        var decoder = DecoderStatistics()
        decoder.pyrowaveAdmissionToCallbackMilliseconds = [3, 1, 2]
        // This separate population must not be mixed with native PyroWave time.
        decoder.singleSampleVTSubmitToCallbackMilliseconds = [99]
        let negotiated = VideoStreamDescription(videoFormat: 0x10000, width: 1920, height: 1080, fps: 60)
        let snapshot = sampler.sample(request: nil, selection: nil, negotiated: negotiated,
            decodedFormat: nil, diagnostics: nil, decoder: decoder, renderer: nil, uptime: 10)
        let summary = try #require(snapshot.decodeTime)
        #expect(summary.sampleCount == 3)
        #expect(summary.minimumMilliseconds == 1 && summary.maximumMilliseconds == 3)
        #expect(summary.averageMilliseconds == 2)
        for detail in [StreamStatisticsDetail.simple, .detailed] {
            let row = try #require(sampler.rows(for: snapshot, detail: detail, uptime: 10).first { $0.id == "decode" })
            #expect(row.label == "Decode time")
            #expect(row.value == (detail == .simple ? "2.00 ms" : "1.00 / 3.00 / 2.00 ms"))
        }
    }

    @Test func absentOrInvalidPyrowaveDecodeSamplesRemainUnavailable() {
        var sampler = StreamStatisticsSampler()
        for samples in [[Double](), [.nan, .infinity, -1]] {
            var decoder = DecoderStatistics()
            decoder.accepted = 10; decoder.output = 8
            decoder.pyrowaveAdmissionToCallbackMilliseconds = samples
            let negotiated = VideoStreamDescription(videoFormat: 0x10000, width: 1920, height: 1080, fps: 60)
            let snapshot = sampler.sample(request: nil, selection: nil, negotiated: negotiated,
                decodedFormat: nil, diagnostics: nil, decoder: decoder, renderer: nil, uptime: 10)
            #expect(snapshot.decodeTime == nil)
            for detail in [StreamStatisticsDetail.simple, .detailed] {
                #expect(sampler.rows(for: snapshot, detail: detail, uptime: 10)
                    .first { $0.id == "decode" }?.value == "Unavailable")
            }
        }
    }

    @Test func pyrowaveNegotiatedProfileIsIdentifiedWithoutInventingDecodeTiming() {
        var sampler = StreamStatisticsSampler()
        let selection = CodecSelection(codec: .pyrowave, hdr: true, chromaSampling: .yuv444, explanation: "Fixture")
        let negotiated = VideoStreamDescription(videoFormat: 0x80000, width: 1920, height: 1080, fps: 120)
        let snapshot = sampler.sample(request: nil, selection: selection, negotiated: negotiated,
            decodedFormat: nil, diagnostics: nil, decoder: nil, renderer: nil, uptime: 10)
        #expect(snapshot.requestedFormat.contains("4:4:4"))
        #expect(snapshot.negotiatedVideo == "PyroWave · 10-bit · 4:4:4")
        #expect(snapshot.decodeTime == nil && snapshot.receivedFramesPerSecond == nil)
    }
    @Test func requestedAndSetupValuesNeverStandInForObservedVideo() {
        var sampler = StreamStatisticsSampler()
        let request = StreamRequest(size: PixelSize(3840, 2160), fps: 120, bitrateKbps: 40_000)
        let selection = CodecSelection(codec: .hevc, hdr: true, explanation: "Fixture")
        let negotiated = VideoStreamDescription(videoFormat: 0x200, width: 3840, height: 2160, fps: 120)
        let snapshot = sampler.sample(request: request, selection: selection, negotiated: negotiated,
            decodedFormat: nil, diagnostics: nil, decoder: nil, renderer: nil, uptime: 10, presentationTime: 100)
        #expect(snapshot.requestedVideo == "3840 × 2160 · 120 Hz")
        #expect(snapshot.requestedFormat.contains("HDR10 · 10-bit · Rec.2020"))
        #expect(snapshot.negotiatedVideo == "HEVC · 10-bit · 4:2:0")
        #expect(snapshot.receivedSize == nil && snapshot.receivedFramesPerSecond == nil)
        #expect(snapshot.networkRoundTrip == nil && snapshot.decodeTime == nil)
        #expect(snapshot.currentFirstPacketToPresentationMilliseconds == nil)
        #expect(sampler.rows(for: snapshot, detail: .simple, uptime: 10)
            .first { $0.id == "client" }?.value == "Unavailable")
    }

    @Test func compressedNegotiatedProfilesShowActualSamplingAndCodec() {
        let cases: [(UInt32, String)] = [
            (0x100, "HEVC · 8-bit · 4:2:0"), (0x200, "HEVC · 10-bit · 4:2:0"),
            (0x400, "HEVC · 8-bit · 4:4:4"), (0x800, "HEVC · 10-bit · 4:4:4"),
            (0x1000, "AV1 · 8-bit · 4:2:0"), (0x2000, "AV1 · 10-bit · 4:2:0"),
            (0x4000, "AV1 · 8-bit · 4:4:4"), (0x8000, "AV1 · 10-bit · 4:4:4")
        ]
        var sampler = StreamStatisticsSampler()
        for (videoFormat, expected) in cases {
            let negotiated = VideoStreamDescription(videoFormat: videoFormat, width: 1920, height: 1080, fps: 60)
            let snapshot = sampler.sample(request: nil, selection: nil, negotiated: negotiated,
                decodedFormat: nil, diagnostics: nil, decoder: nil, renderer: nil, uptime: 10)
            #expect(snapshot.negotiatedVideo == expected)
            #expect(snapshot.decodedColor == nil)
        }
    }

    @Test func decodedSamplingUsesOutputAndOmitsUnavailableValues() throws {
        var sampler = StreamStatisticsSampler()
        let selection = CodecSelection(codec: .hevc, hdr: false, chromaSampling: .yuv444, explanation: "Fixture")
        let negotiated = VideoStreamDescription(videoFormat: 0x400, width: 1920, height: 1080, fps: 60)
        for chroma in [UInt32(1), 3, 2, nil] {
            let chromaField = chroma.map { ",\"chromaFormat\":\($0)" } ?? ""
            let json = """
            {"codec":"hevc","width":1920,"height":1080,"bitDepth":8\(chromaField),
            "color":{"primaries":1,"transfer":1,"matrix":1,"fullRange":false,"chromaLocation":0,
            "mastering":[],"contentLight":[],"hasColorDescription":true,"hasRange":true}}
            """
            let format = try JSONDecoder().decode(DecodedVideoFormat.self, from: Data(json.utf8))
            let snapshot = sampler.sample(request: nil, selection: selection, negotiated: negotiated,
                decodedFormat: format, diagnostics: nil, decoder: nil, renderer: nil, uptime: 10)
            #expect(snapshot.requestedFormat.hasSuffix("4:4:4"))
            #expect(snapshot.negotiatedVideo?.hasSuffix("4:4:4") == true)
            let expected = "8-bit · SDR · Rec.709 · Limited" +
                (chroma == 1 ? " · 4:2:0" : (chroma == 3 ? " · 4:4:4" : ""))
            #expect(snapshot.decodedColor == expected)
            let row = try #require(sampler.rows(for: snapshot, detail: .detailed, uptime: 10).first { $0.id == "color" })
            #expect(row.value == expected)
        }
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
