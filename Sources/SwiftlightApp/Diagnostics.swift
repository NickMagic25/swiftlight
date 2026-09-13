import AppKit
import UniformTypeIdentifiers
import SwiftlightVideo

private struct LiveDiagnostics: Encodable {
    let schemaVersion = 1
    let timestamp: Date
    let phase: String
    let requested: String
    let decoded: String
    let power: String
    let decoder: DecoderStatistics?
    let renderer: RenderStatistics?
    let rttMilliseconds: UInt32?
    let rttVarianceMilliseconds: UInt32?
    let interface: String?
    let timingCaveat = "Decoder uptime and CoreAnimation presentation clocks are separate until calibrated. Zero/unavailable presentation is unconfirmed."
}
extension ClientModel {
    func exportDiagnostics() {
        let transportStats = transport?.diagnostics
        let snapshot = LiveDiagnostics(timestamp: Date(), phase: state.phase.rawValue,
            requested: streamDetail, decoded: decodedDetail, power: powerDetail,
            decoder: pipeline?.statistics, renderer: pipeline?.renderStatistics,
            rttMilliseconds: transportStats?.rttMilliseconds,
            rttVarianceMilliseconds: transportStats?.rttVarianceMilliseconds, interface: transportStats?.interfaceName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(snapshot)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "swiftlight-diagnostics.json"
            panel.begin { [weak self] result in
                guard result == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) }
                catch { self?.message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}
