import Testing
import SwiftlightTransport
import SwiftlightVideo
@testable import SwiftlightApp

struct TransportHDRColorTests {
    private let metadata = TransportHDRMetadata(redX: 34000, redY: 16000, greenX: 13250, greenY: 34500,
        blueX: 7500, blueY: 3000, whiteX: 15635, whiteY: 16450, maxDisplayLuminance: 730,
        minDisplayLuminance: 1, maxContentLightLevel: 600, maxFrameAverageLightLevel: 300, maxFullFrameLuminance: 400)

    @Test func hevcAndAV1ReceiveOnlyTheCapturedHDRMetadata() throws {
        for codec in [VideoCodec.hevc, .av1] {
            let color = try #require(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: metadata))
            #expect(!color.hasColorDescription && !color.hasRange && !color.hasChromaLocation)
            let diagnostic = DecodedColorDiagnostics(color: color)
            #expect(diagnostic.masteringDisplay?.maximumLuminanceNits == 730)
            #expect(diagnostic.masteringDisplay?.minimumLuminanceNits == 0.0001)
            #expect(diagnostic.masteringDisplay?.green.x == 0.265)
            #expect(diagnostic.masteringDisplay?.red.x == 0.68)
            #expect(diagnostic.contentLight?.maximumContentLightLevelNits == 600)
            #expect(diagnostic.contentLight?.maximumFrameAverageLightLevelNits == 300)
        }
    }

    @Test func inactiveOrUnavailableHostMetadataDoesNotBecomeAnHDRLabel() {
        let unavailable = TransportHDRMetadata(redX: 0, redY: 0, greenX: 0, greenY: 0,
            blueX: 0, blueY: 0, whiteX: 0, whiteY: 0, maxDisplayLuminance: 0,
            minDisplayLuminance: 0, maxContentLightLevel: 0, maxFrameAverageLightLevel: 0, maxFullFrameLuminance: 0)
        for codec in [VideoCodec.hevc, .av1] {
            #expect(StreamingPipeline.transportColor(codec: codec, hdrActive: false, metadata: metadata) == nil)
            #expect(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: nil) == nil)
            #expect(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: unavailable) == nil)
        }
    }

    @Test func missingContentLightRemainsUnavailableWhileMasteringIsPreserved() throws {
        let masteringOnly = TransportHDRMetadata(redX: metadata.redX, redY: metadata.redY,
            greenX: metadata.greenX, greenY: metadata.greenY, blueX: metadata.blueX, blueY: metadata.blueY,
            whiteX: metadata.whiteX, whiteY: metadata.whiteY, maxDisplayLuminance: metadata.maxDisplayLuminance,
            minDisplayLuminance: metadata.minDisplayLuminance, maxContentLightLevel: 0,
            maxFrameAverageLightLevel: 0, maxFullFrameLuminance: 0)
        let color = try #require(StreamingPipeline.transportColor(codec: .hevc, hdrActive: true, metadata: masteringOnly))
        #expect(color.mastering.count == 24 && color.contentLight.isEmpty)
    }

    @Test func pyrowaveRetainsItsExplicitNegotiatedInterpretation() throws {
        let color = try #require(StreamingPipeline.transportColor(codec: .pyrowave, hdrActive: true, metadata: metadata))
        #expect(color == StreamingPipeline.pyrowaveColor(hdrActive: true, metadata: metadata))
        #expect(color.hasColorDescription && color.hasRange && color.hasChromaLocation)
        #expect(color.transfer == 16 && color.primaries == 9 && color.matrix == 9 && color.chromaLocation == 1)
    }

    @Test func invalidMasteringBlocksAreOmittedWithoutLosingValidContentLight() throws {
        var invalid = [updatedMetadata(maxDisplay: 0), updatedMetadata(minDisplay: 10_001, maxDisplay: 1),
            updatedMetadata(chromaticities: Array(repeating: 0, count: 8))]
        for index in 0..<8 {
            var coordinates = [metadata.redX, metadata.redY, metadata.greenX, metadata.greenY,
                metadata.blueX, metadata.blueY, metadata.whiteX, metadata.whiteY]
            coordinates[index] = 50_001
            invalid.append(updatedMetadata(chromaticities: coordinates))
        }
        for codec in VideoCodec.allCases {
            for value in invalid {
                let color = try #require(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: value))
                #expect(color.mastering.isEmpty && color.contentLight == [0x02, 0x58, 0x01, 0x2C])
            }
        }
    }

    @Test func invalidContentLightBlocksAreOmittedWithoutLosingValidMastering() throws {
        for codec in VideoCodec.allCases {
            for value in [updatedMetadata(maxCLL: 0, maxFALL: 0), updatedMetadata(maxFALL: 601)] {
                let color = try #require(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: value))
                #expect(color.mastering.count == 24 && color.contentLight.isEmpty)
            }
        }
    }

    @Test func metadataBoundsAndMissingOptionalAverageAreAccepted() throws {
        let boundary = updatedMetadata(chromaticities: [50_000, 0, 0, 50_000, 0, 0, 15_635, 16_450],
            minDisplay: 10_000, maxDisplay: 1, maxCLL: UInt16.max, maxFALL: UInt16.max)
        for codec in VideoCodec.allCases {
            let color = try #require(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: boundary))
            #expect(color.mastering.count == 24 && color.contentLight == [255, 255, 255, 255])
            let diagnostic = DecodedColorDiagnostics(color: color)
            #expect(diagnostic.masteringDisplay?.minimumLuminanceNits == 1)
            #expect(diagnostic.masteringDisplay?.maximumLuminanceNits == 1)
            let missingAverage = try #require(StreamingPipeline.transportColor(codec: codec, hdrActive: true,
                metadata: updatedMetadata(minDisplay: 0, maxDisplay: UInt16.max, maxFALL: 0)))
            #expect(missingAverage.contentLight == [0x02, 0x58, 0, 0])
            #expect(DecodedColorDiagnostics(color: missingAverage).masteringDisplay?.maximumLuminanceNits == 65_535)
            let unknownPeak = try #require(StreamingPipeline.transportColor(codec: codec, hdrActive: true,
                metadata: updatedMetadata(maxCLL: 0)))
            #expect(unknownPeak.contentLight == [0, 0, 0x01, 0x2C])
        }
    }

    @Test func invalidOptionalBlocksLeaveNoHEVCOrAV1Fallback() {
        let invalid = updatedMetadata(chromaticities: Array(repeating: 0, count: 8), maxFALL: 601)
        for codec in [VideoCodec.hevc, .av1] {
            #expect(StreamingPipeline.transportColor(codec: codec, hdrActive: true, metadata: invalid) == nil)
        }
        let pyrowave = StreamingPipeline.pyrowaveColor(hdrActive: true, metadata: invalid)
        #expect(pyrowave.mastering.isEmpty && pyrowave.contentLight.isEmpty && pyrowave.transfer == 16)
    }

    private func updatedMetadata(chromaticities: [UInt16]? = nil, minDisplay: UInt16? = nil,
                                 maxDisplay: UInt16? = nil, maxCLL: UInt16? = nil, maxFALL: UInt16? = nil) -> TransportHDRMetadata {
        let c = chromaticities ?? [metadata.redX, metadata.redY, metadata.greenX, metadata.greenY,
            metadata.blueX, metadata.blueY, metadata.whiteX, metadata.whiteY]
        return TransportHDRMetadata(redX: c[0], redY: c[1], greenX: c[2], greenY: c[3],
            blueX: c[4], blueY: c[5], whiteX: c[6], whiteY: c[7], maxDisplayLuminance: maxDisplay ?? metadata.maxDisplayLuminance,
            minDisplayLuminance: minDisplay ?? metadata.minDisplayLuminance, maxContentLightLevel: maxCLL ?? metadata.maxContentLightLevel,
            maxFrameAverageLightLevel: maxFALL ?? metadata.maxFrameAverageLightLevel, maxFullFrameLuminance: metadata.maxFullFrameLuminance)
    }
}
