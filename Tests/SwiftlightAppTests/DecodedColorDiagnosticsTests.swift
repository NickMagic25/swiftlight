import Foundation
import Testing
import SwiftlightVideo
@testable import SwiftlightApp

struct DecodedColorDiagnosticsTests {
    @Test func masteringAndContentLightRetainSemanticUnits() {
        // SMPTE ST 2086 golden payload: G, B, R, white; 1000 / 0.005 nits.
        let color = VideoColor(primaries: 9, transfer: 16, matrix: 9, fullRange: false,
            chromaLocation: 1,
            mastering: [0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8,
                0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40, 0x42,
                0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32],
            contentLight: [0x03, 0x84, 0x01, 0x90])
        let snapshot = DecodedColorDiagnostics(color: color)
        #expect(snapshot.primaries == 9 && snapshot.transfer == 16 && snapshot.matrix == 9)
        #expect(!snapshot.fullRange && snapshot.hasColorDescription && snapshot.hasRange)
        #expect(snapshot.chromaLocation == 1)
        #expect(snapshot.masteringDisplay?.red.x == 0.68)
        #expect(snapshot.masteringDisplay?.red.y == 0.32)
        #expect(snapshot.masteringDisplay?.green.x == 0.265)
        #expect(snapshot.masteringDisplay?.green.y == 0.69)
        #expect(snapshot.masteringDisplay?.blue.x == 0.15)
        #expect(snapshot.masteringDisplay?.blue.y == 0.06)
        #expect(snapshot.masteringDisplay?.white.x == 0.3127)
        #expect(snapshot.masteringDisplay?.white.y == 0.329)
        #expect(snapshot.masteringDisplay?.maximumLuminanceNits == 1000)
        #expect(snapshot.masteringDisplay?.minimumLuminanceNits == 0.005)
        #expect(snapshot.contentLight?.maximumContentLightLevelNits == 900)
        #expect(snapshot.contentLight?.maximumFrameAverageLightLevelNits == 400)
    }

    @Test func absentOrIncompleteMetadataRemainsUnavailable() throws {
        for length in [0, 23, 25] {
            let snapshot = DecodedColorDiagnostics(color: VideoColor(
                mastering: Array(repeating: 0, count: length), contentLight: [0, 1, 0],
                hasColorDescription: false, hasRange: false))
            #expect(snapshot.masteringDisplay == nil && snapshot.contentLight == nil)
            #expect(!snapshot.hasColorDescription && !snapshot.hasRange)
            let encoded = try JSONEncoder().encode(snapshot)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["masteringDisplay"] == nil && object["contentLight"] == nil)
        }
    }
}
