import Foundation

public enum StreamStatisticsDetail: String, Codable, CaseIterable, Sendable {
    case simple, detailed
    public var label: String {
        switch self { case .simple: "Simple"; case .detailed: "Detailed" }
    }
}

public enum StreamStatisticsPosition: String, Codable, CaseIterable, Sendable {
    case topLeading, top, topTrailing
    public var label: String {
        switch self {
        case .topLeading: "Top Left"
        case .top: "Top Center"
        case .topTrailing: "Top Right"
        }
    }
}

/// Client-global presentation preferences. Changing these does not alter the
/// host request or require restarting the stream.
public struct StreamStatisticsPreferences: Codable, Equatable, Sendable {
    public var detail: StreamStatisticsDetail
    public var position: StreamStatisticsPosition

    public init(detail: StreamStatisticsDetail = .simple, position: StreamStatisticsPosition = .top) {
        self.detail = detail; self.position = position
    }

    private enum CodingKeys: String, CodingKey { case detail, position }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve recognized fields when reading an older or newer preference
        // record; a missing/unknown choice defaults independently of the others.
        if let raw = try values.decodeIfPresent(String.self, forKey: .detail) {
            detail = StreamStatisticsDetail(rawValue: raw) ?? .simple
        }
        if let raw = try values.decodeIfPresent(String.self, forKey: .position) {
            position = StreamStatisticsPosition(rawValue: raw) ?? .top
        }
    }
}
