import Foundation
import CoreGraphics
import CoreText
import SwiftlightCore
import SwiftlightVideo

struct StatisticsOverlayRaster: Sendable {
    let bitmap: VideoOverlayBitmap
    let pointSize: CGSize
    let rowHeight: CGFloat
    let rowOriginY: CGFloat
    let contentInset: CGFloat
    let displayedRowCount: Int
}

/// Core Text works off the main/render thread. This image changes at the existing
/// statistics cadence, while the video encoder reuses its texture for every frame.
enum StatisticsOverlayRasterizer {
    static func render(rows: [StreamStatisticRow], position: StreamStatisticsPosition,
                       backingScale: CGFloat, availableSize: CGSize,
                       fontScale: CGFloat = 1, maximumRows: Int = 24) throws -> StatisticsOverlayRaster {
        let scale = min(4, max(1, backingScale))
        let textScale = fontScale.isFinite ? min(2, max(1, fontScale)) : 1
        let width = min(520, max(96, availableSize.width - 32))
        let lineHeight: CGFloat = 18 * textScale
        let inset: CGFloat = 12 * textScale
        let rowOriginY: CGFloat = 36 * textScale
        let displayedRows = Array(rows.prefix(min(24, max(0, maximumRows))))
        let height = CGFloat(max(1, displayedRows.count)) * lineHeight + 48 * textScale
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        let size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ gray: CGFloat) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [gray, gray, gray, 1])!
        }
        let font = CTFontCreateUIFontForLanguage(.system, 12 * textScale, nil)!
        let headingFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 12 * textScale, nil)!
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
            let omittedRows = rows.count - displayedRows.count
            let heading = omittedRows > 0 ? "Stream Statistics · \(omittedRows) more" : "Stream Statistics"
            draw(heading, font: headingFont, color: color(0.95), x: inset, top: inset, maxWidth: width - 2 * inset)
            if displayedRows.isEmpty {
                let empty = rows.isEmpty ? "Waiting for statistics…" : "More space needed for values"
                draw(empty, font: font, color: color(0.72), x: inset, top: rowOriginY, maxWidth: width - 2 * inset)
            } else {
                let labelWidth = max(1, min(205 * textScale, (width - 44 * textScale) * 0.43))
                let valueX = inset + labelWidth + 20 * textScale
                for (index, row) in displayedRows.enumerated() {
                    try Task.checkCancellation()
                    let top = rowOriginY + CGFloat(index) * lineHeight
                    draw(row.label, font: font, color: color(0.72), x: inset, top: top, maxWidth: labelWidth)
                    draw(row.value, font: font, color: color(0.95), x: valueX, top: top,
                         maxWidth: max(1, width - valueX - inset), alignRight: true)
                }
            }
        }
        let placement: VideoOverlayPosition
        switch position { case .topLeading: placement = .topLeft; case .top: placement = .topCenter; case .topTrailing: placement = .topRight }
        return StatisticsOverlayRaster(bitmap: VideoOverlayBitmap(width: pixelWidth, height: pixelHeight,
            rgba8: data, position: placement, insetPixels: Int((16 * scale).rounded())), pointSize: size,
            rowHeight: lineHeight, rowOriginY: rowOriginY, contentInset: inset, displayedRowCount: displayedRows.count)
    }
}
