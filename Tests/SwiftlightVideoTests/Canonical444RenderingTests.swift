import XCTest
import CoreVideo
import Metal
@testable import SwiftlightVideo

final class Canonical444RenderingTests: XCTestCase {
    func testPQBT2020TenBitFullResolutionChromaAndCrop() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        for full in [false, true] {
            let source = try synthetic(depth: 10, full: full, location: 4)
            let frame = DecodedFrame(pixelBuffer: source.pixelBuffer, id: 2, width: 12, height: 10, bitDepth: 10,
                color: VideoColor(primaries: 9, transfer: 16, matrix: 9, fullRange: full, chromaLocation: 4))
            XCTAssertEqual(frame.chromaFormat, 3)
            XCTAssertEqual(frame.contentRect, CGRect(x: 3, y: 3, width: 8, height: 6))
            let comparison = try VideoReadbackValidator.compare(frame: frame, renderer: renderer)
            XCTAssertTrue(comparison.passed, "PQ 4:4:4 full=\(full): \(comparison.maximumAbsoluteError)")
            let target = try renderer.makeReadbackTarget(width: 8, height: 6)
            XCTAssertTrue(try renderer.render(frame, into: target))
            try renderer.waitUntilIdleForValidation()
            var pixels = [Float](repeating: 0, count: 8 * 6 * 4)
            pixels.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: 8 * 16,
                    from: MTLRegionMake2D(0, 0, 8, 6), mipmapLevel: 0)
            }
            for y in 0..<6 {
                for x in 0..<8 {
                    let expected = reference(x: x + 3, y: y + 3, depth: 10, full: full, hdr: true)
                    for channel in 0..<3 {
                        XCTAssertEqual(Double(pixels[(y * 8 + x) * 4 + channel]), expected[channel], accuracy: 0.005)
                    }
                }
            }
            XCTAssertGreaterThan(abs(pixels[0] - pixels[4]), 1,
                "PQ luminance and per-pixel chroma must remain distinct through the cropped HDR render")
        }
    }

    func testFullResolutionChromaPreservesAlternatingSaturatedPixelsAndCrop() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        for depth in [8, 10] {
            for full in [false, true] {
                // Chroma-location signaling only moves subsampled chroma. All
                // six values must address the same per-pixel 4:4:4 samples.
                for location in UInt8(0)...5 {
                    let frame = try synthetic(depth: depth, full: full, location: location)
                    let buffer = try XCTUnwrap(frame.pixelBuffer)
                    XCTAssertEqual(CVPixelBufferGetWidthOfPlane(buffer, 1), 12)
                    XCTAssertEqual(CVPixelBufferGetHeightOfPlane(buffer, 1), 10)
                    XCTAssertEqual(frame.contentRect, CGRect(x: 3, y: 3, width: 8, height: 6))
                    let comparison = try VideoReadbackValidator.compare(frame: frame, renderer: renderer)
                    XCTAssertTrue(comparison.passed, "depth \(depth), full \(full), location \(location): \(comparison.maximumAbsoluteError)")
                    let target = try renderer.makeReadbackTarget(width: 8, height: 6)
                    XCTAssertTrue(try renderer.render(frame, into: target))
                    try renderer.waitUntilIdleForValidation()
                    var pixels = [Float](repeating: 0, count: 8 * 6 * 4)
                    pixels.withUnsafeMutableBytes {
                        target.getBytes($0.baseAddress!, bytesPerRow: 8 * 16,
                            from: MTLRegionMake2D(0, 0, 8, 6), mipmapLevel: 0)
                    }
                    for y in 0..<6 {
                        for x in 0..<8 {
                            let expected = reference(x: x + 3, y: y + 3, depth: depth, full: full)
                            for channel in 0..<3 {
                                XCTAssertEqual(Double(pixels[(y * 8 + x) * 4 + channel]), expected[channel], accuracy: 0.0003)
                            }
                        }
                    }
                    XCTAssertGreaterThan(abs(pixels[0] - pixels[4]), 0.15,
                        "Adjacent saturated pixels must keep distinct chroma, rather than share a 4:2:0 sample")
                }
            }
        }
    }

    func testInvalidDepthAndNonCanonicalPacked444Reject() throws {
        try requireHardware()
        let renderer = try MetalVideoRenderer()
        let source = try synthetic(depth: 8, full: false, location: 0)
        let target = try renderer.makeReadbackTarget(width: 8, height: 6)
        let mislabeled = DecodedFrame(pixelBuffer: source.pixelBuffer, id: 2, width: 12, height: 10,
            bitDepth: 10, color: source.color)
        XCTAssertThrowsError(try renderer.render(mislabeled, into: target))
        var packed: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 12, 10, kCVPixelFormatType_444YpCbCr8,
            attributes, &packed), kCVReturnSuccess)
        let frame = DecodedFrame(pixelBuffer: try XCTUnwrap(packed), id: 3, width: 12, height: 10,
            bitDepth: 8, color: source.color)
        XCTAssertThrowsError(try renderer.render(frame, into: target))
    }

    private func requireHardware() throws {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Opt in to real Metal/CoreVideo rendering validation")
        }
    }

    private func codes(x: Int, y: Int, depth: Int, full: Bool) -> (Int, Int, Int) {
        let center = depth == 10 ? 512 : 128
        let span = full ? (depth == 10 ? 1023 : 255) : (depth == 10 ? 896 : 224)
        let amplitude = span / 4
        let luma = full ? center : (depth == 10 ? 502 : 126)
        let index = (x + y) % 4
        return (luma, center + (index == 1 || index == 2 ? amplitude : -amplitude),
            center + (index == 0 || index == 2 ? amplitude : -amplitude))
    }

    private func reference(x: Int, y: Int, depth: Int, full: Bool, hdr: Bool = false) -> [Double] {
        let (yCode, cbCode, crCode) = codes(x: x, y: y, depth: depth, full: full)
        let maximum = depth == 10 ? 1023.0 : 255.0
        let center = depth == 10 ? 512.0 : 128.0
        let luma = (Double(yCode) - (full ? 0 : (depth == 10 ? 64 : 16))) /
            (full ? maximum : (depth == 10 ? 876 : 219))
        let chromaSpan = full ? maximum : (depth == 10 ? 896 : 224)
        let cb = (Double(cbCode) - center) / chromaSpan, cr = (Double(crCode) - center) / chromaSpan
        func srgbToLinear(_ value: Double) -> Double {
            let value = max(0, value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        if hdr {
            func pqToLinear(_ value: Double) -> Double {
                let powered = pow(max(0, value), 32.0 / 2523.0)
                let normalized = max(0, powered - 3424.0 / 4096.0) /
                    (2413.0 / 128.0 - 2392.0 / 128.0 * powered)
                return pow(normalized, 16384.0 / 2610.0) * 10000.0 / 203.0
            }
            let kr = 0.2627, kb = 0.0593, kg = 1 - kr - kb
            let rgb = [luma + 2 * (1 - kr) * cr,
                luma - 2 * kb * (1 - kb) / kg * cb - 2 * kr * (1 - kr) / kg * cr,
                luma + 2 * (1 - kb) * cb].map(pqToLinear)
            return [1.660491 * rgb[0] - 0.587641 * rgb[1] - 0.072850 * rgb[2],
                -0.124550 * rgb[0] + 1.132900 * rgb[1] - 0.008349 * rgb[2],
                -0.018151 * rgb[0] - 0.100579 * rgb[1] + 1.118730 * rgb[2]]
        }
        return [luma + 1.5748 * cr, luma - 0.1873242729306488 * cb - 0.4681242729306488 * cr,
            luma + 1.8556 * cb].map(srgbToLinear)
    }

    private func synthetic(depth: Int, full: Bool, location: UInt8) throws -> DecodedFrame {
        let format = depth == 10 ? (full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange) :
            (full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
        var optional: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 12, 10, format, attributes, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            for plane in 0..<2 {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                for y in 0..<10 {
                    for x in 0..<12 {
                        let values = codes(x: x, y: y, depth: depth, full: full)
                        let samples = plane == 0 ? [values.0] : [values.1, values.2]
                        for (component, code) in samples.enumerated() {
                            let offset = y * stride + (x * samples.count + component) * (depth == 10 ? 2 : 1)
                            if depth == 10 { base.storeBytes(of: UInt16(code << 6), toByteOffset: offset, as: UInt16.self) }
                            else { base.storeBytes(of: UInt8(code), toByteOffset: offset, as: UInt8.self) }
                        }
                    }
                }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCleanApertureKey, [kCVImageBufferCleanApertureWidthKey: 8,
            kCVImageBufferCleanApertureHeightKey: 6, kCVImageBufferCleanApertureHorizontalOffsetKey: 1,
            kCVImageBufferCleanApertureVerticalOffsetKey: 1] as CFDictionary, .shouldPropagate)
        return DecodedFrame(pixelBuffer: buffer, id: 1, width: 12, height: 10, bitDepth: depth,
            color: VideoColor(transfer: 13, fullRange: full, chromaLocation: location))
    }
}
