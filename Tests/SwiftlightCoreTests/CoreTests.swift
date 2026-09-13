import CoreGraphics
import XCTest
@testable import SwiftlightCore

final class CoreTests: XCTestCase {
    func testReconnectIntentCannotSurviveCancelOrSwitchHosts() {
        var gate = SessionIntentGate()
        let reconnect = gate.issue(hostID: "hostA")
        XCTAssertTrue(gate.accepts(reconnect, selectedHostID: "hostA"))
        gate.retire()
        XCTAssertFalse(gate.accepts(reconnect, selectedHostID: "hostA"))
        let resume = gate.issue(hostID: "hostA")
        XCTAssertFalse(gate.accepts(resume, selectedHostID: "hostB"))
        let newer = gate.issue(hostID: "hostA")
        XCTAssertFalse(gate.accepts(resume, selectedHostID: "hostA"))
        XCTAssertTrue(gate.accepts(newer, selectedHostID: "hostA"))
    }
    func testCancelRetiresLateCallbacks() {
        var state = SessionState()
        XCTAssertEqual(state.apply(.connect), [.start]); let old = state.generation
        XCTAssertEqual(state.apply(.cancel), [.releaseInputs, .clearPresentation, .stop])
        XCTAssertEqual(state.apply(.negotiated, generation: old), [])
        XCTAssertEqual(state.apply(.firstFrame, generation: old), [])
        XCTAssertEqual(state.phase, .disconnecting)
        state.apply(.stopped); XCTAssertEqual(state.phase, .ready)
    }
    func testSetupFailureAndRepeatedStartStop() {
        var state = SessionState()
        for _ in 0..<100 {
            state.apply(.connect); let id = state.generation
            state.apply(.failure("Unsupported stream"), generation: id)
            XCTAssertEqual(state.phase, .failed)
            state.apply(.firstFrame, generation: id); XCTAssertEqual(state.phase, .failed)
            state.apply(.connect); state.apply(.negotiated); state.apply(.firstFrame)
            XCTAssertEqual(state.phase, .streaming)
            XCTAssertEqual(state.apply(.disconnect), [.releaseInputs, .clearPresentation, .stop])
            XCTAssertEqual(state.apply(.disconnect), [])
            state.apply(.stopped); XCTAssertEqual(state.phase, .ready)
        }
    }
    func testSettingsReconnectSuspendResumeAndPathFailure() {
        var state = SessionState()
        state.apply(.connect); state.apply(.negotiated); state.apply(.firstFrame)
        let original = state.generation
        XCTAssertEqual(state.apply(.settingsChanged), [.releaseInputs, .clearPresentation, .stop])
        XCTAssertEqual(state.phase, .reconfiguring)
        XCTAssertEqual(state.apply(.stopped), [.start])
        XCTAssertGreaterThan(state.generation, original)
        state.apply(.negotiated); state.apply(.firstFrame)
        state.apply(.suspend); state.apply(.stopped)
        XCTAssertEqual(state.phase, .suspending)
        XCTAssertEqual(state.apply(.resume), [.resume])
        state.apply(.negotiated); state.apply(.firstFrame)
        XCTAssertEqual(state.apply(.pathLost), [.releaseInputs, .clearPresentation, .stop])
        XCTAssertEqual(state.phase, .failed)
    }
    func testHeldInputsReleaseExactlyOnce() {
        var input = HeldInputs()
        input.key(42, down: true); input.key(42, down: true); input.mouse(1, down: true); input.controller(0)
        let released = input.releaseAll()
        XCTAssertEqual(released.keys, [42]); XCTAssertEqual(released.mouse, [1]); XCTAssertEqual(released.controllers, [0])
        XCTAssertTrue(input.releaseAll().keys.isEmpty)
    }
    func testSafeAreaIntersectionDoesNotSubtractTwice() {
        let screen = CGRect(x: 100, y: 20, width: 1512, height: 982)
        let safe = CGRect(x: 100, y: 20, width: 1512, height: 950)
        let full = DisplayGeometry(screen: screen, safeScreen: safe, content: screen,
            nativePixels: PixelSize(3024, 1964), backingScale: 2, refreshHz: 120)
        let alreadySafe = DisplayGeometry(screen: screen, safeScreen: safe, content: safe,
            nativePixels: PixelSize(3024, 1964), backingScale: 2, refreshHz: 120)
        XCTAssertEqual(full.safeNativePixels, PixelSize(3024, 1900))
        XCTAssertEqual(full.safeNativePixels, alreadySafe.safeNativePixels)
    }
    func testNativeModeIsDistinctFromBackingPixels() {
        let display = DisplayGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeScreen: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: CGRect(x: 0, y: 0, width: 960, height: 540),
            nativePixels: PixelSize(3008, 1692), backingScale: 2, refreshHz: 59.94)
        XCTAssertEqual(display.safeNativePixels, PixelSize(1504, 846))
        XCTAssertEqual(display.windowPixels, PixelSize(1920, 1080))
    }
    func testViewportLetterboxAndCropInput() {
        let fit = ViewportTransform(source: CGSize(width: 1920, height: 1080), destination: CGRect(x: 10, y: 20, width: 1000, height: 1000))
        XCTAssertNil(fit.videoPoint(CGPoint(x: 20, y: 30)))
        XCTAssertEqual(fit.videoPoint(CGPoint(x: 510, y: 520)), CGPoint(x: 960, y: 540))
        let crop = ViewportTransform(source: CGSize(width: 1920, height: 1080), destination: CGRect(x: 0, y: 0, width: 1000, height: 1000), scaling: .fill)
        XCTAssertGreaterThan(crop.videoPoint(CGPoint(x: 0, y: 0))!.x, 0)
        XCTAssertNil(crop.videoPoint(CGPoint(x: -1, y: 500)))
    }
    func testEvenRoundingBitrateAndDisplayFPS() throws {
        var settings = StreamSettings()
        settings.resolution = .custom; settings.customSize = PixelSize(1919, 1079)
        settings.automaticBitrate = false; settings.bitrateMbps = 12.345; settings.framesPerSecond = 0
        let request = try settings.request(display: .fallback)
        XCTAssertEqual(request.size, PixelSize(1918, 1078)); XCTAssertEqual(request.bitrateKbps, 12345)
        XCTAssertEqual(request.fps, 60)
        settings.bitrateMbps = .nan; XCTAssertThrowsError(try settings.validated())
    }
    func testAutoHDRIntersectsPerCodecBitDepth() throws {
        let host = CodecCapabilities(hevc: true, av1: true, hdr: true, hevcHDR: true, av1HDR: false)
        let device = CodecCapabilities(hevc: true, av1: true, hdr: true)
        let choice = try CodecSelection.negotiate(preference: .auto, hdr: .on, host: host, device: device)
        XCTAssertEqual(choice.codec, .hevc); XCTAssertTrue(choice.hdr)
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .av1, hdr: .on, host: host, device: device))
    }
    func testCodecSelectionCannotAdvertiseFallbackOrInventHDR() throws {
        let host = CodecCapabilities(hevc: true, av1: true, hdr: true)
        let device = CodecCapabilities(hevc: true, av1: false, hdr: false)
        XCTAssertEqual(try CodecSelection.negotiate(preference: .auto, hdr: .auto, host: host, device: device).codec, .hevc)
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .av1, hdr: .off, host: host, device: device))
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .hevc, hdr: .on, host: host, device: device))
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .auto, hdr: .off,
            host: .init(hevc: false, av1: false, hdr: false), device: device))
    }
}
