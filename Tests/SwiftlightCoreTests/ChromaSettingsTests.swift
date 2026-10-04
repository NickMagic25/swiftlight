import Foundation
import XCTest
@testable import SwiftlightCore

final class ChromaSettingsTests: XCTestCase {
    func testExistingSettingsAndGenericCapabilitiesDefaultTo420() throws {
        let settings = try JSONDecoder().decode(StreamSettings.self, from: Data(#"{"codec":"hevc","hdr":"on"}"#.utf8))
        XCTAssertEqual(settings.chromaSampling, .yuv420)
        let capabilities = CodecCapabilities(hevc: true, av1: true, hdr: true)
        XCTAssertFalse(capabilities.hevc444 || capabilities.hevcHDR444 || capabilities.av1444 || capabilities.av1HDR444)
        XCTAssertThrowsError(try choose(.auto, .auto, capabilities, capabilities))
        var selected = settings; selected.chromaSampling = .yuv444
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(selected)), selected)
    }

    func testEach444ProfileRequiresTheSameHostAndDeviceProfile() throws {
        for profile in 0..<4 {
            let supported = capabilities(profile)
            let codec: CodecPreference = profile < 2 ? .hevc : .av1
            let hdr: HDRPreference = profile % 2 == 0 ? .off : .on
            let selection = try choose(codec, hdr, supported, supported)
            XCTAssertEqual(selection.codec, codec)
            XCTAssertEqual(selection.hdr, hdr == .on)
            XCTAssertEqual(selection.chromaSampling, .yuv444)
            for other in 0..<4 where other != profile {
                XCTAssertThrowsError(try choose(codec, hdr, supported, capabilities(other)))
                XCTAssertThrowsError(try choose(codec, hdr, capabilities(other), supported))
            }
        }
    }

    func testAutoChoosesCompatible444HDRBeforeSDR() throws {
        let device = CodecCapabilities(hevc: true, av1: true, hdr: true,
            hevc444: true, hevcHDR444: true, av1444: true, av1HDR444: true)
        var host = device
        host.av1HDR444 = false
        let hdr = try choose(.auto, .auto, host, device)
        XCTAssertEqual(hdr.codec, .hevc); XCTAssertTrue(hdr.hdr)
        let sdr = try choose(.auto, .off, host, device)
        XCTAssertEqual(sdr.codec, .av1); XCTAssertFalse(sdr.hdr)
        host.hevcHDR444 = false
        let fallback = try choose(.auto, .auto, host, device)
        XCTAssertEqual(fallback.codec, .av1); XCTAssertFalse(fallback.hdr)
        XCTAssertThrowsError(try choose(.auto, .on, host, device))
    }

    func testHDR444DoesNotRequireSDR444Or420ButRequiresHDRDisplay() throws {
        for profile in [1, 3] {
            let host = capabilities(profile)
            let codec: CodecPreference = profile == 1 ? .hevc : .av1
            XCTAssertTrue(try choose(codec, .auto, host, host).hdr)
            XCTAssertTrue(try choose(.auto, .on, host, host).hdr)
            XCTAssertThrowsError(try choose(codec, .off, host, host))
            var display = host; display.hdr = false
            XCTAssertThrowsError(try choose(codec, .on, host, display))
            XCTAssertThrowsError(try choose(.auto, .auto, host, display))
        }
    }

    func testExplicit444NeverFallsBackTo420OrPyrowave() throws {
        let only420 = CodecCapabilities(hevc: true, av1: true, hdr: true,
            pyrowave: true, pyrowave444: true, pyrowaveHDR: true, pyrowaveHDR444: true)
        for codec in [CodecPreference.auto, .hevc, .av1] {
            for hdr in HDRPreference.allCases {
                XCTAssertThrowsError(try choose(codec, hdr, only420, only420))
            }
        }
        XCTAssertEqual(try CodecSelection.negotiate(preference: .auto, hdr: .off,
            host: only420, device: only420).chromaSampling, .yuv420)
    }

    private func capabilities(_ profile: Int) -> CodecCapabilities {
        CodecCapabilities(hevc: false, av1: false, hdr: true,
            hevc444: profile == 0, hevcHDR444: profile == 1,
            av1444: profile == 2, av1HDR444: profile == 3)
    }

    private func choose(_ codec: CodecPreference, _ hdr: HDRPreference,
                        _ host: CodecCapabilities, _ device: CodecCapabilities) throws -> CodecSelection {
        try CodecSelection.negotiate(preference: codec, hdr: hdr, chromaSampling: .yuv444, host: host, device: device)
    }
}
