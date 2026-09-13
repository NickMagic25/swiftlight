import XCTest
import Foundation
import CoreVideo
import Metal
@testable import SwiftlightVideo

final class VideoOverlayTests: XCTestCase {
    func testBitmapRejectsInvalidDimensionsStrideAndInsetBeforeAllocation() throws {
        let pixel = Data([255, 255, 255, 255])
        XCTAssertNoThrow(try VideoOverlayBitmap(width: 1, height: 1, rgba8: pixel).validate())
        for bitmap in [VideoOverlayBitmap(width: 0, height: 1, rgba8: pixel),
                       VideoOverlayBitmap(width: Int.max, height: Int.max, rgba8: pixel),
                       VideoOverlayBitmap(width: 1, height: 1, rgba8: Data([0, 0, 0])),
                       VideoOverlayBitmap(width: 1, height: 1, rgba8: pixel, insetPixels: -1)] {
            XCTAssertThrowsError(try bitmap.validate())
        }
    }

    func testOverlayUsesDrawableCoordinatesPremultipliedLinearColorAndOneCommand() throws {
        let renderer = try hardwareRenderer()
        let frame = try makeFrame()
        let target = try renderer.makeReadbackTarget(width: 64, height: 64)
        XCTAssertTrue(try renderer.render(frame, into: target))
        try renderer.waitUntilIdleForValidation()
        let video = pixel(target, x: 32, y: 32)
        let bitmap = VideoOverlayBitmap(width: 4, height: 1,
            rgba8: Data([255,255,255,255, 128,128,128,255, 128,128,128,128, 0,0,0,0]), insetPixels: 3)
        try renderer.setOverlay(bitmap)
        try renderer.setOverlay(bitmap)
        XCTAssertTrue(try renderer.render(frame, into: target))
        try renderer.waitUntilIdleForValidation()
        // The panel starts in the top letterbox, outside the video's fit viewport.
        XCTAssertEqual(pixel(target, x: 3, y: 3)[0], 1, accuracy: 0.0001)
        XCTAssertEqual(pixel(target, x: 4, y: 3)[0], srgbLinear(128.0 / 255), accuracy: 0.0001)
        XCTAssertEqual(pixel(target, x: 5, y: 3)[0], 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(pixel(target, x: 6, y: 3)[0], 0, accuracy: 0.0001)
        XCTAssertEqual(pixel(target, x: 32, y: 32), video)
        XCTAssertEqual(renderer.statistics.overlayUploads, 1)
        XCTAssertEqual(renderer.statistics.overlayDraws, 1)
        XCTAssertEqual(renderer.statistics.submitted, 2, "Overlay must share the video's command buffer")
        try renderer.setOverlay(nil)
        XCTAssertTrue(try renderer.render(frame, into: target))
        try renderer.waitUntilIdleForValidation()
        XCTAssertEqual(pixel(target, x: 3, y: 3)[0], 0, accuracy: 0.0001)
        XCTAssertEqual(renderer.statistics.overlayDraws, 1)
    }

    func testOverlayMovesWithoutUploadAndReplacementDoesNotMutateSubmittedTexture() throws {
        let renderer = try hardwareRenderer()
        let frame = try makeFrame()
        let first = try renderer.makeReadbackTarget(width: 64, height: 36)
        let second = try renderer.makeReadbackTarget(width: 80, height: 48)
        let third = try renderer.makeReadbackTarget(width: 64, height: 36)
        let white = Data(repeating: 255, count: 2 * 2 * 4)
        try renderer.setOverlay(VideoOverlayBitmap(width: 2, height: 2, rgba8: white, insetPixels: 2))
        XCTAssertTrue(try renderer.render(frame, into: first))
        try renderer.setOverlay(VideoOverlayBitmap(width: 2, height: 2, rgba8: white, position: .topRight, insetPixels: 4))
        XCTAssertTrue(try renderer.render(frame, into: second))
        // Replace before waiting: prior GPU submissions must retain immutable texels.
        try renderer.setOverlay(VideoOverlayBitmap(width: 1, height: 1, rgba8: Data([0,0,0,255]), insetPixels: 2))
        XCTAssertTrue(try renderer.render(frame, into: third))
        try renderer.setOverlay(nil)
        try renderer.waitUntilIdleForValidation()
        XCTAssertEqual(pixel(first, x: 2, y: 2)[0], 1, accuracy: 0.0001)
        XCTAssertEqual(pixel(second, x: 74, y: 4)[0], 1, accuracy: 0.0001)
        XCTAssertEqual(pixel(third, x: 2, y: 2)[0], 0, accuracy: 0.0001)
        XCTAssertEqual(renderer.statistics.overlayUploads, 2, "Placement-only changes reuse immutable texels")
        XCTAssertEqual(renderer.statistics.overlayDraws, 3)
        XCTAssertEqual(renderer.statistics.submitted, 3)
        try renderer.setOverlay(VideoOverlayBitmap(width: 2, height: 2, rgba8: white, position: .topCenter, insetPixels: 2))
        XCTAssertTrue(try renderer.render(frame, into: first))
        try renderer.waitUntilIdleForValidation()
        XCTAssertEqual(pixel(first, x: 31, y: 2)[0], 1, accuracy: 0.0001)
        XCTAssertLessThan(pixel(first, x: 30, y: 2)[0], 0.9)
    }

    func testOverlayWhiteMatches203NitsInPQAndReturnsToLinearOnCachedFloatPipeline() throws {
        let renderer = try hardwareRenderer()
        let frame = try makeFrame()
        let target = try renderer.makeReadbackTarget(width: 64, height: 36)
        try renderer.setOverlay(VideoOverlayBitmap(width: 1, height: 1, rgba8: Data([255,255,255,255]), insetPixels: 2))
        XCTAssertTrue(try renderer.render(frame, into: target, outputColorSpace: .rec2020PQ))
        try renderer.waitUntilIdleForValidation()
        for channel in pixel(target, x: 2, y: 2).prefix(3) {
            XCTAssertEqual(channel, pq(nits: 203), accuracy: 0.0002)
        }
        XCTAssertEqual(pixel(target, x: 32, y: 18)[0], 0.5, accuracy: 0.0006)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm, width: 64, height: 36, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let packed = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        XCTAssertTrue(try renderer.render(frame, into: packed, outputColorSpace: .rec2020PQ))
        try renderer.waitUntilIdleForValidation()
        var bits: UInt32 = 0
        packed.getBytes(&bits, bytesPerRow: 4, from: MTLRegionMake2D(2, 2, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(Double(bits & 1023) / 1023, pq(nits: 203), accuracy: 2.0 / 1023)
        XCTAssertEqual(bits >> 30, 3)
        XCTAssertTrue(try renderer.render(frame, into: target))
        try renderer.waitUntilIdleForValidation()
        XCTAssertEqual(pixel(target, x: 2, y: 2)[0], 1, accuracy: 0.0001)
        XCTAssertEqual(renderer.statistics.overlayUploads, 1)
    }

    private func hardwareRenderer() throws -> MetalVideoRenderer {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Overlay readbacks require an authorized real Metal device")
        }
        return try MetalVideoRenderer()
    }
    private func srgbLinear(_ code: Double) -> Double {
        code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4)
    }
    private func pq(nits: Double) -> Double {
        let powered = pow(nits / 10000, 2610.0 / 16384)
        return pow((3424.0 / 4096 + 2413.0 / 128 * powered) / (1 + 2392.0 / 128 * powered), 2523.0 / 32)
    }
    private func pixel(_ target: MTLTexture, x: Int, y: Int) -> [Double] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return values.map(Double.init)
    }
    private func makeFrame() throws -> DecodedFrame {
        var optional: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 36,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane), height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for row in 0..<height {
                for column in 0..<(width * (plane == 0 ? 1 : 2)) {
                    base.storeBytes(of: UInt16((plane == 0 ? 502 : 512) << 6), toByteOffset: row * stride + column * 2, as: UInt16.self)
                }
            }
        }
        return DecodedFrame(pixelBuffer: buffer, id: 1, width: 64, height: 36, bitDepth: 10,
            color: VideoColor(primaries: 9, transfer: 16, matrix: 9))
    }
}
