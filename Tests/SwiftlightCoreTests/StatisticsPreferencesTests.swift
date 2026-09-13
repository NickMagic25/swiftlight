import Foundation
import XCTest
@testable import SwiftlightCore

final class StatisticsPreferencesTests: XCTestCase {
    func testStatisticsDefaultToSimpleTopCenter() throws {
        let preferences = StreamStatisticsPreferences()
        XCTAssertEqual(preferences.detail, .simple)
        XCTAssertEqual(preferences.position, .top)
        XCTAssertEqual(try JSONDecoder().decode(StreamStatisticsPreferences.self, from: Data("{}".utf8)), preferences)
    }

    func testPartialAndUnknownChoicesPreserveIndependentPreferences() throws {
        let old = try JSONDecoder().decode(StreamStatisticsPreferences.self, from: Data("{\"detail\":\"detailed\"}".utf8))
        XCTAssertEqual(old, StreamStatisticsPreferences(detail: .detailed, position: .top))
        let newer = try JSONDecoder().decode(StreamStatisticsPreferences.self, from: Data("{\"detail\":\"future\",\"position\":\"topTrailing\"}".utf8))
        XCTAssertEqual(newer, StreamStatisticsPreferences(detail: .simple, position: .topTrailing))
        let unknownPosition = try JSONDecoder().decode(StreamStatisticsPreferences.self, from: Data("{\"detail\":\"detailed\",\"position\":\"bottom\"}".utf8))
        XCTAssertEqual(unknownPosition, StreamStatisticsPreferences(detail: .detailed, position: .top))
    }

    func testAllStatisticsChoicesRoundTripIndependentlyOfStreamSettings() throws {
        for detail in StreamStatisticsDetail.allCases {
            for position in StreamStatisticsPosition.allCases {
                let preferences = StreamStatisticsPreferences(detail: detail, position: position)
                let data = try JSONEncoder().encode(preferences)
                XCTAssertEqual(try JSONDecoder().decode(StreamStatisticsPreferences.self, from: data), preferences)
                let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
                XCTAssertEqual(Set(keys.keys), ["detail", "position"])
            }
        }
    }
}
