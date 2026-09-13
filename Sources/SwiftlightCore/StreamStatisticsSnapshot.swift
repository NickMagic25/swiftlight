import Foundation

public struct StreamStatisticsLine: Equatable, Sendable {
    public let id, label, value: String
    public init(_ id: String, _ label: String, _ value: String) { self.id = id; self.label = label; self.value = value }
}

/// Display-ready data shared by platform adapters. Missing measurements stay nil;
/// requested, negotiated and observed formats are intentionally separate fields.
public struct StreamStatisticsSnapshot: Codable, Equatable, Sendable {
    public var requestedVideo = "Preparing…"
    public var requestedFormat = "Preparing…"
    public var receivedSize: PixelSize?
    public var receivedFramesPerSecond: Double?
    public var negotiatedVideo: String?
    public var decodedColor: String?
    public var hostProcessing: StreamTimingSummary?
    public var networkRoundTrip: StreamTimingSummary?
    public var networkJitterMilliseconds: Double?
    public var networkLostFrames: UInt64?
    public var totalNetworkFrames: UInt64?
    public var decodeTime: StreamTimingSummary?
    public var firstPacketToPresentation: StreamTimingSummary?
    public var currentFirstPacketToPresentationMilliseconds: Double?
    public var hostProcessingAndClientPresentation: StreamTimingSummary?
    public init() {}

    public var estimatedHostToDisplayMilliseconds: Double? {
        guard let paired = hostProcessingAndClientPresentation, let rtt = networkRoundTrip else { return nil }
        // The protocol has no synchronized server capture clock. Half RTT is an
        // explicit transit estimate, not measured one-way network latency.
        return paired.averageMilliseconds + rtt.averageMilliseconds / 2
    }
    public func lines(detail: StreamStatisticsDetail) -> [StreamStatisticsLine] {
        let detailed = detail == .detailed
        var lines = [StreamStatisticsLine("request", "Requested video", requestedVideo),
                     StreamStatisticsLine("request-format", "Requested format", requestedFormat)]
        let size = receivedSize.map { "\($0.width) × \($0.height)" } ?? "Waiting for video"
        let fps = receivedFramesPerSecond.map { String(format: "%.1f FPS", $0) } ?? "Measuring FPS…"
        lines.append(.init("received", "Received video", "\(size) · \(fps)"))
        if detailed {
            lines.append(.init("negotiated", "Negotiated codec", negotiatedVideo ?? "Unavailable"))
            lines.append(.init("color", "Decoded color", decodedColor ?? "Waiting for video"))
        }
        lines.append(.init("host", "Host processing", duration(hostProcessing, detailed: detailed)))
        lines.append(.init("network", "Network latency (RTT)", duration(networkRoundTrip, detailed: detailed)))
        lines.append(.init("jitter", "Network jitter", milliseconds(networkJitterMilliseconds)))
        let loss: String
        if let lost = networkLostFrames, let total = totalNetworkFrames, total > 0 {
            loss = "\(lost) / \(total) (\(String(format: "%.2f", Double(lost) / Double(total) * 100))%)"
        } else { loss = networkLostFrames.map(String.init) ?? "Unavailable" }
        lines.append(.init("loss", "Frames lost to network", loss))
        lines.append(.init("decode", "Decode time", duration(decodeTime, detailed: detailed)))
        lines.append(.init("client", "First packet → display", detailed
            ? duration(firstPacketToPresentation, detailed: true)
            : milliseconds(currentFirstPacketToPresentationMilliseconds)))
        if detailed {
            lines.append(.init("end-to-end", "Host → display (estimated)", milliseconds(estimatedHostToDisplayMilliseconds)))
        }
        return lines
    }
    private func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return String(format: "%.2f ms", value)
    }
    private func duration(_ summary: StreamTimingSummary?, detailed: Bool) -> String {
        guard let summary else { return "Unavailable" }
        if detailed {
            return String(format: "%.2f / %.2f / %.2f ms", summary.minimumMilliseconds, summary.maximumMilliseconds, summary.averageMilliseconds)
        }
        return milliseconds(summary.averageMilliseconds)
    }
}
