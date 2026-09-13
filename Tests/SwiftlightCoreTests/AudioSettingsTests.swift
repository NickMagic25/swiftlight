import Foundation
import XCTest
@testable import SwiftlightCore

final class AudioSettingsTests: XCTestCase {
    func testExistingSettingsKeepVideoPreferencesAndDefaultToStereoDirect() throws {
        let legacy = Data("""
        {"resolution":"custom","customSize":{"width":3440,"height":1440},
         "framesPerSecond":120,"bitrateMbps":47.5,"automaticBitrate":false,
         "codec":"hevc","hdr":"off","scaling":"fill","pointerMode":"absolute",
         "launchInFullScreen":false,"videoPacing":"displayLink",
         "displaySyncEnabled":true,"maximumDrawableCount":2}
        """.utf8)
        var expected = StreamSettings()
        expected.resolution = .custom; expected.customSize = PixelSize(3440, 1440)
        expected.framesPerSecond = 120; expected.bitrateMbps = 47.5; expected.automaticBitrate = false
        expected.codec = .hevc; expected.hdr = .off; expected.scaling = .fill; expected.pointerMode = .absolute
        expected.launchInFullScreen = false; expected.videoPacing = .displayLink
        expected.displaySyncEnabled = true; expected.maximumDrawableCount = 2
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: legacy)
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.audioChannels, .stereo)
        XCTAssertEqual(decoded.effectiveAudioOutput, .direct)
        XCTAssertFalse(decoded.playAudioOnHost)
    }

    func testAudioChoicesRoundTripInSharedGlobalAndComputerSettingsFormat() throws {
        for channels in AudioChannelConfiguration.allCases {
            for output in AudioOutputMode.allCases {
                var settings = StreamSettings()
                settings.audioChannels = channels; settings.audioOutput = output
                settings.playAudioOnHost = true
                let data = try JSONEncoder().encode(settings)
                let decoded = try JSONDecoder().decode(StreamSettings.self, from: data)
                XCTAssertEqual(decoded, settings)
                XCTAssertEqual(decoded.effectiveAudioOutput, channels == .stereo ? .direct : output)
                XCTAssertTrue(decoded.playAudioOnHost)
            }
        }
    }

    func testPartialSavedAudioPreferencesDefaultIndependently() throws {
        let channelsOnly = try JSONDecoder().decode(StreamSettings.self, from: Data("{\"audioChannels\":8}".utf8))
        XCTAssertEqual(channelsOnly.audioChannels, .surround71)
        XCTAssertEqual(channelsOnly.audioOutput, .direct)
        let outputOnly = try JSONDecoder().decode(StreamSettings.self, from: Data("{\"audioOutput\":\"systemSpatial\"}".utf8))
        XCTAssertEqual(outputOnly.audioChannels, .stereo)
        XCTAssertEqual(outputOnly.audioOutput, .systemSpatial)
        XCTAssertEqual(outputOnly.effectiveAudioOutput, .direct)
    }

    func testStereoCannotEnableSpatialPlaybackAfterRestoringSavedSettings() throws {
        let saved = Data("{\"audioChannels\":2,\"audioOutput\":\"systemSpatial\"}".utf8)
        let settings = try JSONDecoder().decode(StreamSettings.self, from: saved).validated()
        XCTAssertEqual(settings.effectiveAudioOutput, .direct)
    }

    func testInvalidAudioConfigurationDoesNotSilentlyBecomeAnotherChannelLayout() {
        for json in ["{\"audioChannels\":4}", "{\"audioChannels\":\"6\"}", "{\"audioOutput\":\"unknown\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8)))
        }
    }
}
