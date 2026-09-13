import Foundation
import CoreVideo
import Metal

public struct RenderComparison: Codable, Sendable {
    public let samples: Int
    public let maximumAbsoluteError: Double
    public let meanAbsoluteError: Double
    public let tolerance: Double
    public var passed: Bool { samples > 0 && maximumAbsoluteError <= tolerance }
}

/// Server-free correctness diagnostics ONLY. CPU pixel mapping and a completion wait
/// belong here, never in the production display path. The Metal path is unmodified.
public enum VideoReadbackValidator {
    public static func compare(frame: DecodedFrame, renderer: MetalVideoRenderer) throws -> RenderComparison {
        let content = frame.contentRect
        let width = Int(content.width), height = Int(content.height)
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw RendererFailure.unavailable("Invalid readback dimensions")
        }
        let target = try renderer.makeReadbackTarget(width: width, height: height)
        let finished = DispatchSemaphore(value: 0)
        let success = ValidationCompletion()
        guard try renderer.render(frame, into: target, completion: { result in success.store(result.succeeded); finished.signal() }) else {
            throw RendererFailure.unavailable("Unexpected GPU capacity pressure in correctness mode")
        }
        guard finished.wait(timeout: .now() + 10) == .success, success.value else {
            throw RendererFailure.unavailable("Metal correctness command failed or timed out")
        }
        var rendered = [Float](repeating: 0, count: width * height * 4)
        rendered.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let buffer = frame.pixelBuffer
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw RendererFailure.unavailable("Diagnostic pixel map failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw RendererFailure.unavailable("Diagnostic pixel planes unavailable")
        }
        let ten = frame.bitDepth == 10
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        func code(_ base: UnsafeMutableRawPointer, _ offset: Int) -> Double {
            ten ? Double(base.load(fromByteOffset: offset, as: UInt16.self) >> 6) : Double(base.load(fromByteOffset: offset, as: UInt8.self))
        }
        func chroma(_ x: Double, _ y: Double, _ channel: Int) -> Double {
            let ix = Int(floor(x)), iy = Int(floor(y)); let fx = x - floor(x), fy = y - floor(y)
            func at(_ px: Int, _ py: Int) -> Double {
                code(uvBase, min(ch - 1, max(0, py)) * uvStride + (min(cw - 1, max(0, px)) * 2 + channel) * (ten ? 2 : 1))
            }
            return (at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx) * (1 - fy) +
                (at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx) * fy
        }
        let peak = ten ? 1023.0 : 255.0
        let low = frame.color.fullRange ? 0.0 : (ten ? 64.0 : 16.0)
        let ySpan = frame.color.fullRange ? peak : (ten ? 876.0 : 219.0)
        let cSpan = frame.color.fullRange ? peak : (ten ? 896.0 : 224.0)
        let center = ten ? 512.0 : 128.0
        let kr = frame.color.matrix == 9 ? 0.2627 : ([5, 6].contains(frame.color.matrix) ? 0.299 : 0.2126)
        let kb = frame.color.matrix == 9 ? 0.0593 : ([5, 6].contains(frame.color.matrix) ? 0.114 : 0.0722)
        let loc = frame.color.chromaLocation
        let shiftX = [UInt8(0), 2, 4].contains(loc) ? 0.5 : 0.0
        let shiftY = [UInt8(2), 3].contains(loc) ? 0.5 : ([UInt8(4), 5].contains(loc) ? -0.5 : 0.0)
        func linear(_ v: Double) -> Double {
            let x = max(0, v)
            if frame.color.transfer == 16 {
                let p = pow(x, 32.0 / 2523.0)
                return pow(max(p - 3424.0 / 4096.0, 0) / max(2413.0 / 128.0 - 2392.0 / 128.0 * p, 1e-7), 16384.0 / 2610.0) * (10000.0 / 203.0)
            }
            if frame.color.transfer == 13 { return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1.0 / 0.45)
        }
        var errorSum = 0.0, maximum = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let sx = x + Int(content.minX), sy = y + Int(content.minY)
                let luma = (code(yBase, sy * yStride + sx * (ten ? 2 : 1)) - low) / ySpan
                let cb = (chroma((Double(sx) + 0.5 + shiftX) / 2 - 0.5, (Double(sy) + 0.5 + shiftY) / 2 - 0.5, 0) - center) / cSpan
                let cr = (chroma((Double(sx) + 0.5 + shiftX) / 2 - 0.5, (Double(sy) + 0.5 + shiftY) / 2 - 0.5, 1) - center) / cSpan
                var rgb = [linear(luma + 2 * (1 - kr) * cr), linear(luma - 2 * kb * (1 - kb) / (1 - kr - kb) * cb - 2 * kr * (1 - kr) / (1 - kr - kb) * cr), linear(luma + 2 * (1 - kb) * cb)]
                if frame.color.primaries == 9 {
                    let r = rgb[0], g = rgb[1], b = rgb[2]
                    rgb = [1.660491 * r - 0.587641 * g - 0.072850 * b, -0.124550 * r + 1.132900 * g - 0.008349 * b, -0.018151 * r - 0.100579 * g + 1.118730 * b]
                }
                for component in 0..<3 {
                    let actual = Double(rendered[(y * width + x) * 4 + component])
                    guard actual.isFinite, rgb[component].isFinite else { throw RendererFailure.unavailable("Nonfinite render/readback sample") }
                    let error = abs(actual - rgb[component]); maximum = max(maximum, error); errorSum += error
                }
            }
        }
        let samples = width * height * 3
        // Metal texture filtering is implementation-precision; PQ magnifies tiny code
        // interpolation errors. Both limits are in linear reference-white units.
        return RenderComparison(samples: samples, maximumAbsoluteError: maximum, meanAbsoluteError: errorSum / Double(samples),
                                tolerance: frame.color.transfer == 16 ? 0.05 : 0.006)
    }
}

/// Shared one-bit diagnostic completion is synchronized across Metal's callback thread.
private final class ValidationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false
    func store(_ value: Bool) { lock.lock(); succeeded = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return succeeded }
}
