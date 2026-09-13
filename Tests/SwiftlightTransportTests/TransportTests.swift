import XCTest
import CStreamBridge
@testable import SwiftlightTransport

final class TransportTests: XCTestCase {
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
