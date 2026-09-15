import Foundation
import Security
import SwiftlightCore
import SwiftlightHost
import SwiftlightTransport

/// One synchronous snapshot feeds both authenticated launch and native transport.
/// The caller owns host verification, platform capabilities, all await points,
/// and session lifetime. Ephemeral input material must never enter diagnostics.
struct StreamConnectionPreparation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let request: StreamRequest
    let selection: CodecSelection
    let launchRequest: StreamLaunchRequest
    private let host: HostInfo
    private let audioChannels: AudioChannelConfiguration
    private let audioOutput: AudioOutputMode

    init(appID: Int, settings: StreamSettings, display: DisplayGeometry, host: HostInfo,
         device: CodecCapabilities) throws {
        request = try settings.request(display: display)
        // ServerCodecModeSupport uses 0x10000/0x20000 for AV1. These are
        // distinct from common-c's negotiated VIDEO_FORMAT_* bits below.
        let hevcHDR = host.codecSupport & 0x200 != 0
        let av1HDR = host.codecSupport & 0x20000 != 0
        let hostHDR = settings.codec == .av1 ? av1HDR : settings.codec == .hevc ? hevcHDR : hevcHDR || av1HDR
        selection = try CodecSelection.negotiate(preference: settings.codec, hdr: settings.hdr,
            host: .init(hevc: host.supportsHEVC, av1: host.supportsAV1, hdr: hostHDR,
                        hevcHDR: hevcHDR, av1HDR: av1HDR), device: device)
        let exactHDRSupported = selection.codec == .av1 ? av1HDR : hevcHDR
        guard !selection.hdr || exactHDRSupported else {
            throw SettingsError.invalid("Selected codec does not support HDR on this host. Choose another codec or disable HDR.")
        }
        var inputKey = Data(count: 16)
        let keyStatus = inputKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard keyStatus == errSecSuccess else { throw HostError.cryptoFailure }
        let keyID = UInt32.random(in: 0...UInt32.max)
        var launch = try StreamLaunchRequest(appID: appID, width: request.size.width, height: request.size.height,
                                            fps: request.fps, inputKey: inputKey, inputKeyID: keyID)
        launch.hdr = selection.hdr
        launch.surroundAudioInfo = StreamTransport.surroundAudioInfo(for: settings.audioChannels)
        launch.playAudioOnHost = settings.playAudioOnHost
        launch.controllerMask = host.permissions.map { $0 & 0x100 != 0 ? 1 : 0 } ?? 1
        let query = StreamTransport.launchQueryParameters.trimmingCharacters(in: CharacterSet(charactersIn: "&?"))
        if !query.isEmpty {
            guard let items = URLComponents(string: "http://localhost/?" + query)?.queryItems else { throw HostError.invalidResponse }
            launch.additionalQuery = items
        }
        launchRequest = launch
        self.host = host
        audioChannels = settings.audioChannels
        audioOutput = settings.effectiveAudioOutput
    }

    func transportConfiguration(address: String, sessionURL: String, displayRefreshHz: Double) -> TransportConfiguration {
        let formats: UInt32 = selection.codec == .av1 ? (selection.hdr ? 0x2000 : 0x1000) : (selection.hdr ? 0x200 : 0x100)
        return TransportConfiguration(address: address, appVersion: host.appVersion, gfeVersion: host.gfeVersion,
            rtspURL: sessionURL, serverCodecSupport: host.codecSupport, width: request.size.width,
            height: request.size.height, fps: request.fps, bitrateKbps: request.bitrateKbps,
            supportedVideoFormats: formats, inputKey: launchRequest.inputKey, inputKeyID: launchRequest.inputKeyID,
            hdr: selection.hdr, permissions: host.permissions, displayRefreshHz: displayRefreshHz,
            audioChannels: audioChannels, audioOutput: audioOutput)
    }

    var description: String {
        "StreamConnectionPreparation(codec: \(selection.codec.rawValue), hdr: \(selection.hdr), secrets: redacted)"
    }
    var debugDescription: String { description }
}
