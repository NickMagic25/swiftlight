import Foundation
import XCTest
@testable import SwiftlightCore

final class PyrowaveSettingsTests: XCTestCase {
    private var allProfiles: CodecCapabilities {
        .init(hevc: true, av1: true, hdr: true, pyrowave: true,
              pyrowave444: true, pyrowaveHDR: true, pyrowaveHDR444: true)
    }

    func testExistingPreferencesKeepAutomaticCodecAnd420WhilePyrowaveRoundTrips() throws {
        let defaults = try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults.codec, .auto)
        XCTAssertEqual(defaults.chromaSampling, .yuv420)
        var settings = defaults
        settings.codec = .pyrowave; settings.chromaSampling = .yuv444
        settings.automaticBitrate = false; settings.bitrateMbps = 2500
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings)).validated()
        XCTAssertEqual(decoded, settings)
        XCTAssertThrowsError(try JSONDecoder().decode(StreamSettings.self, from: Data("{\"chromaSampling\":\"4:4:4\"}".utf8)))
    }

    func testAutomaticCodecDoesNotSelectPyrowaveEvenWhenItIsTheOnlyMutualFormat() throws {
        XCTAssertEqual(try CodecSelection.negotiate(preference: .auto, hdr: .auto,
            host: allProfiles, device: allProfiles).codec, .av1)
        let onlyPyrowave = CodecCapabilities(hevc: false, av1: false, hdr: false, pyrowave: true)
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .auto, hdr: .off,
            host: onlyPyrowave, device: onlyPyrowave))
        XCTAssertEqual(try CodecSelection.negotiate(preference: .pyrowave, hdr: .off,
            host: onlyPyrowave, device: onlyPyrowave).codec, .pyrowave)
    }

    func testExactPyrowaveProfilesIntersectHostAndDeviceWithoutBorrowingHDR() throws {
        for chroma in StreamChromaSampling.allCases {
            let selection = try CodecSelection.negotiate(preference: .pyrowave, hdr: .on,
                chromaSampling: chroma, host: allProfiles, device: allProfiles)
            XCTAssertEqual(selection.chromaSampling, chroma)
            XCTAssertTrue(selection.hdr)
        }
        var limitedHost = allProfiles
        limitedHost.pyrowaveHDR444 = false
        let sdr444 = try CodecSelection.negotiate(preference: .pyrowave, hdr: .auto,
            chromaSampling: .yuv444, host: limitedHost, device: allProfiles)
        XCTAssertFalse(sdr444.hdr)
        XCTAssertEqual(sdr444.chromaSampling, .yuv444)
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .pyrowave, hdr: .on,
            chromaSampling: .yuv444, host: limitedHost, device: allProfiles))
        limitedHost.pyrowave444 = false
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .pyrowave, hdr: .off,
            chromaSampling: .yuv444, host: limitedHost, device: allProfiles))
        limitedHost.pyrowave = false
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .pyrowave, hdr: .off,
            host: limitedHost, device: allProfiles))
        var sdrDisplay = allProfiles; sdrDisplay.hdr = false
        XCTAssertThrowsError(try CodecSelection.negotiate(preference: .pyrowave, hdr: .on,
            host: allProfiles, device: sdrDisplay))
    }

    func testAutomaticBitrateUsesNegotiatedProfileAndManualWiredBudgetIsBounded() throws {
        var settings = StreamSettings(); settings.codec = .pyrowave; settings.hdr = .auto
        let sdr = try CodecSelection.negotiate(preference: .pyrowave, hdr: .off,
            host: allProfiles, device: allProfiles)
        let hdr444 = try CodecSelection.negotiate(preference: .pyrowave, hdr: .on,
            chromaSampling: .yuv444, host: allProfiles, device: allProfiles)
        XCTAssertEqual(try settings.request(display: .fallback, selection: sdr).bitrateKbps, 199_066)
        XCTAssertEqual(try settings.request(display: .fallback, selection: hdr444).bitrateKbps, 366_281)
        settings.resolution = .uhd4K; settings.framesPerSecond = 240
        XCTAssertEqual(try settings.request(display: .fallback, selection: hdr444).bitrateKbps, 900_000)
        settings.automaticBitrate = false; settings.bitrateMbps = 10_000
        XCTAssertEqual(try settings.request(display: .fallback).bitrateKbps, 10_000_000)
        settings.bitrateMbps = 10_000.1; XCTAssertThrowsError(try settings.validated())
        settings.bitrateMbps = .infinity; XCTAssertThrowsError(try settings.validated())
        settings.bitrateMbps = 501; settings.codec = .hevc
        XCTAssertThrowsError(try settings.validated())
    }
}
