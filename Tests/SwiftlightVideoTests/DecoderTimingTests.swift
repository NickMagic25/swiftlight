import XCTest
@testable import SwiftlightVideo

final class DecoderTimingTests: XCTestCase {
    func testPyrowaveDecodeTimeRequiresOrderedRealTimestamps() {
        var statistics = DecoderStatistics()
        statistics.recordPyrowaveDecodeTime(admissionNanoseconds: 0, callbackNanoseconds: 1_000_000)
        statistics.recordPyrowaveDecodeTime(admissionNanoseconds: 2_000_000, callbackNanoseconds: 1_000_000)
        XCTAssertEqual(statistics.decodeTime.count, 0)
        XCTAssertNil(statistics.decodeTime.averageMilliseconds)
        statistics.recordPyrowaveDecodeTime(admissionNanoseconds: 1_000_000, callbackNanoseconds: 4_000_000)
        XCTAssertEqual(statistics.decodeTime.averageMilliseconds, 3)
        XCTAssertTrue(statistics.singleSampleVTSubmitToCallbackMilliseconds.isEmpty)
    }

    func testPyrowaveWindowStaysBoundedAndVTKeepsItsOwnPopulation() {
        var statistics = DecoderStatistics()
        statistics.singleSampleVTSubmitToCallbackMilliseconds = [2, 4]
        XCTAssertEqual(statistics.decodeTime.averageMilliseconds, 3)
        for index in 1...1030 {
            statistics.recordPyrowaveDecodeTime(admissionNanoseconds: 1,
                callbackNanoseconds: 1 + UInt64(index) * 1_000_000)
        }
        XCTAssertEqual(statistics.pyrowaveAdmissionToCallbackMilliseconds?.count, 1024)
        XCTAssertEqual(statistics.decodeTime.count, 1024)
        XCTAssertEqual(statistics.decodeTime.minimumMilliseconds, 7)
        XCTAssertEqual(statistics.decodeTime.maximumMilliseconds, 1030)
        XCTAssertEqual(statistics.singleSampleVTSubmitToCallbackMilliseconds, [2, 4])
    }

    func testOlderDiagnosticPopulationWithoutPyrowaveFieldStillDecodes() throws {
        var statistics = DecoderStatistics()
        statistics.singleSampleVTSubmitToCallbackMilliseconds = [2, 4]
        let bytes = try JSONEncoder().encode(statistics)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["pyrowaveAdmissionToCallbackMilliseconds"])
        let restored = try JSONDecoder().decode(DecoderStatistics.self, from: bytes)
        XCTAssertNil(restored.pyrowaveAdmissionToCallbackMilliseconds)
        XCTAssertEqual(restored.decodeTime.averageMilliseconds, 3)
    }
}
