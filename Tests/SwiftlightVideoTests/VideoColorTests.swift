import Foundation
import MoonlightAppleVideo
import XCTest
@testable import SwiftlightVideo

final class VideoColorTests: XCTestCase {
    func testMetadataOnlyFallbackDoesNotSupplyColorRangeOrChromaSiting() {
        let color = VideoColor(mastering: Array(repeating: 0, count: 24), contentLight: [0, 100, 0, 50],
            hasColorDescription: false, hasRange: false, hasChromaLocation: false)
        XCTAssertEqual(color.native.valid, UInt32(MAV_COLOR_MASTERING | MAV_COLOR_CONTENT_LIGHT))
        let restored = VideoColor(color.native)
        XCTAssertFalse(restored.hasColorDescription)
        XCTAssertFalse(restored.hasRange)
        XCTAssertFalse(restored.hasChromaLocation)
        XCTAssertEqual(restored.native.valid, color.native.valid)
        XCTAssertEqual(restored.mastering, color.mastering)
        XCTAssertEqual(restored.contentLight, color.contentLight)
    }

    func testExplicitChromaSitingStillRoundTripsThroughTheABI() {
        let color = VideoColor(primaries: 9, transfer: 16, matrix: 9, fullRange: true, chromaLocation: 3)
        XCTAssertEqual(VideoColor(color.native), color)
        XCTAssertEqual(color.native.valid, UInt32(MAV_COLOR_DESCRIPTION | MAV_COLOR_RANGE | MAV_COLOR_CHROMA_LOCATION))
    }

    func testAbsentChromaSitingSurvivesSerialization() throws {
        let color = VideoColor(hasColorDescription: false, hasRange: false, hasChromaLocation: false)
        XCTAssertEqual(try JSONDecoder().decode(VideoColor.self, from: JSONEncoder().encode(color)), color)
    }

    func testOlderSerializedColorsRetainTheirPreviouslyExplicitSiting() throws {
        let color = VideoColor(chromaLocation: 4)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(color)) as? [String: Any])
        object.removeValue(forKey: "hasChromaLocation")
        let restored = try JSONDecoder().decode(VideoColor.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, color)
        XCTAssertNotEqual(restored.native.valid & UInt32(MAV_COLOR_CHROMA_LOCATION), 0)
    }
}
