import XCTest
@testable import SwiftlightVideo

final class HDRMetadataTests: XCTestCase {
    func testStableHDRAndNonMetadataColorChangesDoNotMutateLayerState() {
        var state = HDRMetadataState()
        var color = VideoColor(primaries: 9, transfer: 16, matrix: 9, mastering: [1, 2], contentLight: [3, 4])
        XCTAssertTrue(state.update(HDRMetadataValue(color: color)))
        XCTAssertFalse(state.update(HDRMetadataValue(color: color)))
        color.fullRange = true; color.chromaLocation = 2
        XCTAssertFalse(state.update(HDRMetadataValue(color: color)))
        color.contentLight = [5, 6]
        XCTAssertTrue(state.update(HDRMetadataValue(color: color)))
        color.mastering = [7, 8]
        XCTAssertTrue(state.update(HDRMetadataValue(color: color)))
        color.transfer = 1
        XCTAssertTrue(state.update(HDRMetadataValue(color: color)))
        XCTAssertEqual(state.value, HDRMetadataValue.none)
        XCTAssertFalse(state.update(HDRMetadataValue(color: color)))
    }
}
