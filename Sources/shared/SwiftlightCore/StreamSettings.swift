import Foundation

public enum CodecPreference: String, Codable, CaseIterable, Sendable { case auto, hevc, av1, pyrowave }
public enum HDRPreference: String, Codable, CaseIterable, Sendable { case auto, on, off }
public enum StreamChromaSampling: String, Codable, CaseIterable, Sendable {
    case yuv420, yuv444
    public var label: String { self == .yuv420 ? "4:2:0" : "4:4:4" }
}
public enum ResolutionMode: String, Codable, CaseIterable, Sendable {
    case hd720, hd1080, qhd1440, uhd4K, custom, native, nativeSafeArea, window
    public var label: String {
        switch self {
        case .hd720: "1280 × 720"
        case .hd1080: "1920 × 1080"
        case .qhd1440: "2560 × 1440"
        case .uhd4K: "3840 × 2160"
        case .custom: "Custom"
        case .native: "Native Display"
        case .nativeSafeArea: "Native — Safe Area"
        case .window: "Window"
        }
    }
}
public enum PointerMode: String, Codable, CaseIterable, Sendable { case relative, absolute }
public enum VideoScaling: String, Codable, CaseIterable, Sendable { case fit, fill, integer }
public enum VideoPacing: String, Codable, CaseIterable, Sendable {
    case displayLink, immediate
    public var label: String { self == .displayLink ? "Display paced" : "On decoded frame (lowest latency)" }
}
public enum AudioChannelConfiguration: Int, Codable, CaseIterable, Sendable {
    case stereo = 2, surround51 = 6, surround71 = 8
    public var label: String {
        switch self {
        case .stereo: "Stereo"
        case .surround51: "5.1 Surround"
        case .surround71: "7.1 Surround"
        }
    }
}
public enum AudioOutputMode: String, Codable, CaseIterable, Sendable {
    case direct, systemSpatial
    public var label: String {
        switch self {
        case .direct: "Direct"
        case .systemSpatial: "System Spatial Audio"
        }
    }
}
public struct PixelSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    public var even: PixelSize { PixelSize(max(2, width / 2 * 2), max(2, height / 2 * 2)) }
}
public struct StreamSettings: Codable, Equatable, Sendable {
    public var resolution: ResolutionMode = .hd1080
    public var customSize = PixelSize(1920, 1080)
    /// Zero requests the destination display's refresh rate.
    public var framesPerSecond: Int = 60
    public var bitrateMbps: Double = 20
    public var automaticBitrate = true
    public var codec: CodecPreference = .auto
    public var hdr: HDRPreference = .auto
    /// An explicit 4:4:4 request requires a compatible host and decoder profile.
    public var chromaSampling: StreamChromaSampling = .yuv420
    public var scaling: VideoScaling = .fit
    public var pointerMode: PointerMode = .relative
    /// macOS launch preference; other Apple platforms always present full screen.
    public var launchInFullScreen = true
    public var videoPacing: VideoPacing = .immediate
    public var displaySyncEnabled = false
    public var maximumDrawableCount = 3
    public var audioChannels: AudioChannelConfiguration = .stereo
    public var audioOutput: AudioOutputMode = .direct
    public var playAudioOnHost = false
    /// Stereo may already contain a host-rendered binaural mix. Do not apply a
    /// second spatial effect, including when decoding an inconsistent saved value.
    public var effectiveAudioOutput: AudioOutputMode { audioChannels == .stereo ? .direct : audioOutput }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case resolution, customSize, framesPerSecond, bitrateMbps, automaticBitrate
        case codec, hdr, chromaSampling, scaling, pointerMode, launchInFullScreen
        case videoPacing, displaySyncEnabled, maximumDrawableCount
        case audioChannels, audioOutput, playAudioOnHost
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try values.decodeIfPresent(ResolutionMode.self, forKey: .resolution) ?? resolution
        customSize = try values.decodeIfPresent(PixelSize.self, forKey: .customSize) ?? customSize
        framesPerSecond = try values.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? framesPerSecond
        bitrateMbps = try values.decodeIfPresent(Double.self, forKey: .bitrateMbps) ?? bitrateMbps
        automaticBitrate = try values.decodeIfPresent(Bool.self, forKey: .automaticBitrate) ?? automaticBitrate
        codec = try values.decodeIfPresent(CodecPreference.self, forKey: .codec) ?? codec
        hdr = try values.decodeIfPresent(HDRPreference.self, forKey: .hdr) ?? hdr
        chromaSampling = try values.decodeIfPresent(StreamChromaSampling.self, forKey: .chromaSampling) ?? chromaSampling
        scaling = try values.decodeIfPresent(VideoScaling.self, forKey: .scaling) ?? scaling
        pointerMode = try values.decodeIfPresent(PointerMode.self, forKey: .pointerMode) ?? pointerMode
        // Existing global/per-host JSON predates this key. Preserve its settings
        // while adopting the full-screen launch default for the new preference.
        launchInFullScreen = try values.decodeIfPresent(Bool.self, forKey: .launchInFullScreen) ?? launchInFullScreen
        videoPacing = try values.decodeIfPresent(VideoPacing.self, forKey: .videoPacing) ?? videoPacing
        displaySyncEnabled = try values.decodeIfPresent(Bool.self, forKey: .displaySyncEnabled) ?? displaySyncEnabled
        maximumDrawableCount = try values.decodeIfPresent(Int.self, forKey: .maximumDrawableCount) ?? maximumDrawableCount
        audioChannels = try values.decodeIfPresent(AudioChannelConfiguration.self, forKey: .audioChannels) ?? audioChannels
        audioOutput = try values.decodeIfPresent(AudioOutputMode.self, forKey: .audioOutput) ?? audioOutput
        playAudioOnHost = try values.decodeIfPresent(Bool.self, forKey: .playAudioOnHost) ?? playAudioOnHost
    }
    public func resolvedSize(display: DisplayGeometry) -> PixelSize {
        switch resolution {
        case .hd720: PixelSize(1280, 720)
        case .hd1080: PixelSize(1920, 1080)
        case .qhd1440: PixelSize(2560, 1440)
        case .uhd4K: PixelSize(3840, 2160)
        case .custom: customSize.even
        case .native: display.nativePixels.even
        case .nativeSafeArea: display.safeNativePixels.even
        case .window: display.windowPixels.even
        }
    }
    public func validated() throws -> StreamSettings {
        guard (2...3).contains(maximumDrawableCount) else {
            throw SettingsError.invalid("Drawable count must be 2 or 3.")
        }
        guard (64...16384).contains(customSize.width), (64...16384).contains(customSize.height) else {
            throw SettingsError.invalid("Custom dimensions must be between 64 and 16384 pixels.")
        }
        guard framesPerSecond == 0 || (1...240).contains(framesPerSecond) else {
            throw SettingsError.invalid("Frame rate must be automatic or between 1 and 240 FPS.")
        }
        let maximumBitrate: Double = codec == .pyrowave ? 10_000 : 500
        guard bitrateMbps.isFinite, (1...maximumBitrate).contains(bitrateMbps) else {
            throw SettingsError.invalid("Bitrate must be between 1 and \(Int(maximumBitrate)) Mbps.")
        }
        return self
    }
    public func request(display: DisplayGeometry, selection: CodecSelection? = nil) throws -> StreamRequest {
        let valid = try validated()
        let size = valid.resolvedSize(display: display)
        let fps = framesPerSecond == 0 ? max(1, min(240, Int(display.refreshHz.rounded()))) : framesPerSecond
        let automatic: Double
        if codec == .pyrowave {
            // Upstream's visually clean SDR 4:2:0 reference is 1.6 bits/pixel.
            // The 900 Mbps automatic ceiling leaves headroom on a gigabit LAN;
            // faster links can opt into a larger manual budget.
            let chroma = selection?.chromaSampling ?? chromaSampling
            let isHDR = selection?.hdr ?? (hdr == .on)
            let bitsPerPixel = 1.6 * (chroma == .yuv444 ? 1.6 : 1) * (isHDR ? 1.15 : 1)
            automatic = min(900, max(20, Double(size.width) * Double(size.height) * Double(fps) * bitsPerPixel / 1_000_000))
        } else {
            automatic = min(150, max(5, Double(size.width) * Double(size.height) / (1920 * 1080) * Double(fps) / 60 * 20))
        }
        return StreamRequest(size: size, fps: fps, bitrateKbps: Int(((automaticBitrate ? automatic : bitrateMbps) * 1000).rounded()))
    }
}
public enum SettingsError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public struct StreamRequest: Codable, Equatable, Sendable {
    public let size: PixelSize
    public let fps: Int
    public let bitrateKbps: Int
}
public struct CodecCapabilities: Sendable {
    public var hevc: Bool
    public var av1: Bool
    public var hdr: Bool
    public var hevcHDR: Bool
    public var av1HDR: Bool
    public var hevc444: Bool
    public var hevcHDR444: Bool
    public var av1444: Bool
    public var av1HDR444: Bool
    public var pyrowave: Bool
    public var pyrowave444: Bool
    public var pyrowaveHDR: Bool
    public var pyrowaveHDR444: Bool
    public init(hevc: Bool, av1: Bool, hdr: Bool, hevcHDR: Bool? = nil, av1HDR: Bool? = nil,
                hevc444: Bool = false, hevcHDR444: Bool = false,
                av1444: Bool = false, av1HDR444: Bool = false,
                pyrowave: Bool = false, pyrowave444: Bool = false,
                pyrowaveHDR: Bool = false, pyrowaveHDR444: Bool = false) {
        self.hevc = hevc; self.av1 = av1; self.hdr = hdr
        self.hevcHDR = hevcHDR ?? hdr; self.av1HDR = av1HDR ?? hdr
        self.hevc444 = hevc444; self.hevcHDR444 = hevcHDR444
        self.av1444 = av1444; self.av1HDR444 = av1HDR444
        self.pyrowave = pyrowave; self.pyrowave444 = pyrowave444
        self.pyrowaveHDR = pyrowaveHDR; self.pyrowaveHDR444 = pyrowaveHDR444
    }
}
public struct CodecSelection: Equatable, Sendable {
    public let codec: CodecPreference
    public let hdr: Bool
    public let chromaSampling: StreamChromaSampling
    public let explanation: String
    public init(codec: CodecPreference, hdr: Bool, chromaSampling: StreamChromaSampling = .yuv420,
                explanation: String) {
        self.codec = codec; self.hdr = hdr; self.chromaSampling = chromaSampling; self.explanation = explanation
    }
    public static func negotiate(preference: CodecPreference, hdr: HDRPreference,
                                 chromaSampling: StreamChromaSampling = .yuv420,
                                 host: CodecCapabilities, device: CodecCapabilities) throws -> CodecSelection {
        if preference == .pyrowave {
            guard host.pyrowave && device.pyrowave else {
                throw SettingsError.invalid("PyroWave requires a compatible Vibepollo host and Metal decoder on this device.")
            }
            let canSDR = chromaSampling == .yuv420 || (host.pyrowave444 && device.pyrowave444)
            let canHDRProfile = chromaSampling == .yuv444
                ? host.pyrowaveHDR444 && device.pyrowaveHDR444 : host.pyrowaveHDR && device.pyrowaveHDR
            let canHDR = host.hdr && device.hdr && canHDRProfile
            guard hdr != .on || canHDR else {
                throw SettingsError.invalid("HDR requires host 10-bit support and an HDR-capable destination display.")
            }
            let enabled = hdr != .off && canHDR
            guard enabled || canSDR else {
                throw SettingsError.invalid("PyroWave \(chromaSampling.label) SDR is unavailable for this host/device. Choose 4:2:0 or a supported HDR profile.")
            }
            return CodecSelection(codec: .pyrowave, hdr: enabled, chromaSampling: chromaSampling,
                explanation: "PyroWave \(enabled ? "HDR10" : "SDR") \(chromaSampling.label) requested; requires a fast wired LAN.")
        }
        if chromaSampling == .yuv444 {
            // Profile bits are independent: 4:2:0 and 8-bit support do not
            // establish either 4:4:4 profile, nor does 10-bit imply 8-bit.
            let hevcSDR = host.hevc444 && device.hevc444
            let av1SDR = host.av1444 && device.av1444
            let hevcHDR = host.hdr && device.hdr && host.hevcHDR444 && device.hevcHDR444
            let av1HDR = host.hdr && device.hdr && host.av1HDR444 && device.av1HDR444
            let selected: CodecPreference
            switch preference {
            case .auto:
                if hdr != .off && av1HDR { selected = .av1 }
                else if hdr != .off && hevcHDR { selected = .hevc }
                else if av1SDR { selected = .av1 }
                else if hevcSDR { selected = .hevc }
                else { throw SettingsError.invalid("This host and device share no supported hardware HEVC or AV1 4:4:4 profile. Choose 4:2:0 or another codec.") }
            case .hevc:
                guard hevcSDR || (hdr != .off && hevcHDR) else {
                    throw SettingsError.invalid("HEVC 4:4:4 hardware decoding is unavailable for this host/device. Choose 4:2:0 or Auto.")
                }
                selected = .hevc
            case .av1:
                guard av1SDR || (hdr != .off && av1HDR) else {
                    throw SettingsError.invalid("AV1 4:4:4 hardware decoding is unavailable for this host/device. Choose 4:2:0 or Auto.")
                }
                selected = .av1
            case .pyrowave:
                throw SettingsError.invalid("PyroWave negotiation could not be completed.")
            }
            let canHDR = selected == .av1 ? av1HDR : hevcHDR
            guard hdr != .on || canHDR else {
                throw SettingsError.invalid("HDR 4:4:4 requires a supported host 10-bit profile, hardware decoder, and HDR-capable destination display.")
            }
            let enabled = hdr != .off && canHDR
            return CodecSelection(codec: selected, hdr: enabled, chromaSampling: .yuv444,
                explanation: "\(selected.rawValue.uppercased()) \(enabled ? "HDR10" : "SDR") 4:4:4 requested; hardware support is confirmed by decoded output.")
        }
        let hevc = host.hevc && device.hevc, av1 = host.av1 && device.av1
        let hevcHDR = hevc && host.hdr && device.hdr && host.hevcHDR && device.hevcHDR
        let av1HDR = av1 && host.hdr && device.hdr && host.av1HDR && device.av1HDR
        let selected: CodecPreference
        switch preference {
        case .auto:
            if hdr != .off && av1HDR { selected = .av1 }
            else if hdr != .off && hevcHDR { selected = .hevc }
            else if av1 { selected = .av1 }
            else if hevc { selected = .hevc }
            else { throw SettingsError.invalid("This host and device share no supported hardware HEVC or AV1 format.") }
        case .hevc:
            guard hevc else { throw SettingsError.invalid("HEVC hardware decoding is unavailable for this host/device.") }; selected = .hevc
        case .av1:
            guard av1 else { throw SettingsError.invalid("AV1 hardware decoding is unavailable. Choose HEVC or Auto.") }; selected = .av1
        case .pyrowave:
            // Handled above; PyroWave never enters automatic codec selection.
            throw SettingsError.invalid("PyroWave negotiation could not be completed.")
        }
        let canHDR = selected == .av1 ? av1HDR : hevcHDR
        guard hdr != .on || canHDR else { throw SettingsError.invalid("HDR requires host 10-bit support and an HDR-capable destination display.") }
        let enabled = hdr != .off && canHDR
        return CodecSelection(codec: selected, hdr: enabled,
                              explanation: "\(selected.rawValue.uppercased()) \(enabled ? "HDR10" : "SDR") requested; exact hardware support is confirmed by decoded output.")
    }
}
