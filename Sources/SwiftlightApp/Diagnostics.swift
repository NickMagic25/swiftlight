import AppKit
import UniformTypeIdentifiers
import SwiftlightVideo
import SwiftlightCore

private struct LiveDiagnostics: Encodable {
    let schemaVersion = 3
    let timestamp: Date
    let phase: String
    let requested: String
    let decoded: String
    let power: String
    let appVersion: String
    let operatingSystem: String
    let settings: StreamSettings?
    let failure: String?
    let timeline: StreamDiagnosticTimeline?
    let decoder: DecoderStatistics?
    let renderer: RenderStatistics?
    let stream: StreamStatisticsSnapshot
    let rttMilliseconds: UInt32?
    let rttVarianceMilliseconds: UInt32?
    let interface: String?
    let pendingVideoFrames: Int?
    let pendingAudioMilliseconds: Int?
    let audioQueuedFrames: UInt64?
    let audioUnderrunFrames: UInt64?
    let audioOverrunFrames: UInt64?
    let receivedFrames: UInt64?
    let acquiredFrames: UInt64?
    let acquiredBytes: UInt64?
    let timingCaveat = "Captured before teardown; outstanding media callbacks may not be reflected. Timing summaries use bounded recent populations, not whole-session averages. Timeline samples at most once per second plus a final sample, retaining at most 600 entries. Host-to-display adds half RTT as an estimate; no synchronized host clock or physical scanout measurement."
}
extension ClientModel {
    /// Freeze before clearing native owners or resetting the next connection's state.
    /// One completed attempt stays available while the next stream is running.
    func finishStreamDiagnostics() {
        guard diagnosticTimeline != nil else { return }
        refreshStreamStatistics()
        diagnosticTimeline?.finish(streamStatisticsSnapshot, outcome: state.phase.rawValue)
        do { lastStreamDiagnostics = try diagnosticsData() }
        catch { lastStreamDiagnostics = nil; message = "Could not retain stream diagnostics: \(error.localizedDescription)" }
        diagnosticTimeline = nil
    }

    private func diagnosticsData() throws -> Data {
        let stats = transport?.diagnostics
        let snapshot = LiveDiagnostics(timestamp: Date(), phase: state.phase.rawValue,
            requested: streamDetail, decoded: decodedDetail, power: powerDetail,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: diagnosticSettings, failure: diagnosticFailure, timeline: diagnosticTimeline,
            decoder: pipeline?.statistics, renderer: pipeline?.renderStatistics,
            stream: streamStatisticsSnapshot,
            rttMilliseconds: stats?.rttMilliseconds, rttVarianceMilliseconds: stats?.rttVarianceMilliseconds,
            interface: stats?.interfaceName, pendingVideoFrames: stats?.pendingVideoFrames,
            pendingAudioMilliseconds: stats?.pendingAudioMilliseconds, audioQueuedFrames: stats?.audioQueuedFrames,
            audioUnderrunFrames: stats?.audioUnderrunFrames, audioOverrunFrames: stats?.audioOverrunFrames,
            receivedFrames: stats?.video.receivedFrames, acquiredFrames: stats?.video.acquiredFrames,
            acquiredBytes: stats?.video.acquiredBytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(snapshot)
    }
    func exportDiagnostics() {
        refreshStreamStatistics()
        do { saveDiagnostics(try diagnosticsData(), filename: "swiftlight-live-stream.json") }
        catch { message = error.localizedDescription }
    }
    func exportLastStreamDiagnostics() {
        guard let data = lastStreamDiagnostics else { return }
        saveDiagnostics(data, filename: "swiftlight-last-stream.json")
    }
    private func saveDiagnostics(_ data: Data, filename: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = filename
        panel.title = "Export Stream Diagnostics"
        panel.message = "Contains stream settings, timing and failure counters. No pairing credentials, host addresses, application names, or media are included."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { self?.message = error.localizedDescription }
        }
    }
}
