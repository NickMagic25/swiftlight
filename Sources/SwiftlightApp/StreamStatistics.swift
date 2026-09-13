import Foundation
import SwiftlightCore
import SwiftlightTransport
import SwiftlightVideo

extension ClientModel {
    /// Samples at the existing 4 Hz UI cadence. Native media callbacks only update
    /// bounded counters; hidden statistics cause no additional SwiftUI publication.
    func refreshStreamStatistics() {
        guard let pipeline, let transport else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = StreamStatisticsSnapshot()
        if let request = statisticsRequest {
            snapshot.requestedVideo = "\(request.size.width) × \(request.size.height) · \(request.fps) Hz"
        }
        if let selection = statisticsSelection {
            snapshot.requestedFormat = "\(selection.codec.rawValue.uppercased()) · \(selection.hdr ? "HDR10 · 10-bit · Rec.2020" : "SDR · 8-bit · Rec.709") · Limited"
        }
        if let negotiated = pipeline.streamDescription {
            // common-c setup echoes requested size/FPS; only its codec is
            // negotiated. Observed geometry and frame rate come from below.
            snapshot.negotiatedVideo = "\(negotiated.isAV1 ? "AV1" : "HEVC") · \(negotiated.bitDepth)-bit"
        }
        if let format = pipeline.decodedFormat {
            snapshot.receivedSize = PixelSize(format.width, format.height)
            snapshot.decodedColor = "\(format.bitDepth)-bit · \(colorDescription(format.color))"
        }
        if let diagnostics = transport.diagnostics {
            let video = diagnostics.video
            snapshot.receivedFramesPerSecond = statisticsRateWindow.record(receivedFrames: video.receivedFrames, at: now)
            snapshot.networkRoundTrip = statisticsNetworkWindow.record(diagnostics.rttMilliseconds.map(Double.init), at: now)
            snapshot.hostProcessing = video.hostProcessingLatency.flatMap {
                StreamTimingSummary(sampleCount: Int(clamping: $0.sampleCount), minimum: $0.minimumMilliseconds,
                                    maximum: $0.maximumMilliseconds, average: $0.averageMilliseconds)
            }
            snapshot.networkJitterMilliseconds = video.frameArrivalJitterMilliseconds
            snapshot.networkLostFrames = video.networkLostFrames
            snapshot.totalNetworkFrames = video.totalFrames
        }
        if let decoder = pipeline.statistics { snapshot.decodeTime = summarize(decoder.decodeTime) }
        if let renderer = pipeline.renderStatistics {
            snapshot.firstPacketToPresentation = summarize(renderer.firstPacketToPresentation)
            snapshot.currentFirstPacketToPresentationMilliseconds = renderer.currentFirstPacketToPresentationMilliseconds()
            snapshot.hostProcessingAndClientPresentation = summarize(renderer.hostProcessingAndClientPresentation)
        }
        streamStatisticsSnapshot = snapshot
        diagnosticTimeline?.record(snapshot, phase: state.phase.rawValue, uptime: now)
        guard showingStreamStatistics else { return }
        if statisticsPreferences.detail == .simple {
            // Sample the latest presented frame every five seconds. Detailed rows and exported
            // diagnostics continue to use the current measured snapshot.
            if let held = simplePresentationSample, now >= held.time, now - held.time < 5 {
                snapshot.currentFirstPacketToPresentationMilliseconds = held.milliseconds
            } else {
                simplePresentationSample = (now, snapshot.currentFirstPacketToPresentationMilliseconds)
            }
        }
        let rows = snapshot.lines(detail: statisticsPreferences.detail).map { StreamStatisticRow(id: $0.id, label: $0.label, value: $0.value) }
        if rows != streamStatisticRows { streamStatisticRows = rows }
    }
    private func summarize(_ timing: SwiftlightVideo.TimingSummary) -> StreamTimingSummary? {
        guard let minimum = timing.minimumMilliseconds, let maximum = timing.maximumMilliseconds,
              let average = timing.averageMilliseconds else { return nil }
        return StreamTimingSummary(sampleCount: timing.count, minimum: minimum, maximum: maximum, average: average)
    }
    private func colorDescription(_ color: VideoColor) -> String {
        let primaries: String
        switch color.primaries { case 1: primaries = "Rec.709"; case 9: primaries = "Rec.2020"; default: primaries = "Primaries \(color.primaries)" }
        let transfer: String
        switch color.transfer { case 16: transfer = "PQ / HDR10"; case 18: transfer = "HLG"; case 13: transfer = "sRGB"; case 1, 6: transfer = "SDR"; default: transfer = "Transfer \(color.transfer)" }
        let description = color.hasColorDescription ? "\(transfer) · \(primaries)" : "\(transfer) · \(primaries) (assumed)"
        let range = "\(color.fullRange ? "Full" : "Limited")\(color.hasRange ? "" : " (assumed)")"
        return "\(description) · \(range)"
    }
}
