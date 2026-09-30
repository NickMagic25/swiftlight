#if os(macOS)
import Foundation
import SwiftlightCore

extension ClientModel {
    /// Samples at the existing 4 Hz UI cadence. Native media callbacks only update
    /// bounded counters; hidden statistics cause no additional SwiftUI publication.
    func refreshStreamStatistics() {
        guard let pipeline, let transport else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = statisticsSampler.sample(request: statisticsRequest, selection: statisticsSelection,
            negotiated: pipeline.streamDescription, decodedFormat: pipeline.decodedFormat,
            diagnostics: transport.diagnostics, decoder: pipeline.statistics, renderer: pipeline.renderStatistics,
            uptime: now)
        streamStatisticsSnapshot = snapshot
        diagnosticTimeline?.record(snapshot, phase: state.phase.rawValue, uptime: now)
        guard showingStreamStatistics else { return }
        let rows = statisticsSampler.rows(for: snapshot, detail: statisticsPreferences.detail, uptime: now)
        if rows != streamStatisticRows { streamStatisticRows = rows }
    }
}

#endif
