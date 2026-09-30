import XCTest
import Metal
@testable import SwiftlightVideo

final class PyrowaveRenderingTests: XCTestCase {
    func testThreePlaneCodeNormalizationAndChromaCoordinates() throws {
        guard ProcessInfo.processInfo.environment["SWIFTLIGHT_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Opt in to real Metal validation")
        }
        let renderer = try MetalVideoRenderer()
        for depth in [8, 10] {
            for full in [false, true] {
                for divisor in [1, 2] {
                    let peak = depth == 10 ? 1023.0 : 255.0
                    let low = full ? 0.0 : (depth == 10 ? 64.0 : 16.0)
                    let span = full ? peak : (depth == 10 ? 876.0 : 219.0)
                    let center = depth == 10 ? 512.0 : 128.0
                    let cSpan = full ? peak : (depth == 10 ? 896.0 : 224.0)
                    let y = low + span * 0.4
                    let cb = center - cSpan * 0.12
                    let planes = try [makePlane(renderer.device, width: 8, height: 4, depth: depth, code: y),
                        makePlane(renderer.device, width: 8 / divisor, height: 4 / divisor, depth: depth, code: cb),
                        makePlane(renderer.device, width: 8 / divisor, height: 4 / divisor, depth: depth, code: center)]
                    let gpu = PyrowaveGPUFrame(planes: planes, chromaFormat: divisor == 1 ? 3 : 1)
                    let color = VideoColor(primaries: 9, transfer: 16, matrix: 9, fullRange: full, chromaLocation: 1)
                    let frame = DecodedFrame(pixelBuffer: nil, gpuFrame: gpu, id: 1, generation: 1, width: 8, height: 4,
                        bitDepth: depth, color: color, callbackNanoseconds: 0, hardwareAccelerated: true,
                        firstPacketNanoseconds: 0, admissionNanoseconds: 0, hostProcessingMilliseconds: nil,
                        scheduledArrivalNanoseconds: 0, vtSubmitNanoseconds: 0)
                    let target = try renderer.makeReadbackTarget(width: 8, height: 4)
                    XCTAssertTrue(try renderer.render(frame, into: target, outputColorSpace: .rec2020PQ))
                    try renderer.waitUntilIdleForValidation()
                    var actual = [Float](repeating: 0, count: 8 * 4 * 4)
                    actual.withUnsafeMutableBytes { bytes in
                        target.getBytes(bytes.baseAddress!, bytesPerRow: 8 * 16, from: MTLRegionMake2D(0, 0, 8, 4), mipmapLevel: 0)
                    }
                    func stored(_ code: Double) -> Double {
                        let storagePeak = depth == 10 ? 65535.0 : 255.0
                        return (code / peak * storagePeak).rounded() / storagePeak * peak
                    }
                    let luma = (stored(y) - low) / span
                    let c = (stored(cb) - center) / cSpan
                    let cr = (stored(center) - center) / cSpan
                    let kr = 0.2627, kb = 0.0593, kg = 1 - kr - kb
                    let expected = [luma + 2 * (1 - kr) * cr,
                        luma - 2 * kb * (1 - kb) / kg * c - 2 * kr * (1 - kr) / kg * cr,
                        luma + 2 * (1 - kb) * c]
                    for pixel in 0..<32 {
                        for component in 0..<3 { XCTAssertEqual(Double(actual[pixel * 4 + component]), expected[component], accuracy: 0.00005) }
                    }
                    XCTAssertEqual(frame.contentRect, CGRect(x: 0, y: 0, width: 8, height: 4))
                }
            }
        }
    }

    private func makePlane(_ device: MTLDevice, width: Int, height: Int, depth: Int, code: Double) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depth == 10 ? .r16Unorm : .r8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        if depth == 10 {
            let samples = [UInt16](repeating: UInt16((code / 1023 * 65535).rounded()), count: width * height)
            samples.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 2) }
        } else {
            let samples = [UInt8](repeating: UInt8(code.rounded()), count: width * height)
            samples.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width) }
        }
        return texture
    }
}
