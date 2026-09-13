import Foundation
import CoreGraphics
import CoreText
import SwiftlightCore
import SwiftlightVideo

struct StatisticsOverlayRaster: Sendable {
    let bitmap: VideoOverlayBitmap
    let pointSize: CGSize
    let rowHeight: CGFloat
}

/// Core Text works off the main/render thread. This image changes at the existing
/// statistics cadence, while the video encoder reuses its texture for every frame.
enum StatisticsOverlayRasterizer {
    static func render(rows: [StreamStatisticRow], position: StreamStatisticsPosition,
                       backingScale: CGFloat, availableSize: CGSize) throws -> StatisticsOverlayRaster {
        let scale = min(4, max(1, backingScale))
        let width = min(520, max(96, availableSize.width - 32))
        let lineHeight: CGFloat = 18
        let displayedRows = Array(rows.prefix(24))
        let height = CGFloat(max(1, displayedRows.count)) * lineHeight + 48
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        let size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ gray: CGFloat) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [gray, gray, gray, 1])!
        }
        let font = CTFontCreateUIFontForLanguage(.system, 12, nil)!
        let headingFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 12, nil)!
        func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: String(text.prefix(512)), attributes: attributes))
        }
        var data = Data(count: pixelWidth * pixelHeight * 4)
        try data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RendererFailure.unavailable("Statistics bitmap allocation failed")
            }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(color(0.065))
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
            context.textMatrix = .identity
            let ellipsis = line("…", font: font, color: color(0.95))
            func draw(_ text: String, font: CTFont, color: CGColor, x: CGFloat,
                      top: CGFloat, maxWidth: CGFloat, alignRight: Bool = false) {
                let original = line(text, font: font, color: color)
                let textLine = CTLineGetTypographicBounds(original, nil, nil, nil) > Double(maxWidth) ?
                    CTLineCreateTruncatedLine(original, Double(maxWidth), .end, ellipsis) ?? original : original
                let textWidth = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
                context.saveGState()
                context.clip(to: CGRect(x: x, y: size.height - top - lineHeight, width: maxWidth, height: lineHeight + 2))
                context.textPosition = CGPoint(x: alignRight ? x + max(0, maxWidth - textWidth) : x,
                    y: size.height - top - CTFontGetAscent(font))
                CTLineDraw(textLine, context)
                context.restoreGState()
            }
            draw("Stream Statistics", font: headingFont, color: color(0.95), x: 12, top: 12, maxWidth: width - 24)
            if displayedRows.isEmpty {
                draw("Waiting for statistics…", font: font, color: color(0.72), x: 12, top: 36, maxWidth: width - 24)
            } else {
                let labelWidth = min(205, (width - 44) * 0.43)
                let valueX = 12 + labelWidth + 20
                for (index, row) in displayedRows.enumerated() {
                    try Task.checkCancellation()
                    let top = 36 + CGFloat(index) * lineHeight
                    draw(row.label, font: font, color: color(0.72), x: 12, top: top, maxWidth: labelWidth)
                    draw(row.value, font: font, color: color(0.95), x: valueX, top: top,
                         maxWidth: max(1, width - valueX - 12), alignRight: true)
                }
            }
        }
        let placement: VideoOverlayPosition
        switch position { case .topLeading: placement = .topLeft; case .top: placement = .topCenter; case .topTrailing: placement = .topRight }
        return StatisticsOverlayRaster(bitmap: VideoOverlayBitmap(width: pixelWidth, height: pixelHeight,
            rgba8: data, position: placement, insetPixels: Int((16 * scale).rounded())), pointSize: size, rowHeight: lineHeight)
    }
}
