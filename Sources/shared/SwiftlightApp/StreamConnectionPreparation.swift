import Foundation
import Security
import SwiftlightCore
import SwiftlightHost
import SwiftlightTransport
import SwiftlightVideo

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
        // ServerCodecModeSupport uses 0x10000/0x20000 for AV1. These are
        // distinct from common-c's negotiated VIDEO_FORMAT_* bits below.
        let hevcHDR = host.codecSupport & 0x200 != 0
        let av1HDR = host.codecSupport & 0x20000 != 0
        let hostHDR = hevcHDR || av1HDR || host.supportsHEVCHDR444 || host.supportsAV1HDR444 ||
            host.supportsPyrowaveHDR || host.supportsPyrowaveHDR444
        selection = try CodecSelection.negotiate(preference: settings.codec, hdr: settings.hdr,
            chromaSampling: settings.chromaSampling,
            host: .init(hevc: host.supportsHEVC, av1: host.supportsAV1, hdr: hostHDR,
                        hevcHDR: hevcHDR, av1HDR: av1HDR,
                        hevc444: host.supportsHEVC444, hevcHDR444: host.supportsHEVCHDR444,
                        av1444: host.supportsAV1444, av1HDR444: host.supportsAV1HDR444,
                        pyrowave: host.supportsPyrowave,
                        pyrowave444: host.supportsPyrowave444, pyrowaveHDR: host.supportsPyrowaveHDR,
                        pyrowaveHDR444: host.supportsPyrowaveHDR444), device: device)
        request = try settings.request(display: display, selection: selection)
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
        let formats: UInt32
        switch selection.codec {
        case .av1:
            formats = selection.chromaSampling == .yuv444
                ? (selection.hdr ? 0x8000 : 0x4000) : (selection.hdr ? 0x2000 : 0x1000)
        case .hevc:
            formats = selection.chromaSampling == .yuv444
                ? (selection.hdr ? 0x800 : 0x400) : (selection.hdr ? 0x200 : 0x100)
        case .pyrowave:
            formats = selection.chromaSampling == .yuv444
                ? (selection.hdr ? 0x080000 : 0x020000) : (selection.hdr ? 0x040000 : 0x010000)
        case .auto:
            preconditionFailure("Transport requires a negotiated codec.")
        }
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

/// Exact compressed-profile probes perform bounded hardware decoding. Keep
/// that work off the UI actor and propagate cancellation between probes.
enum StreamDeviceCapabilities {
    static func resolve(settings: StreamSettings, hdrDisplay: Bool,
                        profileProbe: @escaping @Sendable (VideoCodec, Int, Int) -> Bool = {
                            $0.hardwareProfileCandidate(bitDepth: $1, chromaFormat: $2)
                        }) async throws -> CodecCapabilities {
        try Task.checkCancellation()
        _ = try settings.validated()
        let pyrowave = VideoCodec.pyrowave.hardwareCandidate
        var capabilities = CodecCapabilities(hevc: VideoCodec.hevc.hardwareCandidate,
            av1: VideoCodec.av1.hardwareCandidate, hdr: hdrDisplay,
            pyrowave: pyrowave, pyrowave444: pyrowave,
            pyrowaveHDR: pyrowave, pyrowaveHDR444: pyrowave)
        guard settings.chromaSampling == .yuv444, settings.codec != .pyrowave else { return capabilities }
        let initial = capabilities
        let probeTask = Task.detached(priority: .userInitiated) {
            var result = initial
            if settings.codec == .auto || settings.codec == .hevc {
                try Task.checkCancellation()
                result.hevc444 = profileProbe(.hevc, 8, 3)
                if hdrDisplay, settings.hdr != .off {
                    try Task.checkCancellation()
                    result.hevcHDR444 = profileProbe(.hevc, 10, 3)
                }
            }
            if settings.codec == .auto || settings.codec == .av1 {
                try Task.checkCancellation()
                result.av1444 = profileProbe(.av1, 8, 3)
                if hdrDisplay, settings.hdr != .off {
                    try Task.checkCancellation()
                    result.av1HDR444 = profileProbe(.av1, 10, 3)
                }
            }
            try Task.checkCancellation()
            return result
        }
        capabilities = try await withTaskCancellationHandler {
            try await probeTask.value
        } onCancel: {
            probeTask.cancel()
        }
        try Task.checkCancellation()
        return capabilities
    }
}
