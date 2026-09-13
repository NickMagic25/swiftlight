import Foundation
import XCTest
@testable import SwiftlightCore

final class PresentationPolicyTests: XCTestCase {
    func testExistingSettingsKeepEverySavedValueWhenFullScreenKeyIsMissing() throws {
        let legacy = Data("""
        {"resolution":"custom","customSize":{"width":3440,"height":1440},
         "framesPerSecond":120,"bitrateMbps":47.5,"automaticBitrate":false,
         "codec":"hevc","hdr":"off","scaling":"fill","pointerMode":"absolute"}
        """.utf8)
        var expected = StreamSettings()
        expected.resolution = .custom; expected.customSize = PixelSize(3440, 1440)
        expected.framesPerSecond = 120; expected.bitrateMbps = 47.5; expected.automaticBitrate = false
        expected.codec = .hevc; expected.hdr = .off; expected.scaling = .fill; expected.pointerMode = .absolute
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: legacy)
        XCTAssertEqual(decoded, expected)
        XCTAssertTrue(decoded.launchInFullScreen)
    }

    func testSavedWindowedPreferenceSurvivesSettingsRoundTrip() throws {
        var settings = StreamSettings()
        settings.launchInFullScreen = false; settings.resolution = .nativeSafeArea
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertFalse(decoded.launchInFullScreen)
    }

    func testMissingSettingsUseDefaultsWithoutAcceptingInvalidStoredTypes() throws {
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8)), StreamSettings())
        XCTAssertThrowsError(try JSONDecoder().decode(StreamSettings.self, from: Data("{\"launchInFullScreen\":\"false\"}".utf8)))
    }

    func testMacPreferenceAndRequiredFullScreenOnOtherApplePlatforms() {
        var settings = StreamSettings()
        for platform in StreamPlatform.allCases {
            XCTAssertTrue(StreamPresentationPolicy.launchesFullScreen(on: platform, settings: settings))
        }
        settings.launchInFullScreen = false
        XCTAssertFalse(StreamPresentationPolicy.launchesFullScreen(on: .macOS, settings: settings))
        for platform in [StreamPlatform.iOS, .iPadOS, .tvOS] {
            XCTAssertTrue(StreamPresentationPolicy.launchesFullScreen(on: platform, settings: settings))
        }
    }
}
