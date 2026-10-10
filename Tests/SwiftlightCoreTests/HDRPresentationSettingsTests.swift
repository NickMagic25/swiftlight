import Foundation
import XCTest
@testable import SwiftlightCore

final class HDRPresentationSettingsTests: XCTestCase {
    func testMissingOutputKeyPreservesExistingSettingsAndUsesPQDefault() throws {
        let legacy = Data(#"{"codec":"av1","hdr":"on","framesPerSecond":120,"bitrateMbps":45,"automaticBitrate":false,"audioChannels":6,"audioOutput":"systemSpatial"}"#.utf8)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: legacy).validated()
        XCTAssertEqual(decoded.hdrPresentationMode, .nativePQ)
        XCTAssertEqual(decoded.effectiveHDRPresentationMode, .nativePQ)
        XCTAssertEqual(decoded.codec, .av1)
        XCTAssertEqual(decoded.hdr, .on)
        XCTAssertEqual(decoded.framesPerSecond, 120)
        XCTAssertEqual(decoded.bitrateMbps, 45)
        XCTAssertFalse(decoded.automaticBitrate)
        XCTAssertEqual(decoded.audioChannels, .surround51)
        XCTAssertEqual(decoded.audioOutput, .systemSpatial)
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8)), StreamSettings())
    }

    func testSavedLinearAndPQRoundTripWithoutChangingHDRNegotiationOrStreamRequest() throws {
        var original = StreamSettings()
        original.hdr = .on
        original.codec = .hevc
        let baselineRequest = try original.request(display: .fallback)
        for mode in HDRPresentationMode.selectableModes {
            var settings = original
            settings.hdrPresentationMode = mode
            let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings)).validated()
            XCTAssertEqual(decoded, settings)
            XCTAssertEqual(decoded.hdr, original.hdr)
            XCTAssertEqual(try decoded.request(display: .fallback), baselineRequest)
            XCTAssertEqual(decoded.effectiveHDRPresentationMode, mode)
        }
    }

    func testPreviousSystemChoiceMigratesToPQWithoutChangingOtherPreferences() throws {
        var original = StreamSettings()
        original.hdrPresentationMode = .systemToneMapped
        original.hdr = .off
        original.codec = .av1
        original.framesPerSecond = 120
        original.audioChannels = .surround71
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(original)).validated()
        original.hdrPresentationMode = .nativePQ
        XCTAssertEqual(decoded, original)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(encoded?["hdrPresentationMode"] as? String, "nativePQ")
    }

    func testSettingsOffersExactlyLinearAndPQ() {
        XCTAssertEqual(HDRPresentationMode.selectableModes, [.linearUnmapped, .nativePQ])
        XCTAssertEqual(HDRPresentationMode.selectableModes.map(\.label), ["Linear", "PQ"])
        XCTAssertEqual(StreamSettings().hdrPresentationMode, .nativePQ)
    }

    func testUnknownExperimentAndInvalidStoredTypeAreRejected() {
        for json in [#"{"hdrPresentationMode":"direct"}"#, #"{"hdrPresentationMode":1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8)))
        }
    }
}
