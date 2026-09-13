import Foundation

public enum CodecPreference: String, Codable, CaseIterable, Sendable { case auto, hevc, av1 }
public enum HDRPreference: String, Codable, CaseIterable, Sendable { case auto, on, off }
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
    public var scaling: VideoScaling = .fit
    public var pointerMode: PointerMode = .relative
    /// macOS launch preference; other Apple platforms always present full screen.
    public var launchInFullScreen = true
    public var videoPacing: VideoPacing = .immediate
    public var displaySyncEnabled = false
    public var maximumDrawableCount = 3
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case resolution, customSize, framesPerSecond, bitrateMbps, automaticBitrate
        case codec, hdr, scaling, pointerMode, launchInFullScreen
        case videoPacing, displaySyncEnabled, maximumDrawableCount
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
        scaling = try values.decodeIfPresent(VideoScaling.self, forKey: .scaling) ?? scaling
        pointerMode = try values.decodeIfPresent(PointerMode.self, forKey: .pointerMode) ?? pointerMode
        // Existing global/per-host JSON predates this key. Preserve its settings
        // while adopting the full-screen launch default for the new preference.
        launchInFullScreen = try values.decodeIfPresent(Bool.self, forKey: .launchInFullScreen) ?? launchInFullScreen
        videoPacing = try values.decodeIfPresent(VideoPacing.self, forKey: .videoPacing) ?? videoPacing
        displaySyncEnabled = try values.decodeIfPresent(Bool.self, forKey: .displaySyncEnabled) ?? displaySyncEnabled
        maximumDrawableCount = try values.decodeIfPresent(Int.self, forKey: .maximumDrawableCount) ?? maximumDrawableCount
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
        guard bitrateMbps.isFinite, (1...500).contains(bitrateMbps) else {
            throw SettingsError.invalid("Bitrate must be between 1 and 500 Mbps.")
        }
        return self
    }
    public func request(display: DisplayGeometry) throws -> StreamRequest {
        let valid = try validated()
        let size = valid.resolvedSize(display: display)
        let fps = framesPerSecond == 0 ? max(1, min(240, Int(display.refreshHz.rounded()))) : framesPerSecond
        let automatic = min(150, max(5, Double(size.width) * Double(size.height) / (1920 * 1080) * Double(fps) / 60 * 20))
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
    public init(hevc: Bool, av1: Bool, hdr: Bool, hevcHDR: Bool? = nil, av1HDR: Bool? = nil) {
        self.hevc = hevc; self.av1 = av1; self.hdr = hdr
        self.hevcHDR = hevcHDR ?? hdr; self.av1HDR = av1HDR ?? hdr
    }
}
public struct CodecSelection: Equatable, Sendable {
    public let codec: CodecPreference
    public let hdr: Bool
    public let explanation: String
    public static func negotiate(preference: CodecPreference, hdr: HDRPreference,
                                 host: CodecCapabilities, device: CodecCapabilities) throws -> CodecSelection {
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
        }
        let canHDR = selected == .av1 ? av1HDR : hevcHDR
        guard hdr != .on || canHDR else { throw SettingsError.invalid("HDR requires host 10-bit support and an HDR-capable destination display.") }
        let enabled = hdr != .off && canHDR
        return CodecSelection(codec: selected, hdr: enabled,
                              explanation: "\(selected.rawValue.uppercased()) \(enabled ? "HDR10" : "SDR") requested; exact hardware support is confirmed by decoded output.")
    }
}
