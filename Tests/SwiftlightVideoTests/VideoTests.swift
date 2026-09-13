import XCTest
import Foundation
import CoreVideo
import Metal
import QuartzCore
@testable import SwiftlightVideo

final class VideoTests: XCTestCase {
    func testFrameAvailableNotificationCanReadAndTakeMailboxAfterUnlock() throws {
        try requireHardware()
        let decoder = try VideoDecoder(codec: .hevc)
        defer { try? decoder.close() }
        let available = expectation(description: "Frame available outside mailbox lock")
        decoder.setFrameAvailableHandler { [weak decoder] in
            guard let decoder else { return }
            let accessed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInteractive).async {
                // Require another thread to acquire the mailbox lock before the
                // notification returns. Timeout makes a regression fail, not hang.
                _ = decoder.statistics
                XCTAssertNotNil(decoder.takeLatestFrame())
                accessed.signal()
            }
            XCTAssertEqual(accessed.wait(timeout: .now() + 1), .success,
                "Frame notification must not hold the mailbox lock")
            available.fulfill()
        }
        XCTAssertEqual(decoder.submit(try load("hevc-sdr8")[0]), .accepted)
        wait(for: [available], timeout: 10)
        decoder.setFrameAvailableHandler(nil)
        XCTAssertEqual(decoder.statistics.takenForPresentation, 1)
    }

    func testDrawableCallbackCanFinishDuringHandlerRegistration() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        let source = try synthetic(depth: 10, full: false, location: 0)
        let now = VideoDecoder.monotonicNanoseconds
        let frame = DecodedFrame(pixelBuffer: source.pixelBuffer, id: 77, width: source.width, height: source.height,
            bitDepth: source.bitDepth, color: source.color, callbackNanoseconds: now,
            firstPacketNanoseconds: now - 10_000_000, hostProcessingMilliseconds: 2.5)
        let target = try renderer.makeReadbackTarget(width: 64, height: 36)
        let drawable = CallbackDuringRegistrationDrawable()
        XCTAssertTrue(try renderer.encode(frame, target: target, drawable: drawable, present: nil, scaleMode: .fit, completion: nil))
        try renderer.waitUntilIdleForValidation()
        XCTAssertFalse(drawable.callbackTimedOut, "Presented callback must not wait for a lock held during drawable registration")
        XCTAssertEqual(renderer.statistics.completed, 1)
        XCTAssertEqual(renderer.statistics.inFlight, 0)
        XCTAssertEqual(renderer.statistics.presented, 1)
        XCTAssertEqual(renderer.statistics.firstPacketToPresentation.count, 1)
        XCTAssertEqual(renderer.statistics.hostProcessingAndClientPresentation.count, 1)
        let latency = try XCTUnwrap(renderer.statistics.firstPacketToPresentation.averageMilliseconds)
        XCTAssertGreaterThan(latency, 0)
        XCTAssertEqual(try XCTUnwrap(renderer.statistics.hostProcessingAndClientPresentation.averageMilliseconds), latency + 2.5, accuracy: 0.000001)
    }

    func testLifecycleAndSynchronousRejectionConsumesNothing() throws {
        for codec in VideoCodec.allCases {
            let decoder = try VideoDecoder(codec: codec)
            XCTAssertEqual(decoder.submit(CompressedFrame(bytes: Data(), id: 1)), .rejected(2))
            XCTAssertNotEqual(decoder.submit(CompressedFrame(bytes: Data([0xFF, 0x01, 0x7F]), id: 2)), .accepted)
            try decoder.drain(); try decoder.reset(); try decoder.close(); try decoder.close()
            XCTAssertEqual(decoder.statistics.accepted, 0)
            XCTAssertEqual(decoder.statistics.completed, 0)
            XCTAssertEqual(decoder.statistics.rejected, 2)
            XCTAssertEqual(decoder.submit(CompressedFrame(bytes: Data([1]), id: 3)), .rejected(9))
        }
    }

    func testTruncatedRealAccessUnitConsumesNothing() throws {
        for codec in VideoCodec.allCases {
            let first = try load("\(codec.rawValue)-sdr8")[0]
            let decoder = try VideoDecoder(codec: codec)
            XCTAssertNotEqual(decoder.submit(CompressedFrame(bytes: first.bytes.prefix(1), id: 10)), .accepted)
            try decoder.drain(); try decoder.close()
            XCTAssertEqual(decoder.statistics.accepted, 0); XCTAssertEqual(decoder.statistics.completed, 0)
            XCTAssertEqual(decoder.statistics.rejected, 1)
        }
    }

    func testConfigurationOnlyInlineCompletionAndRetainedLifetime() throws {
        try requireHardware()
        let inputs = try load("hevc-sdr8")
        var first = inputs[0]
        first.firstPacketNanoseconds = VideoDecoder.monotonicNanoseconds
        first.arrivalNanoseconds = first.firstPacketNanoseconds
        first.hostProcessingMilliseconds = 3.2
        let bytes = [UInt8](first.bytes)
        var starts: [Int] = []
        for i in 0..<(bytes.count - 3) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 { starts.append(i) }
        starts.append(bytes.count)
        var configuration = Data()
        for pair in zip(starts, starts.dropFirst()) where pair.0 + 4 < pair.1 {
            let type = (bytes[pair.0 + 4] >> 1) & 0x3F
            if [32, 33, 34].contains(type) { configuration.append(contentsOf: bytes[pair.0..<pair.1]) }
        }
        XCTAssertFalse(configuration.isEmpty)
        let decoder = try VideoDecoder(codec: .hevc)
        XCTAssertEqual(decoder.submit(CompressedFrame(bytes: configuration, id: 999)), .accepted)
        // Configuration-only completion can occur inline before submit returns. This
        // checks that the adapter neither deadlocks nor miscounts an early callback.
        XCTAssertEqual(decoder.statistics.accepted, 1)
        XCTAssertEqual(decoder.statistics.completed, 1)
        XCTAssertEqual(decoder.statistics.noDisplay, 1)
        XCTAssertNil(decoder.takeLatestFrame())
        XCTAssertEqual(decoder.submit(first), .accepted)
        try decoder.drain()
        let frame = try XCTUnwrap(decoder.takeLatestFrame())
        XCTAssertEqual(frame.firstPacketNanoseconds, first.firstPacketNanoseconds)
        XCTAssertEqual(frame.hostProcessingMilliseconds, 3.2)
        XCTAssertGreaterThanOrEqual(frame.callbackNanoseconds, frame.admissionNanoseconds)
        XCTAssertGreaterThanOrEqual(frame.admissionNanoseconds, frame.firstPacketNanoseconds)
        XCTAssertEqual(decoder.statistics.decodeTime.count, 1)
        try decoder.reset(); XCTAssertNil(decoder.takeLatestFrame()); try decoder.close()
        let renderer = try MetalVideoRenderer()
        XCTAssertTrue(try VideoReadbackValidator.compare(frame: frame, renderer: renderer).passed)
        XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
    }

    func testBoundedHandoffResetAndTerminalAccounting() throws {
        try requireHardware()
        for codec in VideoCodec.allCases {
            let decoder = try VideoDecoder(codec: codec, maxFramesInFlight: 2)
            let inputs = try load("\(codec.rawValue)-sdr8")
            for input in inputs {
                var result = decoder.submit(input)
                if result == .wouldBlock { try decoder.waitForCapacity(); result = decoder.submit(input) }
                if result == .wouldBlock { try decoder.drain(); result = decoder.submit(input) }
                XCTAssertEqual(result, .accepted)
            }
            try decoder.drain()
            XCTAssertEqual(decoder.statistics.accepted, 8)
            XCTAssertEqual(decoder.statistics.completed, 8)
            XCTAssertEqual(Set(decoder.statistics.terminalIDs).count, 8)
            XCTAssertEqual(decoder.statistics.output, 8)
            XCTAssertEqual(decoder.statistics.mailboxHighWater, 1)
            XCTAssertLessThanOrEqual(decoder.statistics.outstandingHighWater, 2)
            XCTAssertEqual(decoder.statistics.skippedForPresentation, 7)
            // Reset clears pending presentation; late completion accounting stays exact.
            XCTAssertEqual(decoder.submit(inputs[0]), .accepted)
            try decoder.reset()
            XCTAssertNil(decoder.takeLatestFrame())
            XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
            XCTAssertEqual(decoder.submit(inputs[1]), .needsRandomAccess)
            XCTAssertEqual(decoder.submit(inputs[0]), .accepted)
            try decoder.drain()
            XCTAssertNotNil(decoder.takeLatestFrame())
            XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
            try decoder.close()
        }
    }

    func testCanonicalRangeChromaAndPaddedCropShaderReadback() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        for depth in [8, 10] {
            for full in [false, true] {
                for location: UInt8 in [0, 1, 2, 3, 4, 5] {
                    let frame = try synthetic(depth: depth, full: full, location: location)
                    let result = try VideoReadbackValidator.compare(frame: frame, renderer: renderer)
                    XCTAssertTrue(result.passed, "depth=\(depth) full=\(full) location=\(location) max=\(result.maximumAbsoluteError)")
                    XCTAssertEqual(frame.contentRect, CGRect(x: 2, y: 2, width: 60, height: 32))
                    let visibleDimensions = DecodedFrame(pixelBuffer: frame.pixelBuffer, id: 2, width: 60, height: 32,
                        bitDepth: depth, color: frame.color)
                    XCTAssertEqual(visibleDimensions.contentRect, frame.contentRect, "Offset clean aperture must not be cropped a second time by visible dimensions")
                }
            }
        }
        XCTAssertEqual(renderer.statistics.inFlight, 0)
        XCTAssertEqual(renderer.statistics.submitted, renderer.statistics.completed)
    }

    func testConfigurationChangesWithPendingAcceptedWork() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        for codec in VideoCodec.allCases {
            let decoder = try VideoDecoder(codec: codec)
            var initial = try load("\(codec.rawValue)-sdr8")[0]
            var changed = try load("\(codec.rawValue)-reconfigure")[0]
            initial.id = 1000; changed.id = 2000
            XCTAssertEqual(decoder.submit(initial), .accepted)
            let firstTry = decoder.submit(changed)
            if firstTry == .wouldBlock {
                // A format transition may hold admission while old configuration work
                // is pending. Drain on the serialized control worker and retry once.
                try decoder.drain()
                XCTAssertEqual(decoder.submit(changed), .accepted)
            } else { XCTAssertEqual(firstTry, .accepted) }
            try decoder.drain()
            let output = try XCTUnwrap(decoder.takeLatestFrame())
            XCTAssertEqual(output.id, 2000); XCTAssertEqual(output.width, 192); XCTAssertEqual(output.height, 104)
            XCTAssertEqual(output.bitDepth, 10); XCTAssertEqual(output.color.primaries, 9); XCTAssertEqual(output.color.transfer, 16)
            XCTAssertEqual(output.color.mastering.count, 24); XCTAssertEqual(output.color.contentLight.count, 4)
            XCTAssertTrue(try VideoReadbackValidator.compare(frame: output, renderer: renderer).passed)
            XCTAssertEqual(decoder.statistics.accepted, 2); XCTAssertEqual(decoder.statistics.completed, 2)
            XCTAssertEqual(decoder.statistics.failed, 0)
            try decoder.reset()
            initial.id = 3000
            XCTAssertEqual(decoder.submit(initial), .accepted)
            try decoder.drain()
            XCTAssertEqual(decoder.takeLatestFrame()?.bitDepth, 8)
            XCTAssertEqual(decoder.statistics.accepted, decoder.statistics.completed)
            try decoder.close()
        }
    }

    private func requireHardware() throws {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Run scripts/validate-offline.sh with real Apple hardware access; ordinary unit runs do not claim hardware coverage")
        }
    }
    private func load(_ fixture: String) throws -> [CompressedFrame] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent("fixtures/\(fixture)")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("manifest.json"))) as? [String: Any])
        let units = try XCTUnwrap(object["access_units"] as? [[String: Any]])
        let payload = try Data(contentsOf: base.appendingPathComponent("payload.bin"))
        return try units.map { unit in
            let offset = try XCTUnwrap(unit["offset"] as? Int), count = try XCTUnwrap(unit["length"] as? Int)
            return CompressedFrame(bytes: payload.subdata(in: offset..<(offset + count)), id: UInt64(try XCTUnwrap(unit["frame_id"] as? Int)), randomAccess: unit["random_access"] as? Bool ?? false)
        }
    }
    private func synthetic(depth: Int, full: Bool, location: UInt8) throws -> DecodedFrame {
        let format = depth == 10 ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) :
            (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        var optional: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, format, attributes, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane), height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for y in 0..<height {
                for x in 0..<(width * (plane == 0 ? 1 : 2)) {
                    let code: Int
                    if plane == 0 {
                        let low = full ? 0 : (depth == 10 ? 64 : 16), high = full ? (depth == 10 ? 1023 : 255) : (depth == 10 ? 940 : 235)
                        code = low + (high - low) * x / (width - 1)
                    } else {
                        let center = depth == 10 ? 512 : 128
                        let amplitude = depth == 10 ? 128 : 32
                        code = center + ((x / 2 + y) % 4 - 2) * amplitude / 2
                    }
                    if depth == 10 { base.storeBytes(of: UInt16(code << 6), toByteOffset: y * stride + x * 2, as: UInt16.self) }
                    else { base.storeBytes(of: UInt8(code), toByteOffset: y * stride + x, as: UInt8.self) }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, [kCVImageBufferCleanApertureWidthKey: 60,
            kCVImageBufferCleanApertureHeightKey: 32, kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0] as CFDictionary, .shouldPropagate)
        return DecodedFrame(pixelBuffer: buffer, id: 1, width: 64, height: 36, bitDepth: depth,
            color: VideoColor(fullRange: full, chromaLocation: location))
    }
}

/// Models the captured Core Animation ordering: handler registration waits for a
/// prior presented callback to return. All metadata is immutable; callbackTimedOut
/// is written/read only by the submitting test thread. The worker only invokes the
/// supplied Sendable callback and signals its semaphore. No visible presentation.
private final class CallbackDuringRegistrationDrawable: NSObject, MTLDrawable, @unchecked Sendable {
    let presentedTime = CACurrentMediaTime()
    let drawableID = 1
    private(set) var callbackTimedOut = false
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async { [self] in block(self); returned.signal() }
        callbackTimedOut = returned.wait(timeout: .now() + 1) != .success
    }
    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
}
