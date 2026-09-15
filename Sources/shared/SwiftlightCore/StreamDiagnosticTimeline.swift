import Foundation

/// A bounded one-second history, independent of UI visibility and wall-clock changes.
public struct StreamDiagnosticTimeline: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public let elapsedSeconds: Double
        public let phase: String
        public let statistics: StreamStatisticsSnapshot
    }
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var durationSeconds: Double?
    public private(set) var outcome: String?
    public private(set) var samples: [Sample] = []
    public private(set) var discardedSamples = 0
    private let startUptime: Double
    private var lastSampleUptime: Double?
    public static let maximumSamples = 600

    public init(startedAt: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.startedAt = startedAt; startUptime = uptime
    }
    public mutating func record(_ statistics: StreamStatisticsSnapshot, phase: String, uptime: Double) {
        guard endedAt == nil, uptime.isFinite, uptime >= startUptime,
              lastSampleUptime.map({ uptime - $0 >= 1 }) ?? true else { return }
        append(statistics, phase: phase, uptime: uptime)
    }
    public mutating func finish(_ statistics: StreamStatisticsSnapshot, outcome: String,
                                endedAt: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard self.endedAt == nil else { return }
        if uptime.isFinite, uptime >= startUptime {
            durationSeconds = uptime - startUptime
            append(statistics, phase: outcome, uptime: uptime)
        }
        self.endedAt = endedAt; self.outcome = outcome
    }
    private mutating func append(_ statistics: StreamStatisticsSnapshot, phase: String, uptime: Double) {
        samples.append(Sample(elapsedSeconds: uptime - startUptime, phase: phase, statistics: statistics))
        lastSampleUptime = uptime
        if samples.count > Self.maximumSamples {
            discardedSamples += samples.count - Self.maximumSamples
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }
    private enum CodingKeys: String, CodingKey {
        case startedAt, endedAt, durationSeconds, outcome, samples, discardedSamples, startUptime, lastSampleUptime
    }
}
