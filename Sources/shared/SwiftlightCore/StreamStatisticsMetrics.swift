import Foundation

public struct StreamTimingSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let minimumMilliseconds: Double
    public let maximumMilliseconds: Double
    public let averageMilliseconds: Double
    public init?(sampleCount: Int, minimum: Double, maximum: Double, average: Double) {
        let tolerance = max(1e-9, abs(maximum) * 1e-12)
        guard sampleCount > 0, minimum.isFinite, maximum.isFinite, average.isFinite,
              minimum >= 0, maximum >= minimum, average >= minimum - tolerance, average <= maximum + tolerance else { return nil }
        self.sampleCount = sampleCount; minimumMilliseconds = minimum
        maximumMilliseconds = maximum; averageMilliseconds = min(maximum, max(minimum, average))
    }
    public init?(samples: [Double]) {
        let valid = samples.filter { $0.isFinite && $0 >= 0 }
        guard let minimum = valid.min(), let maximum = valid.max() else { return nil }
        self.init(sampleCount: valid.count, minimum: minimum, maximum: maximum,
                  average: valid.reduce(0) { $0 + $1 / Double(valid.count) })
    }
}

/// Bounded recent RTT polls; zero is a valid low-latency result, nil is absent.
public struct StreamTimingWindow: Sendable {
    private var samples: [(time: TimeInterval, milliseconds: Double)] = []
    public init() {}
    public mutating func record(_ milliseconds: Double?, at time: TimeInterval) -> StreamTimingSummary? {
        guard time.isFinite else { return nil }
        if let last = samples.last, time < last.time { samples.removeAll(keepingCapacity: true) }
        samples.removeAll { time - $0.time > 5 }
        if let milliseconds, milliseconds.isFinite, milliseconds >= 0 {
            if samples.count == 64 { samples.removeFirst() }
            samples.append((time, milliseconds))
        }
        return StreamTimingSummary(samples: samples.map(\.milliseconds))
    }
}

/// Counter deltas measure delivered complete-frame rate, never the requested FPS.
public struct StreamFrameRateWindow: Sendable {
    private var samples: [(time: TimeInterval, count: UInt64)] = []
    public init() {}
    public mutating func record(receivedFrames: UInt64, at time: TimeInterval) -> Double? {
        guard time.isFinite else { return nil }
        if let last = samples.last, time <= last.time || time - last.time > 5 || receivedFrames < last.count {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append((time, receivedFrames))
        while samples.count > 2 && time - samples[1].time >= 5 { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        guard let first = samples.first, time - first.time >= 0.5 else { return nil }
        return Double(receivedFrames - first.count) / (time - first.time)
    }
}
