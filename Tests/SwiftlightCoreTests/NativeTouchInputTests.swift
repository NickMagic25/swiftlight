import CoreGraphics
import XCTest
@testable import SwiftlightCore

final class NativeTouchInputTests: XCTestCase {
    private func geometry(_ scaling: VideoScaling = .fit) -> NativeTouchGeometry {
        NativeTouchGeometry(frameSize: CGSize(width: 1000, height: 800),
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            viewBounds: CGRect(x: 10, y: 20, width: 400, height: 400),
            drawableSize: CGSize(width: 800, height: 800), scaling: scaling)
    }

    private func contact(_ id: Int, _ x: CGFloat = 210, _ y: CGFloat = 220) -> TrackpadContact {
        TrackpadContact(id: id, position: CGPoint(x: x, y: y))
    }

    private func assertPoint(_ point: CGPoint?, x: CGFloat, y: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let point else { XCTFail("Expected a normalized point", file: file, line: line); return }
        XCTAssertEqual(point.x, x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.000001, file: file, line: line)
    }

    func testFitMapsApertureAndRejectsLetterboxes() {
        let mapping = geometry()
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 210, y: 220)), x: 0.5, y: 0.5)
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 10, y: 70)), x: 0.1, y: 0.125)
        XCTAssertNil(mapping.normalizedPoint(at: CGPoint(x: 210, y: 45)))
        XCTAssertNil(mapping.normalizedPoint(at: CGPoint(x: 210, y: 410)))
        XCTAssertNil(mapping.normalizedPoint(at: CGPoint(x: 9, y: 220)))
    }

    func testFillClampsToVisibleSubsetOfTheAperture() {
        let mapping = geometry(.fill)
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 210, y: 220)), x: 0.5, y: 0.5)
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: -100, y: -100), clamping: true), x: 0.2, y: 0.125)
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 800, y: 800), clamping: true), x: 0.8, y: 0.875)
        XCTAssertNil(mapping.normalizedPoint(at: CGPoint(x: -100, y: -100)))
    }

    func testIntegerViewportUsesDrawablePixelsRatherThanViewPoints() {
        let mapping = NativeTouchGeometry(frameSize: CGSize(width: 200, height: 100),
            contentRect: CGRect(x: 10, y: 20, width: 100, height: 60),
            viewBounds: CGRect(x: 10, y: 20, width: 100, height: 100),
            drawableSize: CGSize(width: 250, height: 250), scaling: .integer)
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 20, y: 46)), x: 0.05, y: 0.2)
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 60, y: 70)), x: 0.3, y: 0.5)
        XCTAssertNil(mapping.normalizedPoint(at: CGPoint(x: 60, y: 45)))
        assertPoint(mapping.normalizedPoint(at: CGPoint(x: 200, y: 200), clamping: true), x: 0.55, y: 0.8)
    }

    func testInvalidCoordinatesAndGeometryCannotReachTheWire() {
        let mapping = geometry()
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: -CGFloat.infinity, y: 0)] {
            XCTAssertNil(mapping.normalizedPoint(at: point))
            XCTAssertNil(mapping.normalizedPoint(at: point, clamping: true))
        }
        let invalidMappings = [
            NativeTouchGeometry(frameSize: .zero, contentRect: .zero, viewBounds: .zero, drawableSize: .zero, scaling: .fit),
            NativeTouchGeometry(frameSize: CGSize(width: 1000, height: 800),
                contentRect: CGRect(x: -1, y: 0, width: 800, height: 600),
                viewBounds: mapping.viewBounds, drawableSize: mapping.drawableSize, scaling: .fit),
            NativeTouchGeometry(frameSize: mapping.frameSize,
                contentRect: CGRect(x: 100, y: 100, width: 1000, height: 600),
                viewBounds: mapping.viewBounds, drawableSize: mapping.drawableSize, scaling: .fit),
            NativeTouchGeometry(frameSize: mapping.frameSize, contentRect: mapping.contentRect,
                viewBounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400),
                drawableSize: mapping.drawableSize, scaling: .fit),
            NativeTouchGeometry(frameSize: mapping.frameSize, contentRect: mapping.contentRect,
                viewBounds: mapping.viewBounds, drawableSize: CGSize(width: CGFloat.nan, height: 800), scaling: .fill)
        ]
        for invalid in invalidMappings {
            XCTAssertNil(invalid.normalizedPoint(at: CGPoint(x: 210, y: 220)))
            XCTAssertNil(invalid.normalizedPoint(at: CGPoint(x: 210, y: 220), clamping: true))
        }
    }

    func testStableContactsClampMovesAndCompleteWithoutAnOrphan() {
        var state = NativeTouchInputState()
        let mapping = geometry()
        let down = state.consume([contact(42)], phase: .began, geometry: mapping)
        XCTAssertEqual(down, [.init(event: .down, id: 0, x: 0.5, y: 0.5)])
        let move = state.consume([contact(42, -100, -100)], phase: .moved, geometry: mapping)
        XCTAssertEqual(move.count, 1); XCTAssertEqual(move.first?.id, down.first?.id)
        XCTAssertEqual(move.first?.x, 0.1); XCTAssertEqual(move.first?.y, 0.125)
        let up = state.consume([contact(42, 800, 800)], phase: .ended, geometry: mapping)
        XCTAssertEqual(up, [.init(event: .up, id: 0, x: 0.9, y: 0.875)])
        XCTAssertEqual(state.activeContactCount, 0)
        XCTAssertEqual(state.consume([contact(42)], phase: .moved, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(42)], phase: .ended, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(42)], phase: .began, geometry: mapping).first?.id, 1)
    }

    func testRejectedAndDuplicateDownsDoNotCreateTouchEvents() {
        var state = NativeTouchInputState()
        let mapping = geometry()
        XCTAssertEqual(state.consume([contact(7, 210, 45)], phase: .began, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(7)], phase: .moved, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(7)], phase: .ended, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(8), contact(8)], phase: .began, geometry: mapping).count, 1)
        XCTAssertEqual(state.consume([contact(8)], phase: .began, geometry: mapping), [])
        XCTAssertEqual(state.activeContactCount, 1)
    }

    func testContactBoundAndWireIDRollover() {
        var state = NativeTouchInputState(nextPointerID: .max)
        let mapping = geometry()
        let contacts = (0..<12).map { contact($0, 210 + CGFloat($0), 220) }
        let downs = state.consume(contacts, phase: .began, geometry: mapping)
        XCTAssertEqual(downs.count, 10); XCTAssertEqual(state.activeContactCount, 10)
        XCTAssertEqual(downs.first?.id, .max); XCTAssertEqual(downs.dropFirst().first?.id, 0)
        XCTAssertEqual(Set(downs.map(\.id)).count, 10)
        XCTAssertEqual(state.consume([contact(11)], phase: .moved, geometry: mapping), [])
        XCTAssertEqual(state.reset().count, 10)
        XCTAssertEqual(state.activeContactCount, 0)
    }

    func testInvalidMoveOrEndRetainsLastKnownPositionForCompletion() {
        var state = NativeTouchInputState()
        let mapping = geometry()
        _ = state.consume([contact(5)], phase: .began, geometry: mapping)
        XCTAssertEqual(state.consume([contact(5, .nan, .infinity)], phase: .moved, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(5, .nan, .infinity)], phase: .ended, geometry: mapping),
            [.init(event: .up, id: 0, x: 0.5, y: 0.5)])
        XCTAssertEqual(state.activeContactCount, 0)
    }

    func testCancellationAndResetReleaseExactlyTheAdmittedContacts() {
        var state = NativeTouchInputState()
        let mapping = geometry()
        _ = state.consume([contact(1), contact(2)], phase: .began, geometry: mapping)
        XCTAssertEqual(state.consume([contact(1), contact(1), contact(99)], phase: .cancelled, geometry: mapping),
            [.init(event: .cancel, id: 0, x: 0.5, y: 0.5)])
        XCTAssertEqual(state.activeContactCount, 1)
        XCTAssertEqual(state.reset(), [.init(event: .cancel, id: 1, x: 0.5, y: 0.5)])
        XCTAssertEqual(state.reset(), [])
        XCTAssertEqual(state.consume([contact(2)], phase: .moved, geometry: mapping), [])
        XCTAssertEqual(state.consume([contact(2)], phase: .ended, geometry: mapping), [])
    }
}
