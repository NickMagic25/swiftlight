import Foundation
import XCTest
@testable import SwiftlightCore

final class MobileTouchSettingsTests: XCTestCase {
    func testMissingTouchModeDefaultsToTrackpadIndependentlyOfPointerMode() throws {
        XCTAssertEqual(StreamSettings().mobileTouchMode, .trackpad)
        for pointer in PointerMode.allCases {
            let saved = Data("{\"pointerMode\":\"\(pointer.rawValue)\"}".utf8)
            let settings = try JSONDecoder().decode(StreamSettings.self, from: saved)
            XCTAssertEqual(settings.pointerMode, pointer)
            XCTAssertEqual(settings.mobileTouchMode, .trackpad)
        }
    }

    func testTouchAndPointerChoicesRoundTripWithoutChangingStreamRequest() throws {
        let baseline = StreamSettings()
        for touch in MobileTouchMode.allCases {
            for pointer in PointerMode.allCases {
                var saved = baseline
                saved.mobileTouchMode = touch; saved.pointerMode = pointer
                let decoded = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(saved))
                XCTAssertEqual(decoded, saved)
                XCTAssertEqual(try decoded.request(display: .fallback), try baseline.request(display: .fallback))
            }
        }
    }

    func testTouchOnlyPreferencePreservesMouseDefault() throws {
        let saved = Data(#"{"mobileTouchMode":"nativeTouch"}"#.utf8)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: saved)
        XCTAssertEqual(decoded.mobileTouchMode, .nativeTouch)
        XCTAssertEqual(decoded.pointerMode, .relative)
    }

    func testInvalidTouchPreferenceFailsInsteadOfChangingInputMode() {
        for json in [#"{"mobileTouchMode":"absolute"}"#, #"{"mobileTouchMode":true}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8)))
        }
    }
}
