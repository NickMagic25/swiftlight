import Foundation

public enum VideoOverlayPosition: Sendable, Equatable {
    case topLeft, topCenter, topRight
}

/// A CPU-rasterized overlay at drawable-pixel resolution. Rows run top to bottom;
/// each pixel is premultiplied sRGB R, G, B, A in four consecutive bytes.
/// Rasterize/update only when the displayed content changes, outside media callbacks.
public struct VideoOverlayBitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba8: Data
    public let position: VideoOverlayPosition
    public let insetPixels: Int

    public init(width: Int, height: Int, rgba8: Data,
                position: VideoOverlayPosition = .topLeft, insetPixels: Int = 16) {
        self.width = width; self.height = height; self.rgba8 = rgba8
        self.position = position; self.insetPixels = insetPixels
    }

    func validate() throws {
        // Bound allocations and validate multiplication before touching a texture.
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 16_777_216, rgba8.count == width * height * 4,
              insetPixels >= 0, insetPixels <= 16_384 else {
            throw RendererFailure.unavailable("Overlay requires valid dimensions, inset, and tightly packed RGBA8 bytes")
        }
    }
}
