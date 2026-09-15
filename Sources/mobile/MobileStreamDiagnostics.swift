#if os(iOS)
import Darwin
import Foundation
import QuartzCore
import SwiftlightCore
import SwiftlightTransport
import SwiftlightVideo
import UIKit
import os

/// Explicit debug trials reuse the renderer's bounded scalar timing records.
/// No media callback, UI publication, or normal-release polling is added.
@MainActor final class MobileStreamDiagnostics {
    static func makeIfEnabled(settings: StreamSettings) -> MobileStreamDiagnostics? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFTLIGHT_LATENCY_CAPTURE"] == "1",
              let trial = environment["SWIFTLIGHT_LATENCY_TRIAL"],
              ["baseline-off", "baseline-on", "candidate-off", "candidate-on"].contains(trial) else { return nil }
        return MobileStreamDiagnostics(settings: settings, trial: trial, environment: environment)
        #else
        return nil
        #endif
    }

    #if DEBUG
    private let settings: StreamSettings
    private let trial: String
    private let runID = UUID().uuidString
    private let sourceRevision: String?
    private let sourceTreeSHA256: String?
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private var timeline = StreamDiagnosticTimeline()
    private var firstPresentationSeconds: Double?
    private var nextInspectionSeconds = 0.0
    private var sampleCount = 0
    private var finished = false
    private var pendingWrite: Task<Void, Never>?
    private var observedPresentationState: PresentationState?
    private var presentationStateChangedSeconds: Double?
    private struct PresentationState: Equatable {
        let statisticsVisible: Bool
        let controlsVisible: Bool
        let inputEnabled: Bool
    }
    private static let warmupSeconds = 10.0
    private static let checkpoints = [20.0, 30.0, 40.0]

    private init(settings: StreamSettings, trial: String, environment: [String: String]) {
        self.settings = settings; self.trial = trial
        sourceRevision = Self.hexadecimal(environment["SWIFTLIGHT_LATENCY_SOURCE_REVISION"], lengths: [40, 64])
        sourceTreeSHA256 = Self.hexadecimal(environment["SWIFTLIGHT_LATENCY_SOURCE_TREE_SHA256"], lengths: [64])
    }

    private static func hexadecimal(_ value: String?, lengths: [Int]) -> String? {
        guard let value, lengths.contains(value.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return value.lowercased()
    }
    #endif

    func recordIfDue(pipeline: StreamingPipeline?, transport: StreamTransport?, request: StreamRequest?,
                     stream: StreamStatisticsSnapshot, statisticsOverlayVisible: Bool,
                     controlsVisible: Bool, inputEnabled: Bool,
                     statisticsPreferences: StreamStatisticsPreferences? = nil) {
        #if DEBUG
        guard !finished, sampleCount < Self.checkpoints.count else { return }
        let now = CACurrentMediaTime()
        observePresentationState(statisticsVisible: statisticsOverlayVisible, controlsVisible: controlsVisible,
                                 inputEnabled: inputEnabled, now: now)
        guard now >= nextInspectionSeconds else { return }
        if let firstPresentationSeconds {
            guard now - firstPresentationSeconds >= Self.checkpoints[sampleCount] else { return }
        }
        // Before the first confirmed presentation, inspect no more than once a
        // second. Once armed, only the three scheduled checkpoints take snapshots.
        nextInspectionSeconds = now + 1
        guard let renderer = pipeline?.renderStatistics else { return }
        if firstPresentationSeconds == nil {
            firstPresentationSeconds = renderer.presentationTimings
                .filter { $0.actualPresentationNanoseconds > 0 }
                .map { Double($0.actualPresentationNanoseconds) / 1_000_000_000 }.min()
        }
        guard let firstPresentationSeconds,
              now - firstPresentationSeconds >= Self.checkpoints[sampleCount] else { return }
        capture(pipeline: pipeline, transport: transport, request: request, stream: stream, renderer: renderer,
                statisticsOverlayVisible: statisticsOverlayVisible, controlsVisible: controlsVisible,
                inputEnabled: inputEnabled, statisticsPreferences: statisticsPreferences,
                phase: "streaming", terminal: false, now: now)
        #endif
    }

    /// Call before clearing visibility, session phase, or native owners. This
    /// freezes scalars immediately; encoding and disk access run off the main actor.
    func finish(pipeline: StreamingPipeline?, transport: StreamTransport?, request: StreamRequest?,
                stream: StreamStatisticsSnapshot, statisticsOverlayVisible: Bool,
                controlsVisible: Bool, inputEnabled: Bool, phase: String,
                statisticsPreferences: StreamStatisticsPreferences? = nil) {
        #if DEBUG
        guard !finished else { return }
        finished = true
        guard sampleCount < Self.checkpoints.count else { return }
        let now = CACurrentMediaTime()
        observePresentationState(statisticsVisible: statisticsOverlayVisible, controlsVisible: controlsVisible,
                                 inputEnabled: inputEnabled, now: now)
        capture(pipeline: pipeline, transport: transport, request: request, stream: stream,
                renderer: pipeline?.renderStatistics, statisticsOverlayVisible: statisticsOverlayVisible,
                controlsVisible: controlsVisible, inputEnabled: inputEnabled,
                statisticsPreferences: statisticsPreferences,
                phase: phase == "streaming" ? "streaming" : "notStreaming", terminal: true, now: now)
        #endif
    }

    /// Optional after teardown when a caller needs the files ready for retrieval.
    func waitForWrites() async {
        #if DEBUG
        await pendingWrite?.value
        #endif
    }

    #if DEBUG
    private func observePresentationState(statisticsVisible: Bool, controlsVisible: Bool, inputEnabled: Bool, now: Double) {
        let value = PresentationState(statisticsVisible: statisticsVisible, controlsVisible: controlsVisible, inputEnabled: inputEnabled)
        if observedPresentationState != value { observedPresentationState = value; presentationStateChangedSeconds = now }
    }

    private func capture(pipeline: StreamingPipeline?, transport: StreamTransport?, request: StreamRequest?,
                         stream: StreamStatisticsSnapshot, renderer: RenderStatistics?,
                         statisticsOverlayVisible: Bool, controlsVisible: Bool, inputEnabled: Bool,
                         statisticsPreferences: StreamStatisticsPreferences?,
                         phase: String, terminal: Bool, now: Double) {
        var renderer = renderer
        let originalPresentationCount = renderer?.presentationTimings.count ?? 0
        let originalCompletionCount = renderer?.completedFrameTimings.count ?? 0
        let cutoff = firstPresentationSeconds.map { max($0, presentationStateChangedSeconds ?? $0) + Self.warmupSeconds }
        if let cutoff {
            renderer?.presentationTimings.removeAll { Double($0.actualPresentationNanoseconds) / 1_000_000_000 < cutoff }
            renderer?.completedFrameTimings.removeAll { ($0.renderStartSeconds ?? -.infinity) < cutoff }
            renderer?.actualPresentationNanoseconds.removeAll { Double($0) / 1_000_000_000 < cutoff }
        }
        let network = transport?.diagnostics
        let decoder = pipeline?.statistics
        // UI statistics intentionally stop refreshing while hidden. Capture fresh
        // scalar totals and timing summaries without publishing or enabling the UI.
        var stream = stream
        stream.networkLostFrames = network?.video.networkLostFrames
        stream.totalNetworkFrames = network?.video.totalFrames
        stream.networkJitterMilliseconds = network?.video.frameArrivalJitterMilliseconds
        stream.hostProcessing = network?.video.hostProcessingLatency.flatMap {
            StreamTimingSummary(sampleCount: Int(clamping: $0.sampleCount), minimum: $0.minimumMilliseconds,
                maximum: $0.maximumMilliseconds, average: $0.averageMilliseconds)
        }
        stream.decodeTime = decoder.flatMap { Self.summarize($0.decodeTime) }
        stream.firstPacketToPresentation = renderer.flatMap { Self.summarize($0.firstPacketToPresentation) }
        stream.currentFirstPacketToPresentationMilliseconds = renderer?.currentFirstPacketToPresentationMilliseconds()
        stream.hostProcessingAndClientPresentation = renderer.flatMap { Self.summarize($0.hostProcessingAndClientPresentation) }
        if !statisticsOverlayVisible { stream.receivedFramesPerSecond = nil; stream.networkRoundTrip = nil }
        let timestamp = Date()
        timeline.record(stream, phase: phase, uptime: ProcessInfo.processInfo.systemUptime)
        var capturedTimeline = timeline
        capturedTimeline.finish(stream, outcome: phase, endedAt: timestamp)
        let capture = MobileLatencyCaptureMetadata(trial: trial, runID: runID, index: sampleCount + 1,
            terminal: terminal, sourceRevision: sourceRevision, sourceTreeSHA256: sourceTreeSHA256,
            sessionElapsedSeconds: ProcessInfo.processInfo.systemUptime - startUptime,
            elapsedSinceFirstPresentationSeconds: firstPresentationSeconds.map { now - $0 },
            scheduledCheckpointSeconds: terminal ? nil : Self.checkpoints[sampleCount],
            warmupSeconds: Self.warmupSeconds, warmupComplete: cutoff.map { now >= $0 } ?? false,
            presentationStateStableSeconds: presentationStateChangedSeconds.map { now - $0 },
            excludedWarmupPresentationRecords: originalPresentationCount - (renderer?.presentationTimings.count ?? 0),
            excludedWarmupOrUntimedCompletionRecords: originalCompletionCount - (renderer?.completedFrameTimings.count ?? 0),
            statisticsVisibilityMatchesTrial: statisticsOverlayVisible == trial.hasSuffix("-on"),
            statisticsPreferences: statisticsPreferences,
            controlsVisible: controlsVisible, deviceModel: Self.deviceModel(),
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            gameModeDeclaredSupported: Bundle.main.object(forInfoDictionaryKey: "LSSupportsGameMode") as? Bool,
            gameModeObserved: nil)
        let snapshot = MobileLatencySnapshot(timestamp: timestamp, phase: phase,
            requested: request.map { "\($0.size.width) × \($0.size.height) · \($0.fps) Hz · \($0.bitrateKbps) kbps" } ?? "Unavailable",
            decoded: pipeline?.decodedDetail ?? "Unavailable", power: Self.thermalDescription(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: settings, timeline: capturedTimeline, decoder: decoder, renderer: renderer,
            presentationRuntime: pipeline?.presentationDiagnostics, statisticsOverlayVisible: statisticsOverlayVisible,
            inputCaptured: inputEnabled, renderOptions: pipeline?.renderOptions, stream: stream,
            rttMilliseconds: network?.rttMilliseconds, rttVarianceMilliseconds: network?.rttVarianceMilliseconds,
            pendingVideoFrames: network?.pendingVideoFrames, pendingAudioMilliseconds: network?.pendingAudioMilliseconds,
            audioQueuedFrames: network?.audioQueuedFrames, audioUnderrunFrames: network?.audioUnderrunFrames,
            audioOverrunFrames: network?.audioOverrunFrames, receivedFrames: network?.video.receivedFrames,
            acquiredFrames: network?.video.acquiredFrames, acquiredBytes: network?.video.acquiredBytes, capture: capture)
        sampleCount += 1
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            await MobileLatencyWriter.shared.write(snapshot)
        }
    }

    private static func deviceModel() -> String {
        var value = utsname()
        guard uname(&value) == 0 else { return "unavailable" }
        return withUnsafeBytes(of: value.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    private static func summarize(_ value: SwiftlightVideo.TimingSummary) -> StreamTimingSummary? {
        guard let minimum = value.minimumMilliseconds, let maximum = value.maximumMilliseconds,
              let average = value.averageMilliseconds else { return nil }
        return StreamTimingSummary(sampleCount: value.count, minimum: minimum, maximum: maximum, average: average)
    }
    private static func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
    #endif
}

#if DEBUG
private struct MobileLatencyCaptureMetadata: Encodable, Sendable {
    let trial: String
    let runID: String
    let index: Int
    let terminal: Bool
    let sourceRevision: String?
    let sourceTreeSHA256: String?
    let sessionElapsedSeconds: Double
    let elapsedSinceFirstPresentationSeconds: Double?
    let scheduledCheckpointSeconds: Double?
    let warmupSeconds: Double
    let warmupComplete: Bool
    let presentationStateStableSeconds: Double?
    let excludedWarmupPresentationRecords: Int
    let excludedWarmupOrUntimedCompletionRecords: Int
    let statisticsVisibilityMatchesTrial: Bool
    let statisticsPreferences: StreamStatisticsPreferences?
    let controlsVisible: Bool
    let deviceModel: String
    let deviceClass: String
    let lowPowerModeEnabled: Bool
    let gameModeDeclaredSupported: Bool?
    let gameModeObserved: Bool?
}

private struct MobileLatencySnapshot: Encodable, Sendable {
    let schemaVersion = 5
    let buildConfiguration = "debug"
    let timestamp: Date
    let phase: String
    let requested: String
    let decoded: String
    let power: String
    let appVersion: String
    let appBuild: String?
    let operatingSystem: String
    let settings: StreamSettings
    let timeline: StreamDiagnosticTimeline
    let decoder: DecoderStatistics?
    let renderer: RenderStatistics?
    let presentationRuntime: PresentationRuntimeDiagnostics?
    let statisticsOverlayVisible: Bool
    let inputCaptured: Bool
    let renderOptions: StreamRenderOptions?
    let stream: StreamStatisticsSnapshot
    let rttMilliseconds: UInt32?
    let rttVarianceMilliseconds: UInt32?
    let pendingVideoFrames: Int?
    let pendingAudioMilliseconds: Int?
    let audioQueuedFrames: UInt64?
    let audioUnderrunFrames: UInt64?
    let audioOverrunFrames: UInt64?
    let receivedFrames: UInt64?
    let acquiredFrames: UInt64?
    let acquiredBytes: UInt64?
    let capture: MobileLatencyCaptureMetadata
    let timingCaveat = "At most 1024 recent records per renderer population, filtered after a 10-second presentation warmup and any observed overlay/control/input-state change; checkpoints can overlap. Same-frame confirmed drawable presentation is not physical scanout. Missing timing fields remain unavailable. Completion samples and decoder windows are independent populations. Captured before teardown; pending callbacks can remain. Timeline contains capture checkpoints only. Game Mode support in the plist does not establish actual activation; verify externally."
}

private actor MobileLatencyWriter {
    static let shared = MobileLatencyWriter()
    private let logger = Logger(subsystem: "net.edrisil.swiftlight", category: "MobileLatencyCapture")
    func write(_ snapshot: MobileLatencySnapshot) {
        do {
            let manager = FileManager.default
            let directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("SwiftlightLatency", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let filename = "mobile-\(Int(snapshot.timestamp.timeIntervalSince1970 * 1000))-\(snapshot.capture.runID)-\(snapshot.capture.index).json"
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent(filename), options: .atomic)
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("mobile-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in files.prefix(max(0, files.count - 32)) { try manager.removeItem(at: old) }
        } catch {
            // Never log arbitrary error descriptions, container paths or host data.
            logger.error("Could not save a mobile latency capture.")
        }
    }
}
#endif

#endif
