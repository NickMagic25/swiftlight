import CoreGraphics
import XCTest
@testable import SwiftlightCore

final class NativeDrawableGeometryTests: XCTestCase {
    private let landscape = CGSize(width: 1408, height: 970)
    private let nativePortrait = CGSize(width: 1668, height: 2420)
    private let nativeScale: CGFloat = 2420.0 / 1408.0

    func testFullScreenUsesExactOrientedNativePixels() {
        // The two rounded point dimensions do not imply exactly the same scale.
        XCTAssertNotEqual((landscape.height * nativeScale).rounded(), 1668)
        XCTAssertEqual(NativeDrawableGeometry.size(viewSize: landscape, screenSize: landscape,
            nativeSize: nativePortrait, nativeScale: nativeScale), CGSize(width: 2420, height: 1668))
        let portrait = CGSize(width: landscape.height, height: landscape.width)
        XCTAssertEqual(NativeDrawableGeometry.size(viewSize: portrait, screenSize: portrait,
            nativeSize: nativePortrait, nativeScale: nativeScale), nativePortrait)
    }

    func testPartialWindowUsesNativeScaleAndWholePixels() {
        XCTAssertEqual(NativeDrawableGeometry.size(viewSize: CGSize(width: 704, height: 485),
            screenSize: landscape, nativeSize: nativePortrait, nativeScale: nativeScale),
            CGSize(width: 1210, height: 834))
        XCTAssertEqual(NativeDrawableGeometry.size(viewSize: CGSize(width: 100.25, height: 200.75),
            screenSize: landscape, nativeSize: nativePortrait, nativeScale: nativeScale),
            CGSize(width: 172, height: 345))
        XCTAssertEqual(NativeDrawableGeometry.size(viewSize: CGSize(width: 0.1, height: 0.1),
            screenSize: landscape, nativeSize: nativePortrait, nativeScale: nativeScale),
            CGSize(width: 1, height: 1))
    }

    func testInvalidGeometryOrScaleDoesNotInventDrawableDimensions() {
        let invalidSizes = [CGSize.zero, CGSize(width: -1, height: 100),
                            CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.nan)]
        for invalid in invalidSizes {
            XCTAssertNil(NativeDrawableGeometry.size(viewSize: invalid, screenSize: landscape,
                nativeSize: nativePortrait, nativeScale: nativeScale))
            XCTAssertNil(NativeDrawableGeometry.size(viewSize: landscape, screenSize: invalid,
                nativeSize: nativePortrait, nativeScale: nativeScale))
            XCTAssertNil(NativeDrawableGeometry.size(viewSize: landscape, screenSize: landscape,
                nativeSize: invalid, nativeScale: nativeScale))
        }
        for invalid in [CGFloat(0), -1, .infinity, .nan] {
            XCTAssertNil(NativeDrawableGeometry.size(viewSize: landscape, screenSize: landscape,
                nativeSize: nativePortrait, nativeScale: invalid))
        }
        XCTAssertNil(NativeDrawableGeometry.size(viewSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100),
            screenSize: landscape, nativeSize: nativePortrait, nativeScale: 2))
    }

    func testIntegerInputMatchesNativePixelViewportAtFractionalScale() throws {
        let view = CGRect(origin: CGPoint(x: 10, y: 20), size: landscape)
        let transform = ViewportTransform(source: CGSize(width: 1080, height: 720),
            destination: CGRect(x: 0, y: 0, width: 2420, height: 1668), scaling: .integer)
        XCTAssertEqual(transform.viewport, CGRect(x: 130, y: 114, width: 2160, height: 1440))
        XCTAssertNil(transform.videoPoint(CGPoint(x: view.minX + 50, y: view.midY), from: view))
        // This point falls inside the 2x native-pixel viewport, even though it
        // would land in a letterbox if the scale were rounded in view points.
        let inside = try XCTUnwrap(transform.videoPoint(CGPoint(x: view.minX + 100, y: view.midY), from: view))
        XCTAssertEqual(inside.x, (100 * 2420.0 / 1408.0 - 130) / 2, accuracy: 0.000_001)
        XCTAssertEqual(inside.y, 360, accuracy: 0.000_001)
        XCTAssertEqual(transform.videoPoint(CGPoint(x: view.midX, y: view.midY), from: view),
                       CGPoint(x: 540, y: 360))
    }

    func testFitAndFillMapThroughDrawableWithoutChangingSourceCoordinates() throws {
        let view = CGRect(x: 12, y: 24, width: 1000, height: 700)
        let drawable = CGRect(x: 5, y: 9, width: 1750, height: 1225)
        for scaling in [VideoScaling.fit, .fill] {
            let points = ViewportTransform(source: CGSize(width: 1920, height: 1080), destination: view, scaling: scaling)
            let pixels = ViewportTransform(source: CGSize(width: 1920, height: 1080), destination: drawable, scaling: scaling)
            for point in [CGPoint(x: view.midX, y: view.midY), CGPoint(x: 212, y: 324)] {
                let expected = try XCTUnwrap(points.videoPoint(point))
                let actual = try XCTUnwrap(pixels.videoPoint(point, from: view))
                XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001)
                XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001)
            }
            XCTAssertNil(pixels.videoPoint(CGPoint(x: view.minX - 1, y: view.midY), from: view))
        }
    }

    func testMappedInputRejectsInvalidViewBoundsAndPoints() {
        let transform = ViewportTransform(source: CGSize(width: 1920, height: 1080),
            destination: CGRect(x: 0, y: 0, width: 2420, height: 1668))
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 100),
                       CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
                       CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan)] {
            XCTAssertNil(transform.videoPoint(CGPoint(x: 50, y: 50), from: bounds))
        }
        XCTAssertNil(transform.videoPoint(CGPoint(x: CGFloat.nan, y: 20), from: CGRect(origin: .zero, size: landscape)))
        XCTAssertNil(transform.videoPoint(CGPoint(x: 20, y: CGFloat.infinity), from: CGRect(origin: .zero, size: landscape)))
        let invalidDestination = ViewportTransform(source: CGSize(width: 1920, height: 1080), destination: .zero)
        XCTAssertNil(invalidDestination.videoPoint(CGPoint(x: 20, y: 20), from: CGRect(origin: .zero, size: landscape)))
    }
}
