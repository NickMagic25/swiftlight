import Testing
import SwiftlightTransport
@testable import SwiftlightApp

struct PyrowaveColorTests {
    @Test func actualHostModeAndMetadataDefineTheFrameColor() {
        let metadata = TransportHDRMetadata(redX: 34000, redY: 16000, greenX: 13250, greenY: 34500,
            blueX: 7500, blueY: 3000, whiteX: 15635, whiteY: 16450, maxDisplayLuminance: 1000,
            minDisplayLuminance: 50, maxContentLightLevel: 900, maxFrameAverageLightLevel: 400, maxFullFrameLuminance: 400)
        let hdr = StreamingPipeline.pyrowaveColor(hdrActive: true, metadata: metadata)
        #expect(hdr.primaries == 9 && hdr.matrix == 9 && hdr.transfer == 16)
        #expect(!hdr.fullRange && hdr.chromaLocation == 1)
        // SMPTE2086 wire ordering is G, B, R, white, then max/min in 1/10000 nit.
        #expect(hdr.mastering == [0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8,
            0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32])
        #expect(hdr.contentLight == [0x03, 0x84, 0x01, 0x90])
        let sdr = StreamingPipeline.pyrowaveColor(hdrActive: false, metadata: metadata)
        #expect(sdr.primaries == 1 && sdr.matrix == 1 && sdr.transfer == 1)
        #expect(!sdr.fullRange && sdr.mastering.isEmpty && sdr.contentLight.isEmpty)
        let unknownMetadata = StreamingPipeline.pyrowaveColor(hdrActive: true, metadata: nil)
        #expect(unknownMetadata.transfer == 16 && unknownMetadata.mastering.isEmpty)
    }
}
