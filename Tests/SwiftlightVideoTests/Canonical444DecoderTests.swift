import XCTest
import CoreVideo
@testable import SwiftlightVideo

final class Canonical444DecoderTests: XCTestCase {
    func testOlderDecodedFormatExportsKeepSamplingUnavailable() throws {
        let legacy = Data("""
        {"codec":"hevc","width":128,"height":72,"bitDepth":10,"color":{"primaries":9,"transfer":16,"matrix":9,
        "fullRange":false,"chromaLocation":0,"mastering":[],"contentLight":[],"hasColorDescription":true,"hasRange":true}}
        """.utf8)
        let decoded = try JSONDecoder().decode(DecodedVideoFormat.self, from: legacy)
        XCTAssertNil(decoded.chromaFormat, "An older export cannot establish its actual chroma sampling")
        let unknown = DecodedFrame(pixelBuffer: nil, id: 1, width: 128, height: 72, bitDepth: 10,
            color: VideoColor(primaries: 9, transfer: 16, matrix: 9))
        XCTAssertNil(DecodedVideoFormat(codec: .hevc, frame: unknown).chromaFormat)
    }

    func testHEVC4448HardwareDecodeAndRetainedRender() throws { try verify(codec: .hevc, depth: 8, sample: "hevc_rext8_444") }
    func testHEVC44410HardwareDecodeAndRetainedRender() throws { try verify(codec: .hevc, depth: 10, sample: "hevc_rext10_444") }
    func testAV1High4448HardwareAvailabilityAndOutput() throws { try verify(codec: .av1, depth: 8, sample: "av1_high8_444") }
    func testAV1High44410HardwareAvailabilityAndOutput() throws { try verify(codec: .av1, depth: 10, sample: "av1_high10_444") }

    private func verify(codec: VideoCodec, depth: Int, sample: String) throws {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Opt in to actual HEVC range-extension / AV1 High hardware profile checks")
        }
        let supported = DispatchQueue.global(qos: .userInitiated).sync {
            codec.hardwareProfileCandidate(bitDepth: depth, chromaFormat: 3)
        }
        guard supported else {
            throw XCTSkip("\(codec.rawValue.uppercased()) \(depth)-bit 4:4:4 hardware decode is unavailable; generic codec support does not establish this profile")
        }
        let decoder = try VideoDecoder(codec: codec, bitDepth: depth, chromaFormat: 3)
        defer { try? decoder.close() }
        XCTAssertEqual(decoder.submit(CompressedFrame(bytes: try sampleBytes(named: sample), id: 1, randomAccess: true)), .accepted)
        try decoder.drain()
        let frame = try XCTUnwrap(decoder.takeLatestFrame(), decoder.statistics.failureDescription ?? "No canonical 4:4:4 hardware output")
        XCTAssertTrue(frame.hardwareAccelerated)
        XCTAssertEqual(frame.bitDepth, depth)
        XCTAssertEqual(frame.chromaFormat, 3)
        XCTAssertEqual(DecodedVideoFormat(codec: codec, frame: frame).chromaFormat, 3)
        let buffer = try XCTUnwrap(frame.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), 2)
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetWidthOfPlane(buffer, 0))
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 0))
        let renderer = try MetalVideoRenderer()
        let renderFrame: DecodedFrame
        if [UInt16(1), 9].contains(frame.color.primaries) { renderFrame = frame }
        else {
            // The imported 8-bit HEVC capability AU signals SMPTE170M primaries,
            // which the renderer intentionally rejects. Keep that rejection and
            // validate canonical storage with explicit supported test primaries;
            // this does not claim correct display of that original color gamut.
            XCTAssertThrowsError(try VideoReadbackValidator.compare(frame: frame, renderer: renderer))
            var color = frame.color; color.primaries = 1
            renderFrame = DecodedFrame(pixelBuffer: buffer, id: frame.id, width: frame.width, height: frame.height,
                bitDepth: frame.bitDepth, color: color)
        }
        XCTAssertTrue(try VideoReadbackValidator.compare(frame: renderFrame, renderer: renderer).passed)
        try decoder.reset(); try decoder.close()
        // Buffer and both CoreVideo texture wrappers remain alive through GPU
        // completion even after the native decoder has been reset and destroyed.
        XCTAssertTrue(try VideoReadbackValidator.compare(frame: renderFrame, renderer: renderer).passed)
        XCTAssertEqual(decoder.statistics.accepted, 1)
        XCTAssertEqual(decoder.statistics.completed, 1)
        XCTAssertEqual(decoder.statistics.output, 1)
        XCTAssertEqual(decoder.statistics.failed, 0)
    }

    private func sampleBytes(named name: String) throws -> Data {
        // Reuse the native package's attributed immutable probe AUs; keep one
        // compressed-input source rather than duplicate a fixture in the client.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let header = try String(contentsOf: root.appendingPathComponent("Packages/moonlight-apple-decoder/src/profile_samples.hpp"), encoding: .utf8)
        let declaration = try XCTUnwrap(header.range(of: "\\b\(name)\\[\\]\\s*=\\s*\\{", options: .regularExpression))
        let suffix = header[declaration.upperBound...]
        let end = try XCTUnwrap(suffix.range(of: "}"))
        let body = String(suffix[..<end.lowerBound])
        let expression = try NSRegularExpression(pattern: "0x([0-9a-fA-F]{2})")
        let bytes = try expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { match in
            let range = try XCTUnwrap(Range(match.range(at: 1), in: body))
            return try XCTUnwrap(UInt8(body[range], radix: 16))
        }
        XCTAssertFalse(bytes.isEmpty)
        return Data(bytes)
    }
}
