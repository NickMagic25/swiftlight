import Foundation
import QuartzCore
import SwiftlightCore
import SwiftlightTransport
import SwiftlightVideo

/// Value-only sampling shared by platform session owners. The caller owns the
/// polling cadence, visibility policy, publication and diagnostic timeline.
struct StreamStatisticsSampler {
    private var networkWindow = StreamTimingWindow()
    private var rateWindow = StreamFrameRateWindow()
    private var simplePresentationSample: (time: TimeInterval, milliseconds: Double?)?

    /// Uptime drives interval windows; presentation freshness uses Core Animation's
    /// clock. Keep these inputs distinct instead of assuming equal clock epochs.
    mutating func sample(request: StreamRequest?, selection: CodecSelection?,
                         negotiated: VideoStreamDescription?, decodedFormat: DecodedVideoFormat?,
                         diagnostics: TransportDiagnostics?, decoder: DecoderStatistics?, renderer: RenderStatistics?,
                         uptime: TimeInterval, presentationTime: TimeInterval = CACurrentMediaTime()) -> StreamStatisticsSnapshot {
        var snapshot = StreamStatisticsSnapshot()
        if let request {
            snapshot.requestedVideo = "\(request.size.width) × \(request.size.height) · \(request.fps) Hz"
        }
        if let selection {
            snapshot.requestedFormat = "\(selection.codec.rawValue.uppercased()) · \(selection.hdr ? "HDR10 · 10-bit · Rec.2020" : "SDR · 8-bit · Rec.709") · Limited"
        }
        if let negotiated {
            // Setup echoes requested dimensions/FPS; only its codec is negotiated.
            // Received geometry and frame rate must come from actual output.
            snapshot.negotiatedVideo = "\(negotiated.isAV1 ? "AV1" : "HEVC") · \(negotiated.bitDepth)-bit"
        }
        if let format = decodedFormat {
            snapshot.receivedSize = PixelSize(format.width, format.height)
            snapshot.decodedColor = "\(format.bitDepth)-bit · \(Self.colorDescription(format.color))"
        }
        if let diagnostics {
            let video = diagnostics.video
            snapshot.receivedFramesPerSecond = rateWindow.record(receivedFrames: video.receivedFrames, at: uptime)
            snapshot.networkRoundTrip = networkWindow.record(diagnostics.rttMilliseconds.map(Double.init), at: uptime)
            snapshot.hostProcessing = video.hostProcessingLatency.flatMap {
                StreamTimingSummary(sampleCount: Int(clamping: $0.sampleCount), minimum: $0.minimumMilliseconds,
                                    maximum: $0.maximumMilliseconds, average: $0.averageMilliseconds)
            }
            snapshot.networkJitterMilliseconds = video.frameArrivalJitterMilliseconds
            snapshot.networkLostFrames = video.networkLostFrames
            snapshot.totalNetworkFrames = video.totalFrames
        }
        if let decoder { snapshot.decodeTime = Self.summarize(decoder.decodeTime) }
        if let renderer {
            snapshot.firstPacketToPresentation = Self.summarize(renderer.firstPacketToPresentation)
            snapshot.currentFirstPacketToPresentationMilliseconds = renderer.currentFirstPacketToPresentationMilliseconds(at: presentationTime)
            snapshot.hostProcessingAndClientPresentation = Self.summarize(renderer.hostProcessingAndClientPresentation)
        }
        return snapshot
    }

    /// The five-second Simple hold is presentation-only. Raw snapshots and
    /// Detailed rows retain the current measurement, including an unavailable one.
    mutating func rows(for current: StreamStatisticsSnapshot, detail: StreamStatisticsDetail,
                       uptime: TimeInterval) -> [StreamStatisticRow] {
        var snapshot = current
        if detail == .simple {
            if let held = simplePresentationSample, uptime >= held.time, uptime - held.time < 5 {
                snapshot.currentFirstPacketToPresentationMilliseconds = held.milliseconds
            } else {
                simplePresentationSample = (uptime, snapshot.currentFirstPacketToPresentationMilliseconds)
            }
        }
        return snapshot.lines(detail: detail).map {
            StreamStatisticRow(id: $0.id, label: $0.label, value: $0.value)
        }
    }

    mutating func resetPresentationSample() { simplePresentationSample = nil }

    private static func summarize(_ timing: SwiftlightVideo.TimingSummary) -> StreamTimingSummary? {
        guard let minimum = timing.minimumMilliseconds, let maximum = timing.maximumMilliseconds,
              let average = timing.averageMilliseconds else { return nil }
        return StreamTimingSummary(sampleCount: timing.count, minimum: minimum, maximum: maximum, average: average)
    }

    private static func colorDescription(_ color: VideoColor) -> String {
        let primaries: String
        switch color.primaries { case 1: primaries = "Rec.709"; case 9: primaries = "Rec.2020"; default: primaries = "Primaries \(color.primaries)" }
        let transfer: String
        switch color.transfer { case 16: transfer = "PQ / HDR10"; case 18: transfer = "HLG"; case 13: transfer = "sRGB"; case 1, 6: transfer = "SDR"; default: transfer = "Transfer \(color.transfer)" }
        let description = color.hasColorDescription ? "\(transfer) · \(primaries)" : "\(transfer) · \(primaries) (assumed)"
        let range = "\(color.fullRange ? "Full" : "Limited")\(color.hasRange ? "" : " (assumed)")"
        return "\(description) · \(range)"
    }
}
