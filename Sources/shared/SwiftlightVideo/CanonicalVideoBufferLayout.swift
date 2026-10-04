import CoreVideo

/// Canonical immutable VideoToolbox biplanar storage accepted by the production
/// renderer. Texture extent comes from CoreVideo, never from a requested profile.
struct CanonicalVideoBufferLayout {
    let bitDepth: Int
    let chromaDivisor: Int

    init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            bitDepth = 8; chromaDivisor = 2
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            bitDepth = 10; chromaDivisor = 2
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            bitDepth = 8; chromaDivisor = 1
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            bitDepth = 10; chromaDivisor = 1
        default: return nil
        }
    }

    static func validated(buffer: CVPixelBuffer, width: Int, height: Int, bitDepth: Int) throws -> Self {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let layout = Self(pixelFormat: format), layout.bitDepth == bitDepth,
              CVPixelBufferGetPlaneCount(buffer) == 2 else { throw RendererFailure.unsupportedFormat(format) }
        let yw = CVPixelBufferGetWidthOfPlane(buffer, 0), yh = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard width > 0, height > 0, yw >= width, yh >= height, cw > 0, ch > 0,
              cw * layout.chromaDivisor >= width, ch * layout.chromaDivisor >= height,
              layout.chromaDivisor != 1 || (cw == yw && ch == yh) else {
            throw RendererFailure.unavailable("Invalid canonical luma/chroma plane dimensions")
        }
        return layout
    }
}
