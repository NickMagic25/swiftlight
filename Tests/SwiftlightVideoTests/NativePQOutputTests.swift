import XCTest
import Foundation
import CoreVideo
import Metal
@testable import SwiftlightVideo

/// Real GPU readbacks validate shader values and the packed drawable format.
/// They do not validate Core Animation tone mapping or a monitor's light output.
final class NativePQOutputTests: XCTestCase {
    func testNativePQPreservesNeutralBlackWhiteAndIntermediateCodes() throws {
        let renderer = try hardwareRenderer()
        let target = try renderer.makeReadbackTarget(width: 64, height: 36)
        for (code, expected) in [(64, 0.0), (283, 0.25), (502, 0.5), (721, 0.75), (940, 1.0)] {
            let frame = try makeFrame(y: code, cb: 512, cr: 512)
            XCTAssertTrue(try renderer.render(frame, into: target, outputColorSpace: .rec2020PQ))
            try renderer.waitUntilIdleForValidation()
            for actual in readFloatPixel(target).prefix(3) {
                XCTAssertEqual(actual, expected, accuracy: 0.0006,
                    "PQ code \(code) must retain its nonlinear value without EOTF or reference-white scaling")
            }
            XCTAssertEqual(readFloatPixel(target)[3], 1)
        }
    }

    func testNativePQRetainsBT2020SaturatedColorsInFloatAndPackedTargets() throws {
        let renderer = try hardwareRenderer()
        let floatTarget = try renderer.makeReadbackTarget(width: 64, height: 36)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm,
            width: 64, height: 36, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .shared
        let packedTarget = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        // Fixed limited-range 10-bit BT.2020 patches: red, green, blue, yellow,
        // and magenta. Unequal channels expose gamut conversion and R/B swaps.
        let patches = [(354, 402, 827), (575, 282, 206), (205, 864, 475), (740, 192, 560), (335, 722, 749)]
        for (y, cb, cr) in patches {
            let frame = try makeFrame(y: y, cb: cb, cr: cr)
            let expected = referencePQ(y: y, cb: cb, cr: cr)
            XCTAssertTrue(try renderer.render(frame, into: floatTarget, outputColorSpace: .rec2020PQ))
            try renderer.waitUntilIdleForValidation()
            let actualFloat = readFloatPixel(floatTarget)
            for channel in 0..<3 {
                XCTAssertEqual(actualFloat[channel], expected[channel], accuracy: 0.0006,
                    "BT.2020 PQ must not be converted to linear sRGB")
            }
            XCTAssertTrue(try renderer.render(frame, into: packedTarget, outputColorSpace: .rec2020PQ))
            try renderer.waitUntilIdleForValidation()
            var packed: UInt32 = 0
            packedTarget.getBytes(&packed, bytesPerRow: 4, from: MTLRegionMake2D(32, 18, 1, 1), mipmapLevel: 0)
            let actualPacked = [Double((packed >> 20) & 1023), Double((packed >> 10) & 1023), Double(packed & 1023)]
            for channel in 0..<3 {
                XCTAssertEqual(actualPacked[channel] / 1023, expected[channel], accuracy: 2.0 / 1023,
                    "The production BGR10A2 target must preserve PQ color, allowing quantization")
            }
            XCTAssertEqual(packed >> 30, 3, "Packed output must remain opaque")
        }
    }

    func testNativePQSelectionDoesNotChangeDefaultLinearOutput() throws {
        let renderer = try hardwareRenderer()
        let target = try renderer.makeReadbackTarget(width: 64, height: 36)
        let frame = try makeFrame(y: 502, cb: 512, cr: 512)
        XCTAssertTrue(try renderer.render(frame, into: target, outputColorSpace: .rec2020PQ))
        try renderer.waitUntilIdleForValidation()
        XCTAssertEqual(readFloatPixel(target)[0], 0.5, accuracy: 0.0006)
        // Reuse the same cached pipeline. The omitted argument must restore the
        // existing linear output: ST.2084 code 0.5 is 92.2457 nits, white=203 nits.
        XCTAssertTrue(try renderer.render(frame, into: target))
        try renderer.waitUntilIdleForValidation()
        for actual in readFloatPixel(target).prefix(3) {
            XCTAssertEqual(actual, 92.2457 / 203, accuracy: 0.006)
        }
    }

    func testNativePQRejectsMismatchedColorSignalingAndTargets() throws {
        let renderer = try hardwareRenderer()
        let target = try renderer.makeReadbackTarget(width: 64, height: 36)
        for color in [VideoColor(primaries: 1, transfer: 16, matrix: 9),
                      VideoColor(primaries: 9, transfer: 1, matrix: 9),
                      VideoColor(primaries: 9, transfer: 16, matrix: 1)] {
            let frame = try makeFrame(y: 502, cb: 512, cr: 512, color: color)
            XCTAssertThrowsError(try renderer.render(frame, into: target, outputColorSpace: .rec2020PQ)) { error in
                guard case RendererFailure.unsupportedColor = error else {
                    return XCTFail("Expected rejection before rendering incorrectly tagged PQ: \(error)")
                }
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: 64, height: 36, mipmapped: false)
        descriptor.usage = .renderTarget
        let wrongTarget = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let frame = try makeFrame(y: 502, cb: 512, cr: 512)
        XCTAssertThrowsError(try renderer.render(frame, into: wrongTarget, outputColorSpace: .rec2020PQ))
        XCTAssertEqual(renderer.statistics.submitted, 0, "Rejected configurations must submit no GPU work")
    }

    private func hardwareRenderer() throws -> MetalVideoRenderer {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Native PQ readbacks require an authorized real Metal device; no display color validation is claimed")
        }
        return try MetalVideoRenderer()
    }

    /// Independent double-precision inverse BT.2020 nonconstant-luminance matrix
    /// on digital code values. No renderer uniforms, EOTF, or gamut matrix is reused.
    private func referencePQ(y: Int, cb: Int, cr: Int) -> [Double] {
        let luma = Double(y - 64) / 876
        let blueDifference = Double(cb - 512) / 896
        let redDifference = Double(cr - 512) / 896
        return [luma + 1.4746 * redDifference,
                luma - 0.16455312684366 * blueDifference - 0.57135312684366 * redDifference,
                luma + 1.8814 * blueDifference]
    }

    private func readFloatPixel(_ target: MTLTexture) -> [Double] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(32, 18, 1, 1), mipmapLevel: 0)
        }
        return values.map(Double.init)
    }

    private func makeFrame(y: Int, cb: Int, cr: Int,
                           color: VideoColor = VideoColor(primaries: 9, transfer: 16, matrix: 9)) throws -> DecodedFrame {
        var optional: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 36,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        let locked = CVPixelBufferLockBaseAddress(buffer, [])
        guard locked == kCVReturnSuccess else { throw RendererFailure.unavailable("Synthetic PQ pixel map failed: \(locked)") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane), height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for row in 0..<height {
                for column in 0..<(width * (plane == 0 ? 1 : 2)) {
                    let code = plane == 0 ? y : (column.isMultiple(of: 2) ? cb : cr)
                    base.storeBytes(of: UInt16(code << 6), toByteOffset: row * stride + column * 2, as: UInt16.self)
                }
            }
        }
        return DecodedFrame(pixelBuffer: buffer, id: 1, width: 64, height: 36, bitDepth: 10, color: color)
    }
}
