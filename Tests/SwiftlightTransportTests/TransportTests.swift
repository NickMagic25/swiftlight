import XCTest
import CStreamBridge
import SwiftlightCore
@testable import SwiftlightTransport

final class TransportTests: XCTestCase {
    func testAudioNegotiationUsesSameMaskForLaunchAndTransport() throws {
        let callbacks = TransportCallbacks(setup: { _ in true }, video: { _ in true }, event: { _ in })
        for (channels, expected): (AudioChannelConfiguration, UInt32) in [
            (.stereo, 0x00030002), (.surround51, 0x003F0006), (.surround71, 0x063F0008)
        ] {
            let launch = StreamTransport.surroundAudioInfo(for: channels)
            XCTAssertEqual(launch, expected)
            let native = UInt32(sf_stream_audio_configuration(Int32(channels.rawValue)))
            XCTAssertEqual(native & 0xFFFF0000, launch & 0xFFFF0000)
            XCTAssertEqual((native >> 8) & 0xFF, launch & 0xFFFF)
            XCTAssertEqual(native & 0xFF, 0xCA)
            for mode in AudioOutputMode.allCases {
                let config = TransportConfiguration(address: "localhost", appVersion: "7.1.431.0", rtspURL: nil,
                    serverCodecSupport: 0x100, width: 1920, height: 1080, fps: 60, bitrateKbps: 20000,
                    supportedVideoFormats: 0x100, inputKey: Data(repeating: 1, count: 16), inputKeyID: 1,
                    audioChannels: channels, audioOutput: mode)
                XCTAssertEqual(config.audioOutput, channels == .stereo ? .direct : mode)
                _ = try StreamTransport(configuration: config, callbacks: callbacks)
            }
        }
        for invalid: Int32 in [-1, 0, 1, 3, 4, 5, 7, 9, Int32.max] {
            XCTAssertEqual(sf_stream_audio_configuration(invalid), 0)
            XCTAssertEqual(sf_stream_surround_audio_info(invalid), 0)
        }
    }
    func testMultichannelRingPreservesChannelIsolationAcrossWrapAndRouteDiscard() throws {
        for channels: UInt32 in [6, 8] {
            let ring = try XCTUnwrap(sf_audio_ring_create(4, channels))
            defer { sf_audio_ring_destroy(ring) }
            let frame = (0..<Int(channels)).map { Float($0 + 1) }
            let packet = frame + frame + frame
            XCTAssertTrue(sf_audio_ring_write(ring, packet, 3))
            var first = [Float](repeating: 0, count: Int(channels) * 2)
            XCTAssertEqual(sf_audio_ring_read(ring, &first, 2), 2)
            XCTAssertEqual(first, frame + frame)
            XCTAssertTrue(sf_audio_ring_write(ring, packet, 3))
            var wrapped = [Float](repeating: -1, count: Int(channels) * 5)
            XCTAssertEqual(sf_audio_ring_read(ring, &wrapped, 5), 4)
            XCTAssertEqual(wrapped, frame + frame + frame + frame + Array(repeating: 0, count: Int(channels)))
            XCTAssertTrue(sf_audio_ring_write(ring, packet, 3))
            sf_audio_ring_discard_queued(ring)
            XCTAssertEqual(sf_audio_ring_read(ring, &first, 2), 0)
            XCTAssertTrue(first.allSatisfy { $0 == 0 })
        }
    }
    func testAcquiredFramesAlwaysCompleteExactlyOnce() {
        for scenario: UInt32 in 0...5 {
            var completions: UInt32 = 0, submissions: UInt32 = 0
            let result = sf_stream_validate_frame_ownership(scenario, &completions, &submissions)
            XCTAssertEqual(completions, 1, "scenario \(scenario)")
            XCTAssertEqual(submissions, scenario <= 1 ? 1 : 0)
            XCTAssertEqual(result, scenario == 0 ? 0 : -1)
        }
    }
    func testAudioRingWrapOverflowAndSilence() throws {
        let ring = try XCTUnwrap(sf_audio_ring_create(4, 2)); defer { sf_audio_ring_destroy(ring) }
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertTrue(sf_audio_ring_write(ring, input, 3))
        XCTAssertFalse(sf_audio_ring_write(ring, input, 2))
        XCTAssertEqual(sf_audio_ring_overruns(ring), 2)
        var output = [Float](repeating: -1, count: 4)
        XCTAssertEqual(sf_audio_ring_read(ring, &output, 2), 2)
        XCTAssertEqual(output, [1, 2, 3, 4])
        XCTAssertTrue(sf_audio_ring_write(ring, input, 3))
        var wrapped = [Float](repeating: -1, count: 10)
        XCTAssertEqual(sf_audio_ring_read(ring, &wrapped, 5), 4)
        XCTAssertEqual(wrapped, [5, 6, 1, 2, 3, 4, 5, 6, 0, 0])
        XCTAssertEqual(sf_audio_ring_queued(ring), 0)
        XCTAssertEqual(sf_audio_ring_underruns(ring), 1)
    }
    func testVideoTelemetryUnitsWindowsAndConcurrentSnapshots() { XCTAssertTrue(sf_stream_validate_video_telemetry()) }
    func testTelemetrySwiftUnitsAndMissingMeasurements() throws {
        var raw = SFVideoTransportStatistics()
        let absent = VideoTransportStatistics(raw)
        XCTAssertNil(absent.hostProcessingLatency)
        XCTAssertNil(absent.reassemblyTime)
        XCTAssertNil(absent.frameArrivalJitterMilliseconds)
        XCTAssertNil(absent.firstReceiveUptimeNanoseconds)
        XCTAssertEqual(absent.totalFrames, 0)
        raw.received_frames = 98; raw.network_lost_frames = 2
        raw.host_processing_latency = SFTimingSummary(sample_count: 2, minimum_us: 8700, maximum_us: 12300, total_us: 21000)
        raw.reassembly_time = SFTimingSummary(sample_count: 1, minimum_us: 0, maximum_us: 0, total_us: 0)
        raw.frame_arrival_sample_count = 1; raw.frame_arrival_jitter_us = 250
        raw.first_receive_uptime_ns = 1_000_000_000
        let value = VideoTransportStatistics(raw)
        let host = try XCTUnwrap(value.hostProcessingLatency)
        XCTAssertEqual(value.totalFrames, 100)
        XCTAssertEqual(host.sampleCount, 2)
        XCTAssertEqual(host.minimumMilliseconds, 8.7, accuracy: 0.000001)
        XCTAssertEqual(host.maximumMilliseconds, 12.3, accuracy: 0.000001)
        XCTAssertEqual(host.averageMilliseconds, 10.5, accuracy: 0.000001)
        XCTAssertEqual(value.reassemblyTime?.averageMilliseconds, 0) // A measured zero is available.
        XCTAssertEqual(value.frameArrivalJitterMilliseconds, 0.25)
        XCTAssertEqual(value.firstReceiveUptimeNanoseconds, 1_000_000_000)
    }
    func testKeyboardWireMarkerAndHeldRelease() { XCTAssertTrue(sf_stream_validate_keyboard_wire_codes()) }
    func testCancellationAcrossPublishedLifecycleStates() { XCTAssertTrue(sf_stream_validate_cancel_state_race()) }
    func testCommonClockAndLaunchExtensions() {
        XCTAssertTrue(sf_stream_validate_clock_mapping())
        let query = StreamTransport.launchQueryParameters
        XCTAssertFalse(query.isEmpty)
        let parsed = URLComponents(string: "https://localhost/launch?base=1" + query)
        XCTAssertGreaterThan(parsed?.queryItems?.count ?? 0, 1)
    }
    func testRejectsH264AndInvalidInputKey() {
        let callbacks = TransportCallbacks(setup: { _ in true }, video: { _ in true }, event: { _ in })
        for (mask, key) in [(UInt32(1), Data(repeating: 0, count: 16)), (UInt32(0x100), Data())] {
            let config = TransportConfiguration(address: "localhost", appVersion: "7.1.431.0", rtspURL: nil,
                serverCodecSupport: 0x100, width: 1920, height: 1080, fps: 60, bitrateKbps: 20000,
                supportedVideoFormats: mask, inputKey: key, inputKeyID: 1)
            XCTAssertThrowsError(try StreamTransport(configuration: config, callbacks: callbacks))
        }
    }
    func testCancelBeforeStartIsTerminalWithoutNetwork() async throws {
        let config = TransportConfiguration(address: "localhost", appVersion: "7.1.431.0", rtspURL: nil,
            serverCodecSupport: 0x100, width: 1920, height: 1080, fps: 60, bitrateKbps: 20000,
            supportedVideoFormats: 0x100, inputKey: Data(repeating: 1, count: 16), inputKeyID: 1)
        let transport = try StreamTransport(configuration: config,
            callbacks: TransportCallbacks(setup: { _ in true }, video: { _ in true }, event: { _ in }))
        transport.cancelStart()
        do { try await transport.start(); XCTFail("Cancelled transport started") } catch is CancellationError { }
        await transport.stop(); await transport.stop()
        transport.key(0x8041, pressed: true); transport.releaseAllInputs()
    }
}
