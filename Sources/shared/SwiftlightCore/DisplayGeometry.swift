import CoreGraphics
import Foundation

/// All rectangles in one shared window/display point coordinate system.
/// Intersecting the actual content rect with the safe screen rect prevents applying notch insets twice.
public struct DisplayGeometry: Sendable, Equatable {
    public var screen: CGRect
    public var safeScreen: CGRect
    public var content: CGRect
    public var nativePixels: PixelSize
    public var backingScale: Double
    public var refreshHz: Double
    public init(screen: CGRect, safeScreen: CGRect, content: CGRect, nativePixels: PixelSize,
                backingScale: Double, refreshHz: Double) {
        self.screen = screen; self.safeScreen = safeScreen; self.content = content
        self.nativePixels = nativePixels; self.backingScale = backingScale; self.refreshHz = refreshHz
    }
    public static let fallback = DisplayGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        safeScreen: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: CGRect(x: 0, y: 0, width: 1280, height: 720),
        nativePixels: PixelSize(1920, 1080), backingScale: 1, refreshHz: 60)
    public var safeContent: CGRect { content.intersection(safeScreen) }
    public var safeNativePixels: PixelSize {
        let rect = safeContent
        guard !rect.isNull, screen.width > 0, screen.height > 0 else { return PixelSize(2, 2) }
        return PixelSize(Int((rect.width / screen.width * Double(nativePixels.width)).rounded(.down)),
                         Int((rect.height / screen.height * Double(nativePixels.height)).rounded(.down))).even
    }
    public var windowPixels: PixelSize {
        PixelSize(Int((content.width * backingScale).rounded(.down)), Int((content.height * backingScale).rounded(.down))).even
    }
}

/// Native display pixels are distinct from UIKit's logical backing pixels in
/// scaled display modes. The platform adapter supplies the owning screen values.
public enum NativeDrawableGeometry {
    public static func size(viewSize: CGSize, screenSize: CGSize, nativeSize: CGSize,
                            nativeScale: CGFloat) -> CGSize? {
        func valid(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        }
        guard valid(viewSize), valid(screenSize), valid(nativeSize),
              nativeScale.isFinite, nativeScale > 0 else { return nil }

        let pixels: CGSize
        if viewSize == screenSize {
            // UIScreen.nativeBounds remains in its native orientation. Use the
            // exact screen dimensions to avoid a fractional-scale rounding border.
            pixels = (screenSize.width > screenSize.height) == (nativeSize.width > nativeSize.height)
                ? nativeSize : CGSize(width: nativeSize.height, height: nativeSize.width)
        } else {
            pixels = CGSize(width: viewSize.width * nativeScale, height: viewSize.height * nativeScale)
        }
        guard valid(pixels) else { return nil }
        return CGSize(width: max(1, pixels.width.rounded()), height: max(1, pixels.height.rounded()))
    }
}

public struct ViewportTransform: Sendable {
    public let source: CGSize
    public let viewport: CGRect
    public let destination: CGRect
    public init(source: CGSize, destination: CGRect, scaling: VideoScaling = .fit) {
        self.source = source; self.destination = destination
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else {
            viewport = .zero; return
        }
        let fit = min(destination.width / source.width, destination.height / source.height)
        let scale: Double
        switch scaling {
        case .fit: scale = fit
        case .fill: scale = max(destination.width / source.width, destination.height / source.height)
        case .integer: scale = fit >= 1 ? floor(fit) : fit
        }
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        viewport = CGRect(x: destination.midX - size.width / 2, y: destination.midY - size.height / 2,
                          width: size.width, height: size.height)
    }
    /// Returns top-left-origin video coordinates. Letterboxes and safe-area exclusions reject input.
    public func videoPoint(_ point: CGPoint) -> CGPoint? {
        guard destination.contains(point), viewport.contains(point), viewport.width > 0, viewport.height > 0 else { return nil }
        return CGPoint(x: (point.x - viewport.minX) / viewport.width * source.width,
                       y: (point.y - viewport.minY) / viewport.height * source.height)
    }
    /// Converts a point in the view's coordinates into the drawable's coordinates
    /// before testing the rendered viewport. Integer scaling must use drawable
    /// pixels even when the display's native scale is fractional.
    public func videoPoint(_ point: CGPoint, from viewBounds: CGRect) -> CGPoint? {
        func valid(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
                rect.size.width.isFinite && rect.size.height.isFinite &&
                rect.size.width > 0 && rect.size.height > 0
        }
        guard point.x.isFinite, point.y.isFinite, valid(viewBounds), valid(destination),
              viewBounds.contains(point) else { return nil }
        let mapped = CGPoint(
            x: destination.minX + (point.x - viewBounds.minX) / viewBounds.width * destination.width,
            y: destination.minY + (point.y - viewBounds.minY) / viewBounds.height * destination.height)
        return videoPoint(mapped)
    }
}
