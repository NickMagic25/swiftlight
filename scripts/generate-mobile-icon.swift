#!/usr/bin/env swift
// Reproduce the app-owned vector mark as the opaque PNG required by AppIcon.
// Run from the repository root: swift scripts/generate-mobile-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: "App/MobileAssets.xcassets/AppIcon.appiconset/AppIcon.png")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
}

let colors = [color(0.04, 0.10, 0.24), color(0.06, 0.25, 0.40), color(0.06, 0.43, 0.47)] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.65, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 70, y: 50), end: CGPoint(x: 1024, y: 1024),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Display outline and a single play shape stay legible at home-screen sizes.
context.setStrokeColor(color(0.83, 0.98, 1))
context.setLineWidth(42)
context.addPath(CGPath(roundedRect: CGRect(x: 191, y: 304, width: 642, height: 455),
                       cornerWidth: 66, cornerHeight: 66, transform: nil))
context.strokePath()

context.setFillColor(color(0.97, 1, 1))
context.move(to: CGPoint(x: 453, y: 422))
context.addLine(to: CGPoint(x: 453, y: 642))
context.addQuadCurve(to: CGPoint(x: 477, y: 656), control: CGPoint(x: 453, y: 670))
context.addLine(to: CGPoint(x: 642, y: 550))
context.addQuadCurve(to: CGPoint(x: 642, y: 514), control: CGPoint(x: 670, y: 532))
context.addLine(to: CGPoint(x: 477, y: 408))
context.addQuadCurve(to: CGPoint(x: 453, y: 422), control: CGPoint(x: 453, y: 394))
context.closePath()
context.fillPath()

context.setStrokeColor(color(0.50, 0.91, 0.94))
context.setLineWidth(38)
context.setLineCap(.round)
context.move(to: CGPoint(x: 410, y: 218))
context.addLine(to: CGPoint(x: 614, y: 218))
context.strokePath()

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write AppIcon.png") }
print(output.path)
