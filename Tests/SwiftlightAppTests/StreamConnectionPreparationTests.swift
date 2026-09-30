import Foundation
import SwiftlightCore
import SwiftlightTransport
import Testing
@testable import SwiftlightApp
@testable import SwiftlightHost

struct StreamConnectionPreparationTests {
    @Test func serverCodecBitsProduceOnlyTheSelectedTransportFormat() throws {
        let cases: [(CodecPreference, HDRPreference, UInt32, UInt32)] = [
            (.hevc, .off, 0x100, 0x100),
            (.hevc, .on, 0x300, 0x200),
            (.av1, .off, 0x10000, 0x1000),
            (.av1, .on, 0x30000, 0x2000)
        ]
        for (codec, hdr, serverFlags, expectedFormat) in cases {
            var settings = StreamSettings()
            settings.codec = codec; settings.hdr = hdr
            let prepared = try prepare(settings, flags: serverFlags)
            let transport = configuration(prepared)
            #expect(prepared.selection.codec == codec)
            #expect(prepared.launchRequest.hdr == (hdr == .on))
            #expect(transport.hdr == prepared.launchRequest.hdr)
            #expect(transport.serverCodecSupport == serverFlags)
            #expect(transport.supportedVideoFormats == expectedFormat)
        }
    }

    @Test func automaticHDRIntersectsEachCodecWithoutBorrowingAnotherCodecsBit() throws {
        var settings = StreamSettings()
        settings.hdr = .auto
        let hevcHDR = try prepare(settings, flags: 0x10300)
        #expect(hevcHDR.selection.codec == .hevc && hevcHDR.selection.hdr)
        #expect(configuration(hevcHDR).supportedVideoFormats == 0x200)
        let av1HDR = try prepare(settings, flags: 0x30100)
        #expect(av1HDR.selection.codec == .av1 && av1HDR.selection.hdr)
        #expect(configuration(av1HDR).supportedVideoFormats == 0x2000)
        settings.codec = .av1
        let av1SDR = try prepare(settings, flags: 0x10300)
        #expect(av1SDR.selection.codec == .av1 && !av1SDR.selection.hdr)
        #expect(configuration(av1SDR).supportedVideoFormats == 0x1000)
    }

    @Test func requiredHDRFailsWithControlledErrorsWhenTheSelectedCodecOrDisplayLacksIt() throws {
        var settings = StreamSettings()
        settings.codec = .av1; settings.hdr = .on
        let message = "HDR requires host 10-bit support and an HDR-capable destination display."
        expectSettingsError(message) { _ = try prepare(settings, flags: 0x10300) }
        expectSettingsError(message) { _ = try prepare(settings, flags: 0x30300, displayHDR: false) }
        settings.hdr = .off
        // VIDEO_FORMAT_AV1_* bits must not be accepted as SCM_AV1_* support.
        expectSettingsError("AV1 hardware decoding is unavailable. Choose HEVC or Auto.") {
            _ = try prepare(settings, flags: 0x3000)
        }
    }

    @Test func oneSnapshotKeepsHostLaunchAndTransportConsistentWhenSettingsChange() throws {
        var settings = StreamSettings()
        settings.resolution = .custom; settings.customSize = PixelSize(1921, 1081)
        settings.framesPerSecond = 0; settings.automaticBitrate = false; settings.bitrateMbps = 12.345
        settings.codec = .hevc; settings.hdr = .off
        settings.audioChannels = .surround71; settings.audioOutput = .systemSpatial
        settings.playAudioOnHost = true
        let prepared = try prepare(settings, flags: 0x100, permissions: 0)
        settings.customSize = PixelSize(1280, 720); settings.framesPerSecond = 30
        settings.audioChannels = .stereo; settings.audioOutput = .direct; settings.playAudioOnHost = false
        let launch = prepared.launchRequest
        let transport = configuration(prepared)
        #expect(launch.appID == 17)
        #expect(launch.width == 1920 && launch.height == 1080 && launch.fps == 120)
        #expect(transport.width == launch.width && transport.height == launch.height && transport.fps == launch.fps)
        #expect(transport.bitrateKbps == 12_345)
        #expect(transport.audioChannels == .surround71 && transport.audioOutput == .systemSpatial)
        #expect(launch.surroundAudioInfo == 0x063F0008 && launch.playAudioOnHost)
        #expect(launch.controllerMask == 0 && transport.permissions == 0)
        #expect(launch.inputKey.count == 16 && transport.inputKey == launch.inputKey)
        #expect(transport.inputKeyID == launch.inputKeyID)
        #expect(transport.address == "fixture.invalid" && transport.rtspURL == "rtsp://fixture.invalid/session")
        #expect(transport.appVersion == "7.1" && transport.gfeVersion == "3.2")
        #expect(transport.displayRefreshHz == 119.88)
    }

    @Test func controllerPermissionAndStereoOutputGatesPreserveTheirDefaults() throws {
        var settings = StreamSettings()
        settings.hdr = .off; settings.audioChannels = .stereo; settings.audioOutput = .systemSpatial
        let cases: [(UInt32?, UInt32)] = [(nil, 1), (0, 0), (0x100, 1), (0x800, 0)]
        for (permissions, mask) in cases {
            let prepared = try prepare(settings, flags: 0x100, permissions: permissions)
            #expect(prepared.launchRequest.controllerMask == mask)
            #expect(configuration(prepared).permissions == permissions)
            #expect(configuration(prepared).audioOutput == .direct)
            #expect(prepared.launchRequest.surroundAudioInfo == 0x00030002)
        }
    }

    @Test func descriptionsExcludeEphemeralKeysAndHostData() throws {
        var settings = StreamSettings(); settings.codec = .hevc; settings.hdr = .off
        let prepared = try prepare(settings, flags: 0x100)
        let expected = "StreamConnectionPreparation(codec: hevc, hdr: false, secrets: redacted)"
        #expect(String(describing: prepared) == expected)
        #expect(String(reflecting: prepared) == expected)
    }

    private func prepare(_ settings: StreamSettings, flags: UInt32, permissions: UInt32? = nil,
                         displayHDR: Bool = true) throws -> StreamConnectionPreparation {
        var display = DisplayGeometry.fallback; display.refreshHz = 120
        let host = HostInfo(id: "fixture", name: "Fixture", appVersion: "7.1", gfeVersion: "3.2",
            httpsPort: 47984, isPaired: true, currentAppID: 0, codecSupport: flags,
            permissions: permissions, rawFields: [:])
        return try StreamConnectionPreparation(appID: 17, settings: settings, display: display, host: host,
            device: .init(hevc: true, av1: true, hdr: displayHDR))
    }

    private func configuration(_ prepared: StreamConnectionPreparation) -> TransportConfiguration {
        prepared.transportConfiguration(address: "fixture.invalid", sessionURL: "rtsp://fixture.invalid/session",
                                        displayRefreshHz: 119.88)
    }

    private func expectSettingsError(_ message: String, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected a controlled unsupported-format error")
        } catch let error as SettingsError {
            #expect(error.errorDescription == message)
        } catch {
            Issue.record("Expected SettingsError, received \(type(of: error))")
        }
    }
}
