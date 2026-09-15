import Foundation

/// Only fields that change the layer's HDR10 tone mapping participate in this key.
public enum HDRMetadataValue: Equatable, Sendable {
    case none
    case hdr10(mastering: Data, contentLight: Data)

    public init(color: VideoColor) {
        self = color.transfer == 16 ? .hdr10(mastering: Data(color.mastering), contentLight: Data(color.contentLight)) : .none
    }
}

public struct HDRMetadataState: Sendable {
    public private(set) var value: HDRMetadataValue?
    public init() {}
    /// True also for the first SDR frame: explicitly clear any prior layer metadata.
    public mutating func update(_ next: HDRMetadataValue) -> Bool {
        guard value != next else { return false }
        value = next; return true
    }
}
