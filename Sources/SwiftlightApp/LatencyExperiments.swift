#if DEBUG
import Foundation
import SwiftlightCore
import SwiftlightHost
import os

extension ClientModel {
    var latencyExperimentsRunning: Bool { LatencyExperimentRunner.shared.isRunning(for: self) }

    /// Runs against the selected computer's Desktop app without changing its saved profile.
    func runLatencyExperiments(short: Bool = false) {
        LatencyExperimentRunner.shared.start(model: self, short: short)
    }

    /// Isolates statistics composition with identical HDR, pacing, and HUD options.
    func runStatisticsOverlayComparison() {
        LatencyExperimentRunner.shared.start(model: self, short: false, statisticsOverlay: true)
    }

    func cancelLatencyExperiments() { LatencyExperimentRunner.shared.cancel(model: self) }
}

/// Owns one comparison sequence independently of SwiftUI view reconstruction. The
/// stream generation distinguishes this runner's connection from a manual reconnect.
@MainActor private final class LatencyExperimentRunner {
    static let shared = LatencyExperimentRunner()
    private var task: Task<Void, Never>?
    private weak var model: ClientModel?
    private let logger = Logger(subsystem: "net.edrisil.swiftlight", category: "LatencyExperiments")

    private struct Comparison {
        let label: String
        let cachesMetadata: Bool
        let drawableCount: Int
        var showsStatistics = false
        var nativePQ = false
        var metalHUD = false
        var captureScheduled = true
        var configureBefore = false
        var rootMetalLayer = false
        var hideEmptyOverlay = false
        var swiftUIStatistics = false
    }

    private struct DisplayConfiguration: Equatable {
        let width: Int
        let height: Int
        let refreshHz: Double
    }

    private enum ExperimentError: LocalizedError {
        case stopped(String)
        var errorDescription: String? {
            switch self { case .stopped(let reason): reason }
        }
    }

    func isRunning(for model: ClientModel) -> Bool { task != nil && self.model === model }

    func start(model: ClientModel, short: Bool, statisticsOverlay: Bool = false) {
        guard task == nil else { return }
        guard !model.busy, let hostID = model.selectedHostID,
              let desktop = model.apps.first(where: { $0.name.caseInsensitiveCompare("Desktop") == .orderedSame }) else {
            model.message = "Select a connected computer with a Desktop app before running latency comparisons."
            return
        }
        guard !model.isSessionActive || model.activeApp?.id == desktop.id else {
            model.message = "Disconnect the current application before running Desktop latency comparisons."
            return
        }
        self.model = model
        task = Task { [weak self, weak model] in
            guard let self, let model else { self?.task = nil; return }
            await self.run(model: model, hostID: hostID, desktop: desktop, short: short, statisticsOverlay: statisticsOverlay)
            self.task = nil; self.model = nil
            model.objectWillChange.send()
        }
        model.objectWillChange.send()
    }

    func cancel(model: ClientModel) {
        guard self.model === model else { return }
        task?.cancel()
    }

    private func run(model: ClientModel, hostID: String, desktop: RemoteApp, short: Bool, statisticsOverlay: Bool) async {
        let originalSettings = model.settings
        let originalOptions = model.renderOptions
        let prefix = statisticsOverlay ? "statistics-overlay" : "comparison"
        let runID = "\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        let allCases = [
            Comparison(label: "legacy-scheduled-on-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true),
            Comparison(label: "legacy-scheduled-off-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true, captureScheduled: false),
            Comparison(label: "per-frame-before-acquire-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true, captureScheduled: false, configureBefore: true),
            Comparison(label: "legacy-no-empty-overlay-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true, captureScheduled: false, hideEmptyOverlay: true),
            Comparison(label: "legacy-root-layer-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true, captureScheduled: false, rootMetalLayer: true, hideEmptyOverlay: true),
            Comparison(label: "native-pq-root-layer-hud", cachesMetadata: true, drawableCount: 3, nativePQ: true, metalHUD: true, captureScheduled: false, rootMetalLayer: true, hideEmptyOverlay: true)
        ]
        let statisticsCases = [
            Comparison(label: "hidden-baseline-legacy-hdr-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true),
            Comparison(label: "swiftui-stats-legacy-hdr-hud", cachesMetadata: false, drawableCount: 3,
                       showsStatistics: true, metalHUD: true, swiftUIStatistics: true),
            Comparison(label: "metal-stats-legacy-hdr-hud", cachesMetadata: false, drawableCount: 3,
                       showsStatistics: true, metalHUD: true),
            Comparison(label: "hidden-repeat-legacy-hdr-hud", cachesMetadata: false, drawableCount: 3, metalHUD: true)
        ]
        let comparisons = statisticsOverlay ? statisticsCases : (short ? Array(allCases.prefix(3)) : allCases)
        let checkpoints = statisticsOverlay ? [10, 20, 30] : [10, 30, 50]
        var ownedGeneration: UInt64?
        var referenceDisplay: DisplayConfiguration?
        var completed = 0
        var resultMessage: String

        do {
            try Task.checkCancellation()
            if model.isSessionActive { model.disconnect() }
            await model.waitForStreamTeardown()
            try Task.checkCancellation()

            for (index, comparison) in comparisons.enumerated() {
                try Task.checkCancellation()
                guard model.selectedHostID == hostID, !model.isSessionActive, !model.busy else {
                    throw ExperimentError.stopped("The selected computer or connection changed.")
                }
                var settings = originalSettings
                settings.videoPacing = .immediate
                settings.displaySyncEnabled = false
                settings.maximumDrawableCount = comparison.drawableCount
                settings.launchInFullScreen = true
                model.settings = settings
                var options = originalOptions
                options.cacheEDRMetadata = comparison.cachesMetadata
                options.nativePQOutput = comparison.nativePQ
                options.showMetalHUD = comparison.metalHUD
                options.captureScheduledCallback = comparison.captureScheduled
                options.configureEDRBeforeAcquire = comparison.configureBefore
                options.useRootMetalLayer = comparison.rootMetalLayer
                options.hideEmptyOverlayContainer = comparison.hideEmptyOverlay
                options.useSwiftUIStatisticsOverlay = comparison.swiftUIStatistics
                model.renderOptions = options
                model.showingStreamStatistics = false
                model.launch(desktop)
                guard model.isSessionActive else {
                    throw ExperimentError.stopped("The Desktop connection could not start.")
                }
                let generation = model.state.generation
                ownedGeneration = generation
                let connectionDeadline = ContinuousClock.now.advanced(by: .seconds(45))
                while model.state.phase != .streaming {
                    try validateConnection(model, hostID: hostID, generation: generation, settings: settings)
                    guard ContinuousClock.now < connectionDeadline else {
                        throw ExperimentError.stopped("The Desktop connection did not begin streaming within 45 seconds.")
                    }
                    try await pause()
                }
                try Task.checkCancellation()
                model.showingStreamStatistics = comparison.showsStatistics
                model.refreshStreamStatistics()
                model.hostStatus = "Latency comparison \(index + 1) of \(comparisons.count)"
                logger.info("Starting \(runID, privacy: .public) case \(index + 1): \(comparison.label, privacy: .public)")
                let streamingStart = ContinuousClock.now

                // Ten seconds of warmup, then two additional measured windows.
                // Captures contain bounded recent frames and occur while streaming.
                for seconds in checkpoints {
                    let deadline = streamingStart.advanced(by: .seconds(seconds))
                    while ContinuousClock.now < deadline {
                        try validateConnection(model, hostID: hostID, generation: generation, settings: settings,
                                               showsStatistics: comparison.showsStatistics)
                        try await pause()
                    }
                    try validateConnection(model, hostID: hostID, generation: generation, settings: settings,
                                           showsStatistics: comparison.showsStatistics)
                    guard let runtime = model.pipeline?.presentationDiagnostics, runtime.nativeFullScreen else {
                        throw ExperimentError.stopped("The comparison requires the stream to remain in full screen.")
                    }
                    guard model.inputCaptured else {
                        throw ExperimentError.stopped("Input capture was released; stream controls would overlap the video.")
                    }
                    let display = DisplayConfiguration(width: runtime.drawableWidth, height: runtime.drawableHeight,
                                                       refreshHz: runtime.displayRefreshHz)
                    if let referenceDisplay, display != referenceDisplay {
                        throw ExperimentError.stopped("The display size or refresh rate changed during the comparisons.")
                    }
                    referenceDisplay = display
                    let visibility = model.showingStreamStatistics ? "visible" : "hidden"
                    let label = "\(runID)-\(index + 1)-\(comparison.label)-\(seconds)s-stats-\(visibility)"
                    _ = try model.writeLatencyExperimentSnapshot(label: label)
                    logger.info("Captured \(label, privacy: .public)")
                }
                model.disconnect()
                ownedGeneration = nil
                await model.waitForStreamTeardown()
                try Task.checkCancellation()
                completed += 1
            }
            resultMessage = "Completed \(completed) latency comparisons. Captures are in the Application Support/Swiftlight/LatencyExperiments folder. Desktop remains running on the host."
        } catch is CancellationError {
            resultMessage = "Latency comparisons canceled after \(completed) completed runs. Existing captures were retained."
        } catch {
            resultMessage = "Latency comparisons stopped after \(completed) completed runs: \(error.localizedDescription)"
        }

        // Canceling this Task must not cancel or skip native teardown. Only stop
        // the connection we created; a user-started replacement belongs to them.
        if let ownedGeneration, model.state.generation == ownedGeneration, model.isSessionActive {
            model.disconnect()
        }
        await model.waitForStreamTeardown()
        if model.selectedHostID == hostID { model.settings = originalSettings }
        model.renderOptions = originalOptions
        model.message = resultMessage
        logger.info("\(resultMessage, privacy: .public)")
    }

    private func validateConnection(_ model: ClientModel, hostID: String, generation: UInt64,
                                    settings: StreamSettings, showsStatistics: Bool? = nil) throws {
        try Task.checkCancellation()
        guard model.selectedHostID == hostID, model.state.generation == generation,
              [.connecting, .negotiating, .streaming].contains(model.state.phase) else {
            throw ExperimentError.stopped("The stream ended or the connection changed.")
        }
        guard model.settings == settings else {
            throw ExperimentError.stopped("Stream settings changed during the comparison.")
        }
        if let showsStatistics, model.showingStreamStatistics != showsStatistics {
            throw ExperimentError.stopped("Statistics visibility changed during the comparison.")
        }
    }

    private func pause() async throws {
        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
    }
}
#endif
