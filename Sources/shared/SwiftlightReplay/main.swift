import Foundation
import CryptoKit
import SwiftlightVideo

struct Fixture: Decodable {
    struct Rational: Decodable { let num: Int64; let den: Int64 }
    struct AccessUnit: Decodable {
        let frame_id: UInt64; let offset: Int; let length: Int; let sha256: String
        let pts: Int64?; let random_access: Bool; let expected_display_count: Int
    }
    let schema_version: Int; let codec: VideoCodec; let profile: Int; let bit_depth: Int
    let width: Int; let height: Int; let framing: String; let chroma: String
    let payload_file: String; let payload_sha256: String; let timebase: Rational; let frame_rate: Rational
    let access_units: [AccessUnit]
    let expected_internal_samples: UInt64?
    let expected_show_existing: UInt64?
    let expected_no_display: UInt64?
}

struct ReplayReport: Encodable {
    var status: String = "FAIL"
    var mode: String
    var fixture: String
    var codec: String = "unknown"
    var profile = 0
    var bitDepth = 0
    var width = 0
    var height = 0
    var fixtureSHA256 = ""
    var message = ""
    var decoder: DecoderStatistics?
    var renderer: RenderStatistics?
    var comparisons: [RenderComparison] = []
    var retainedBufferAfterDestroy = false
    var resetAccounting = false
    var hardwareValidated = false
    var frameOwnership: FrameOwnershipStatistics?
    var timingDistributions: [String: TimingDistribution] = [:]
    var presentationEvidence = "Offscreen replay does not measure display presentation or network latency."
}

struct TimingDistribution: Encodable {
    let samples: Int
    let medianMilliseconds: Double?
    let p95Milliseconds: Double?
    let p99Milliseconds: Double?
    let maximumMilliseconds: Double?
    init(_ values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        samples = sorted.count
        func percentile(_ fraction: Double) -> Double? {
            sorted.isEmpty ? nil : sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        medianMilliseconds = percentile(0.5); p95Milliseconds = percentile(0.95)
        p99Milliseconds = percentile(0.99); maximumMilliseconds = sorted.last
    }
}

enum ReplayError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let message) = self { message } else { "Invalid replay" } }
}

func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

func run(manifestURL: URL, mode: String, report: inout ReplayReport) throws {
    let manifestData = try Data(contentsOf: manifestURL)
    guard manifestData.count <= 8 * 1024 * 1024 else { throw ReplayError.invalid("Manifest exceeds 8 MiB") }
    let fixture = try JSONDecoder().decode(Fixture.self, from: manifestData)
    report.codec = fixture.codec.rawValue; report.profile = fixture.profile; report.bitDepth = fixture.bit_depth
    report.width = fixture.width; report.height = fixture.height; report.fixtureSHA256 = digest(manifestData)
    guard fixture.schema_version == 1, [8, 10].contains(fixture.bit_depth), fixture.chroma == "420",
          fixture.width > 0, fixture.height > 0, fixture.width <= 8192, fixture.height <= 8192,
          fixture.timebase.num > 0, fixture.timebase.den > 0, fixture.frame_rate.num > 0, fixture.frame_rate.den > 0,
          fixture.access_units.count > 0, fixture.access_units.count <= 10000, fixture.access_units[0].random_access,
          fixture.framing == (fixture.codec == .hevc ? "hevc-annex-b" : "av1-low-overhead-obu") else {
        throw ReplayError.invalid("Unsupported fixture schema, framing, dimensions, or initial random-access point")
    }
    let base = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let payloadURL = base.appendingPathComponent(fixture.payload_file).resolvingSymlinksInPath()
    guard payloadURL.path.hasPrefix(base.path + "/") else { throw ReplayError.invalid("Payload escapes fixture directory") }
    let attributes = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
    guard let fileSize = attributes[.size] as? NSNumber, fileSize.uint64Value <= 2 * 1024 * 1024 * 1024 else { throw ReplayError.invalid("Payload exceeds 2 GiB") }
    let payload = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
    guard digest(payload) == fixture.payload_sha256 else { throw ReplayError.invalid("Payload SHA-256 mismatch") }
    var identities = Set<UInt64>(), end = 0
    for unit in fixture.access_units {
        guard identities.insert(unit.frame_id).inserted, unit.offset == end, unit.length > 0,
              unit.length <= 64 * 1024 * 1024, unit.offset >= 0, unit.offset <= payload.count,
              unit.length <= payload.count - unit.offset, (0...1).contains(unit.expected_display_count) else { throw ReplayError.invalid("Invalid AU identity, length, bounds, or display count") }
        end += unit.length
        guard digest(payload.subdata(in: unit.offset..<end)) == unit.sha256 else { throw ReplayError.invalid("AU SHA-256 mismatch") }
    }
    guard end == payload.count else { throw ReplayError.invalid("Unaccounted trailing payload") }
    guard fixture.codec.hardwareCandidate else {
        report.status = "BLOCKED"; throw ReplayError.invalid("Hardware \(fixture.codec.rawValue) candidate unavailable on this device")
    }
    let decoder = try VideoDecoder(codec: fixture.codec)
    let renderer = try MetalVideoRenderer()
    let pacedTarget = mode == "paced" ? try renderer.makeReadbackTarget(width: fixture.width, height: fixture.height) : nil
    defer { report.decoder = decoder.statistics; report.renderer = renderer.statistics; try? decoder.close() }
    var retained: DecodedFrame?
    let started = VideoDecoder.monotonicNanoseconds
    for (index, unit) in fixture.access_units.enumerated() {
        let ptsValue = Double(unit.pts ?? Int64(index)) * Double(fixture.timebase.num) / Double(fixture.timebase.den) * 1_000_000_000
        guard ptsValue.isFinite, ptsValue >= Double(Int64.min), ptsValue < Double(Int64.max) else {
            throw ReplayError.invalid("Fixture timestamp cannot be represented in nanoseconds")
        }
        let pts = Int64(ptsValue)
        // Hidden coded units can share a media timestamp with the following display
        // event. Preserve those arrivals instead of stretching 71 coded units into
        // 71 display periods for a 48-frame AV1 accounting fixture.
        let relativePTS = Double(unit.pts ?? Int64(index)) - Double(fixture.access_units[0].pts ?? 0)
        let relativeNanoseconds = max(0, relativePTS * Double(fixture.timebase.num) / Double(fixture.timebase.den) * 1_000_000_000)
        guard relativeNanoseconds.isFinite, relativeNanoseconds <= 3_600_000_000_000 else {
            throw ReplayError.invalid("Fixture arrival timeline exceeds the one-hour replay bound")
        }
        let arrival = started + UInt64(relativeNanoseconds)
        if mode == "paced" {
            let now = VideoDecoder.monotonicNanoseconds
            if arrival > now { Thread.sleep(forTimeInterval: Double(arrival - now) / 1_000_000_000) }
        }
        let input = CompressedFrame(bytes: payload.subdata(in: unit.offset..<(unit.offset + unit.length)), id: unit.frame_id,
            presentationTimeNanoseconds: pts, randomAccess: unit.random_access,
            arrivalNanoseconds: mode == "paced" ? arrival : 0)
        var result = decoder.submit(input)
        if result == .wouldBlock {
            // Capacity pressure leaves this AU unconsumed. Drain also handles pending
            // format changes; correctness may block, production uses its worker.
            try decoder.drain(); result = decoder.submit(input)
        }
        guard result == .accepted else { throw ReplayError.invalid("AU \(unit.frame_id) rejected: \(result)") }
        if mode == "correctness" {
            try decoder.drain()
            guard decoder.statistics.terminalIDs.last == unit.frame_id else { throw ReplayError.invalid("Terminal identity mismatch") }
            let frame = decoder.takeLatestFrame()
            if unit.expected_display_count == 1 {
                guard let frame, frame.id == unit.frame_id, frame.width == fixture.width, frame.height == fixture.height,
                      frame.bitDepth == fixture.bit_depth, frame.hardwareAccelerated else { throw ReplayError.invalid("Missing or mismatched hardware output for AU \(unit.frame_id)") }
                let comparison = try VideoReadbackValidator.compare(frame: frame, renderer: renderer)
                report.comparisons.append(comparison)
                guard comparison.passed else { throw ReplayError.invalid("Production shader/readback differs from CPU reference: \(comparison.maximumAbsoluteError)") }
                retained = frame
            } else if frame != nil { throw ReplayError.invalid("Unexpected display for no-display AU") }
        } else if let frame = decoder.takeLatestFrame(), let target = pacedTarget {
            _ = try renderer.render(frame, into: target)
            retained = frame
        }
    }
    try decoder.drain()
    try renderer.waitUntilIdleForValidation()
    if mode == "paced", let final = decoder.takeLatestFrame() { retained = final; _ = try VideoReadbackValidator.compare(frame: final, renderer: renderer) }
    let state = decoder.statistics
    guard state.accepted == UInt64(fixture.access_units.count), state.completed == state.accepted, state.failed == 0,
          state.cancelled == 0, state.outstanding == 0,
          state.output == UInt64(fixture.access_units.reduce(0) { $0 + $1.expected_display_count }) else {
        throw ReplayError.invalid("Terminal or display accounting mismatch: \(state.accepted) accepted, \(state.completed) completed, \(state.failed) failed")
    }
    if let expected = fixture.expected_internal_samples, state.internalSamples != expected { throw ReplayError.invalid("Internal sample accounting mismatch") }
    if let expected = fixture.expected_show_existing, state.showExisting != expected { throw ReplayError.invalid("Show-existing accounting mismatch") }
    if let expected = fixture.expected_no_display, state.noDisplay != expected { throw ReplayError.invalid("Hidden/no-display accounting mismatch") }
    try decoder.reset()
    report.resetAccounting = decoder.statistics.accepted == decoder.statistics.completed && decoder.takeLatestFrame() == nil
    try decoder.close()
    if let retained {
        let comparison = try VideoReadbackValidator.compare(frame: retained, renderer: renderer)
        report.retainedBufferAfterDestroy = comparison.passed
    }
    guard report.resetAccounting, report.retainedBufferAfterDestroy else { throw ReplayError.invalid("Reset/destroy retention validation failed") }
    report.hardwareValidated = state.hardwareValidated
    report.status = "PASS"
    report.message = "Hardware decoding, exact terminal accounting, canonical Metal shader/readback, and retained output after destruction validated."
    retained = nil
    try renderer.waitUntilIdleForValidation()
}

let arguments = Array(CommandLine.arguments.dropFirst())
func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
guard let fixture = argument("--fixture") else {
    print("Usage: swiftlight-replay --fixture fixtures/hevc-sdr8/manifest.json [--mode correctness|paced] [--output artifacts/replay.json]")
    exit(2)
}
let mode = argument("--mode") ?? "correctness"
var report = ReplayReport(mode: mode, fixture: fixture)
do {
    guard ["correctness", "paced"].contains(mode) else { throw ReplayError.invalid("Unknown replay mode") }
    try run(manifestURL: URL(fileURLWithPath: fixture), mode: mode, report: &report)
} catch { report.message = String(describing: error) }
report.frameOwnership = DecodedFrame.ownershipStatistics
if let decoder = report.decoder {
    report.timingDistributions["admissionToTerminal"] = TimingDistribution(decoder.admissionToTerminalMilliseconds)
    report.timingDistributions["singleSampleVTSubmitToCallback"] = TimingDistribution(decoder.singleSampleVTSubmitToCallbackMilliseconds)
}
if let renderer = report.renderer { report.timingDistributions["offscreenGPUExecution"] = TimingDistribution(renderer.gpuMilliseconds) }
if report.status == "PASS", report.frameOwnership?.live != 0 { report.status = "FAIL"; report.message = "Retained frame owner leaked after GPU completion and teardown" }
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let encoded = try encoder.encode(report)
if let path = argument("--output") {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded.write(to: url, options: .atomic)
}
print("\(report.status) \(report.codec) \(report.bitDepth)-bit \(report.width)x\(report.height) [\(mode)]: \(report.message)")
if let state = report.decoder { print("accepted=\(state.accepted) completed=\(state.completed) output=\(state.output) noDisplay=\(state.noDisplay) outstanding=\(state.outstanding) mailboxPeak=\(state.mailboxHighWater)") }
if argument("--output") == nil { print(String(decoding: encoded, as: UTF8.self)) }
exit(report.status == "PASS" ? 0 : 1)
