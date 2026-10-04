import XCTest
import Foundation
import Metal
@testable import SwiftlightVideo

/// Real packet decoding and rendering through the production adapter. Readback
/// and waits are confined to this opt-in correctness suite.
final class PyrowaveDecoderTests: XCTestCase {
    func testAllProfilesRetainRealDecodedPlanesAcrossResetAndClose() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        for chroma in [UInt32(1), 3] {
            let bytes = try fixture(chroma: chroma)
            let width = Int(word(bytes, at: 0) & 0x3FFF) + 1
            let height = Int((word(bytes, at: 0) >> 14) & 0x3FFF) + 1
            for depth in [8, 10] {
                let color = depth == 10 ? VideoColor(primaries: 9, transfer: 16, matrix: 9, chromaLocation: 1) : VideoColor(chromaLocation: 1)
                let decoder = try VideoDecoder(codec: .pyrowave, maxFramesInFlight: 2, width: width,
                    height: height, bitDepth: depth, chromaFormat: chroma, fallbackColor: color)
                defer { try? decoder.close() }
                let frame = try decode(bytes, id: UInt64(depth), decoder: decoder)
                XCTAssertNil(frame.pixelBuffer)
                let gpu = try XCTUnwrap(frame.gpuFrame)
                XCTAssertEqual(gpu.planes.count, 3)
                XCTAssertEqual(frame.bitDepth, depth)
                XCTAssertEqual(frame.color, color)
                XCTAssertEqual(frame.width, width); XCTAssertEqual(frame.height, height)
                XCTAssertEqual(frame.vtSubmitNanoseconds, 0)
                let measuredDecode = decoder.statistics.decodeTime
                XCTAssertEqual(measuredDecode.count, 1)
                let duration = try XCTUnwrap(measuredDecode.averageMilliseconds)
                XCTAssertGreaterThan(duration, 0)
                XCTAssertEqual(duration, Double(frame.callbackNanoseconds - frame.admissionNanoseconds) / 1_000_000,
                    accuracy: 0.000001, "PyroWave decode time must describe this actual output's admission-to-callback interval")
                XCTAssertTrue(decoder.statistics.singleSampleVTSubmitToCallbackMilliseconds.isEmpty,
                    "PyroWave must retain a separate timing window from VideoToolbox")
                XCTAssertTrue(frame.hardwareAccelerated)
                for (planeIndex, plane) in gpu.planes.enumerated() {
                    let divisor = planeIndex == 0 || chroma == 3 ? 1 : 2
                    XCTAssertEqual(plane.width, width / divisor); XCTAssertEqual(plane.height, height / divisor)
                    let samples = try planeSamples(plane)
                    // The immutable native fixture is an independently specified
                    // three-plane ramp, encoded once by the test-only encoder.
                    var squaredError = 0.0, maximumError = 0.0
                    for y in 0..<plane.height {
                        for x in 0..<plane.width {
                            let dx = max(1, plane.width - 1), dy = max(1, plane.height - 1)
                            let input: Int
                            switch planeIndex {
                            case 0: input = 32 + 96 * x / dx + 96 * y / dy
                            case 1: input = 64 + 64 * x / dx + 32 * y / dy
                            default: input = 160 - 48 * x / dx + 32 * y / dy
                            }
                            let error = abs(samples[y * plane.width + x] - Double(input) / 255)
                            maximumError = max(maximumError, error); squaredError += error * error
                        }
                    }
                    XCTAssertLessThan(maximumError, 0.015)
                    XCTAssertLessThan(sqrt(squaredError / Double(samples.count)), 0.004)
                }
                let before = try renderedPixels(frame, renderer: renderer)
                try decoder.reset(); XCTAssertNil(decoder.takeLatestFrame())
                try decoder.close()
                XCTAssertEqual(try renderedPixels(frame, renderer: renderer), before,
                    "Retained output must survive decoder teardown without pool reuse")
                XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
                XCTAssertEqual(decoder.statistics.failed, 0)
                XCTAssertLessThanOrEqual(decoder.statistics.outstandingHighWater, 2)
            }
        }
    }

    func testDetailLossCriticalLossAndMalformedFrameRecoverIndependently() throws {
        try requireHardware()
        let decoder = try VideoDecoder(codec: .pyrowave, width: 128, height: 128, bitDepth: 8, chromaFormat: 1)
        defer { try? decoder.close() }
        // Twenty valid zero-coefficient records; the missing detail packet is
        // distinct from an intact record whose coefficients are all zero.
        var words: [UInt32] = [0x8000_0000 | 127 | (127 << 14), 20]
        for index in UInt32(0)..<20 { words += [2 << 16, index << 8] }
        let bytes = data(words)
        var fragments = [PyrowavePacketFragment(offset: 0, size: 8, kind: 2)]
        for index in UInt32(0)..<20 {
            fragments.append(PyrowavePacketFragment(offset: 8 + index * 8, size: 8, kind: index == 17 ? 1 : 2))
        }
        let detail = CompressedFrame(bytes: bytes, id: 100, pyrowaveFragments: fragments, pyrowaveCriticalPackets: 13)
        XCTAssertEqual(decoder.submit(detail), .accepted); try decoder.drain()
        let retained = try XCTUnwrap(decoder.takeLatestFrame())
        for plane in try XCTUnwrap(retained.gpuFrame).planes {
            for sample in try planeSamples(plane) { XCTAssertEqual(sample, 128.0 / 255, accuracy: 0.00001) }
        }
        fragments[3] = PyrowavePacketFragment(offset: fragments[3].offset, size: fragments[3].size, kind: 1)
        let before = decoder.statistics
        let critical = decoder.submit(CompressedFrame(bytes: bytes, id: 101, pyrowaveFragments: fragments, pyrowaveCriticalPackets: 13))
        guard case .rejected(let criticalCode) = critical else { return XCTFail("Critical packet loss must reject before admission: \(critical)") }
        XCTAssertTrue(decoder.canRecoverOnNextFrame(from: criticalCode))
        var malformed = bytes; malformed.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        let invalid = decoder.submit(CompressedFrame(bytes: malformed, id: 102))
        guard case .rejected(let malformedCode) = invalid else { return XCTFail("Malformed sequence must reject before admission: \(invalid)") }
        XCTAssertTrue(decoder.canRecoverOnNextFrame(from: malformedCode))
        XCTAssertEqual(decoder.statistics.accepted, before.accepted)
        XCTAssertEqual(decoder.statistics.completed, before.completed)
        var restored = detail; restored.id = 103
        XCTAssertEqual(decoder.submit(restored), .accepted); try decoder.drain()
        XCTAssertEqual(try XCTUnwrap(decoder.takeLatestFrame()).id, 103)
        XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
        XCTAssertEqual(decoder.statistics.failed, 0)
        XCTAssertNil(decoder.statistics.failureDescription)
        try decoder.close()
        XCTAssertFalse(try planeSamples(try XCTUnwrap(retained.gpuFrame).planes[0]).isEmpty)
    }

    func testNativeCodecRejectsGeometryAndBlockIndexThenAcceptsDuplicate() throws {
        try requireHardware()
        let decoder = try VideoDecoder(codec: .pyrowave, width: 128, height: 128, bitDepth: 8, chromaFormat: 1)
        defer { try? decoder.close() }
        let sequence: UInt32 = 0x8000_0000 | 127 | (127 << 14)
        let invalidRecords: [[UInt32]] = [
            [sequence ^ 1, 1, 2 << 16, 0],
            [sequence, 1 | (1 << 26), 2 << 16, 0],
            [sequence, 1 | (1 << 24), 2 << 16, 0],
            [sequence, 1, 2 << 16, 0xffff_ff00]
        ]
        for (index, words) in invalidRecords.enumerated() {
            let result = decoder.submit(CompressedFrame(bytes: data(words), id: UInt64(index)))
            guard case .rejected(let code) = result else { return XCTFail("Native codec must reject invalid record: \(result)") }
            XCTAssertTrue(decoder.canRecoverOnNextFrame(from: code))
            XCTAssertEqual(decoder.statistics.accepted, 0)
            XCTAssertEqual(decoder.statistics.completed, 0)
            XCTAssertNil(decoder.takeLatestFrame())
        }
        // The native parser ignores duplicates. The bridge only extracts bytes.
        let duplicate = data([sequence, 1, 2 << 16, 0, 2 << 16, 0])
        let decoded = try decode(duplicate, id: 10, decoder: decoder)
        XCTAssertEqual(decoded.id, 10)
        XCTAssertEqual(decoder.statistics.accepted, 1)
        XCTAssertEqual(decoder.statistics.completed, 1)
        XCTAssertEqual(decoder.statistics.failed, 0)
    }

    func testBoundedAsynchronousAdmissionAndTerminalAccounting() throws {
        try requireHardware()
        let bytes = try fixture(chroma: 1)
        let decoder = try VideoDecoder(codec: .pyrowave, maxFramesInFlight: 2, width: 128, height: 128,
            bitDepth: 8, chromaFormat: 1)
        defer { try? decoder.close() }
        for id in UInt64(1)...32 {
            let input = CompressedFrame(bytes: bytes, id: id)
            var result = decoder.submit(input)
            if result == .wouldBlock {
                let count = decoder.statistics.accepted
                try decoder.waitForCapacity(timeoutNanoseconds: 1_000_000_000)
                XCTAssertEqual(decoder.statistics.accepted, count, "Capacity wait cannot consume the rejected input")
                result = decoder.submit(input)
            }
            XCTAssertEqual(result, .accepted)
        }
        try decoder.drain()
        let statistics = decoder.statistics
        XCTAssertEqual(statistics.accepted, 32); XCTAssertEqual(statistics.completed, 32)
        XCTAssertEqual(Set(statistics.terminalIDs), Set(UInt64(1)...32))
        XCTAssertEqual(statistics.output, 32); XCTAssertEqual(statistics.failed, 0)
        XCTAssertEqual(statistics.mailboxHighWater, 1)
        XCTAssertLessThanOrEqual(statistics.outstandingHighWater, 2)
        XCTAssertEqual(try XCTUnwrap(decoder.takeLatestFrame()).id, 32)
    }

    func testRetainedOutputBackpressureDoesNotOverwriteOrConsumeInput() throws {
        try requireHardware()
        let bytes = try fixture(chroma: 1)
        let decoder = try VideoDecoder(codec: .pyrowave, maxFramesInFlight: 2, width: 128, height: 128,
            bitDepth: 8, chromaFormat: 1)
        defer { try? decoder.close() }
        var retained = [DecodedFrame]()
        var blockedInput: CompressedFrame?
        let neutral = data([0x8000_0000 | 127 | (127 << 14), 0])
        // Retention must eventually apply bounded pressure, rather than allocating
        // indefinitely or silently overwriting a texture still owned by rendering.
        for id in UInt64(1)...16 {
            let input = CompressedFrame(bytes: id == 1 ? bytes : neutral, id: id)
            let result = decoder.submit(input)
            if result == .wouldBlock { blockedInput = input; break }
            XCTAssertEqual(result, .accepted); try decoder.drain()
            retained.append(try XCTUnwrap(decoder.takeLatestFrame()))
        }
        let input = try XCTUnwrap(blockedInput, "Retained GPU leases must enforce a finite output pool")
        XCTAssertGreaterThanOrEqual(retained.count, 2)
        let oldest = try XCTUnwrap(retained.first)
        let before = try planeSamples(try XCTUnwrap(oldest.gpuFrame).planes[0])
        let statistics = decoder.statistics
        XCTAssertEqual(statistics.accepted, statistics.completed)
        XCTAssertFalse(statistics.terminalIDs.contains(input.id), "Would-block input must not receive a completion")
        // Release a different lease so the oldest retained output remains available
        // as an overwrite oracle while the exact blocked input is retried.
        retained.removeLast()
        try decoder.waitForCapacity(timeoutNanoseconds: 1_000_000_000)
        XCTAssertEqual(decoder.submit(input), .accepted); try decoder.drain()
        XCTAssertEqual(try XCTUnwrap(decoder.takeLatestFrame()).id, input.id)
        XCTAssertEqual(try planeSamples(try XCTUnwrap(oldest.gpuFrame).planes[0]), before)
        try decoder.close()
        XCTAssertEqual(try planeSamples(try XCTUnwrap(oldest.gpuFrame).planes[0]), before)
        XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
        XCTAssertEqual(Set(decoder.statistics.terminalIDs).count, Int(decoder.statistics.completed))
    }

    private func requireHardware() throws {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else { throw XCTSkip("Opt in to real PyroWave Metal validation") }
        guard VideoCodec.pyrowave.hardwareCandidate else { throw XCTSkip("PyroWave requires an Apple7 Metal GPU") }
    }
    private func fixture(chroma: UInt32) throws -> Data {
        let name = chroma == 3 ? "pyrowave-127x97-444.bin" : "pyrowave-128x128-420.bin"
        let configured = ProcessInfo.processInfo.environment["SWIFTLIGHT_PYROWAVE_FIXTURE_PATH"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = configured.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build/pyrowave-fixtures")
        let url = directory.hasDirectoryPath || directory.pathExtension != "bin" ? directory.appendingPathComponent(name) : directory
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Run scripts/prepare-pyrowave-fixtures.py or set SWIFTLIGHT_PYROWAVE_FIXTURE_PATH") }
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(bytes.count, 8)
        XCTAssertEqual((word(bytes, at: 4) >> 26) & 1, chroma == 3 ? 1 : 0)
        return bytes
    }
    private func decode(_ bytes: Data, id: UInt64, decoder: VideoDecoder) throws -> DecodedFrame {
        XCTAssertEqual(decoder.submit(CompressedFrame(bytes: bytes, id: id)), .accepted)
        try decoder.drain()
        return try XCTUnwrap(decoder.takeLatestFrame())
    }
    private func word(_ bytes: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
    }
    private func data(_ words: [UInt32]) -> Data {
        Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }
    private func planeSamples(_ texture: MTLTexture) throws -> [Double] {
        let bytesPerSample = texture.pixelFormat == .r16Unorm ? 2 : 1
        let row = (texture.width * bytesPerSample + 255) & ~255
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: row * texture.height, options: .storageModeShared))
        let queue = try XCTUnwrap(texture.device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * texture.height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        return (0..<texture.height).flatMap { y in (0..<texture.width).map { x in
            bytesPerSample == 2 ? Double(buffer.contents().load(fromByteOffset: y * row + x * 2, as: UInt16.self)) / 65535 :
                Double(buffer.contents().load(fromByteOffset: y * row + x, as: UInt8.self)) / 255
        } }
    }
    private func renderedPixels(_ frame: DecodedFrame, renderer: MetalVideoRenderer) throws -> [Float] {
        let target = try renderer.makeReadbackTarget(width: frame.width, height: frame.height)
        XCTAssertTrue(try renderer.render(frame, into: target))
        try renderer.waitUntilIdleForValidation()
        var values = [Float](repeating: 0, count: frame.width * frame.height * 4)
        values.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: frame.width * 16,
            from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0) }
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        return values
    }
}
