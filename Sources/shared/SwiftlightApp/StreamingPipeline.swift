import Foundation
import SwiftlightCore
import SwiftlightVideo
import SwiftlightTransport
import os

struct StreamRenderOptions: Codable, Equatable, Sendable {
    // A drawable must be acquired with the metadata for its selected frame.
    // Stable HDR frames reuse the layer state rather than rebuilding tone mapping.
    var cacheEDRMetadata = true
    var configureEDRBeforeAcquire = true
    var captureScheduledCallback = true
    var nativePQOutput = false
    /// Unresolved options use the shared Settings choice (PQ by default).
    /// The system mode is retained for internal baseline captures and fallbacks.
    var hdrPresentationMode: HDRPresentationMode = .systemToneMapped
    /// Native render-loop lifetime boundary; disable only in explicit debug A/B captures.
    var useFrameAutoreleasePool = true
    var showMetalHUD = false
    /// Diagnostic only; honored by the macOS surface in DEBUG builds.
    var useRootMetalLayer = false
    var hideEmptyOverlayContainer = false
    var useSwiftUIStatisticsOverlay = false

    func resolvingHDRPresentation(settings: StreamSettings) -> Self {
        var options = self
        #if DEBUG
        // Preserve explicit legacy capture/menu trials. Ordinary launches use
        // the shared Settings selection without changing pacing or hierarchy.
        if nativePQOutput {
            options.hdrPresentationMode = .nativePQ
        } else if hdrPresentationMode == .systemToneMapped {
            options.hdrPresentationMode = settings.effectiveHDRPresentationMode
        }
        #else
        // Release/archive builds honor the visible opt-in Settings control,
        // while legacy debug-only capture/menu flags cannot override it.
        options.hdrPresentationMode = settings.effectiveHDRPresentationMode
        #endif
        options.nativePQOutput = options.hdrPresentationMode == .nativePQ
        return options
    }
}

/// Fixed-size semantic color metadata, assembled only when diagnostics are captured.
/// No decoded image, host information, or frame identity enters this snapshot.
struct DecodedColorDiagnostics: Codable, Sendable {
    struct Chromaticity: Codable, Sendable {
        let x: Double
        let y: Double
    }
    struct MasteringDisplay: Codable, Sendable {
        let red: Chromaticity
        let green: Chromaticity
        let blue: Chromaticity
        let white: Chromaticity
        let minimumLuminanceNits: Double
        let maximumLuminanceNits: Double
    }
    struct ContentLight: Codable, Sendable {
        let maximumContentLightLevelNits: UInt16
        let maximumFrameAverageLightLevelNits: UInt16
    }
    let primaries: UInt16
    let transfer: UInt16
    let matrix: UInt16
    let fullRange: Bool
    let hasColorDescription: Bool
    let hasRange: Bool
    let chromaLocation: UInt8
    let masteringDisplay: MasteringDisplay?
    let contentLight: ContentLight?

    init(color: VideoColor) {
        primaries = color.primaries; transfer = color.transfer; matrix = color.matrix
        fullRange = color.fullRange; hasColorDescription = color.hasColorDescription
        hasRange = color.hasRange; chromaLocation = color.chromaLocation
        func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
                UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        if color.mastering.count == 24 {
            func xy(_ offset: Int) -> Chromaticity {
                Chromaticity(x: Double(u16(color.mastering, offset)) / 50_000,
                    y: Double(u16(color.mastering, offset + 2)) / 50_000)
            }
            // SMPTE ST 2086 orders the primary pairs G, B, R, followed by white.
            masteringDisplay = MasteringDisplay(red: xy(8), green: xy(0), blue: xy(4), white: xy(12),
                minimumLuminanceNits: Double(u32(color.mastering, 20)) / 10_000,
                maximumLuminanceNits: Double(u32(color.mastering, 16)) / 10_000)
        } else { masteringDisplay = nil }
        if color.contentLight.count == 4 {
            contentLight = ContentLight(maximumContentLightLevelNits: u16(color.contentLight, 0),
                maximumFrameAverageLightLevelNits: u16(color.contentLight, 2))
        } else { contentLight = nil }
    }
}

struct PresentationRuntimeDiagnostics: Codable, Sendable {
    let pacing: String
    let displaySyncEnabled: Bool?
    let maximumDrawableCount: Int
    let maximumGPUFramesInFlight: Int
    let displayRefreshHz: Double?
    let preferredFrameLatency: Float?
    let layerOpaque: Bool
    let presentsWithTransaction: Bool
    let nativeFullScreen: Bool
    let drawableWidth: Int
    let drawableHeight: Int
    let minimumRefreshInterval: Double?
    let maximumRefreshInterval: Double?
    let displayUpdateGranularity: Double?
    let cacheEDRMetadata: Bool
    var edrMetadataUpdates = 0
    var outputColorSpace = "linearSRGB"
    var layerPixelFormat = "rgba16Float"
    var metalLayerIsViewRoot = false
    var viewOpaque = false
    var windowOpaque: Bool? = nil
    var displaySyncControlSupported: Bool? = nil
    var displayMaximumFramesPerSecond: Int? = nil
    var preferredFrameRateMinimum: Float? = nil
    var preferredFrameRateMaximum: Float? = nil
    var preferredFrameRatePreferred: Float? = nil
    var wantsExtendedDynamicRangeContent: Bool? = nil
    var edrMetadataConfigured: Bool? = nil
    var displayPotentialEDRHeadroom: Double? = nil
    var displayCurrentEDRHeadroom: Double? = nil
    var viewWidthPoints: Double? = nil
    var viewHeightPoints: Double? = nil
    var viewContentScale: Double? = nil
    var layerContentsScale: Double? = nil
    var screenWidthPoints: Double? = nil
    var screenHeightPoints: Double? = nil
    var screenScale: Double? = nil
    var screenNativeScale: Double? = nil
    /// UIScreen native bounds retain the screen's native orientation.
    var screenNativeWidthPixels: Int? = nil
    var screenNativeHeightPixels: Int? = nil
    var presentationHierarchy: PresentationHierarchyDiagnostics? = nil
}

/// The lock protects only admission and the decoder reference. The decoder owns its
/// serialized API queue. A pull callback holds a strong owner until it has acquired
/// the AU; teardown closes admission, joins common-c, then destroys that owner.
final class StreamingPipeline: @unchecked Sendable {
    let renderOptions: StreamRenderOptions
    #if DEBUG
    /// Explicit capture checkpoints refresh a weak native surface on MainActor.
    /// This is never invoked by media workers or normal streaming publication.
    @MainActor var refreshPresentationDiagnostics: (@MainActor () -> Void)?
    #endif
    init(renderOptions: StreamRenderOptions = .init()) { self.renderOptions = renderOptions }
    private let lock = NSLock()
    private var decoder: VideoDecoder?
    private var accepting = true
    private var failure: String?
    private var renderer: MetalVideoRenderer?
    private var latestDecodedFormat: DecodedVideoFormat?
    private var negotiatedStream: VideoStreamDescription?
    private var latestViewport = CGSize.zero
    private var frameAvailableHandler: (@Sendable () -> Void)?
    private var presentationRuntime: PresentationRuntimeDiagnostics?
    private var edrMetadataUpdates = 0
    private var outputColorSpace = "linearSRGB"
    private var layerPixelFormat = "rgba16Float"
    private let signposter = OSSignposter(subsystem: "net.edrisil.swiftlight", category: "Video")
    func setup(_ description: VideoStreamDescription) -> Bool {
        let codec: VideoCodec
        switch description.videoFormat {
        case 0x100, 0x200, 0x400, 0x800: codec = .hevc
        case 0x1000, 0x2000, 0x4000, 0x8000: codec = .av1
        case 0x10000, 0x20000, 0x40000, 0x80000: codec = .pyrowave
        default: recordFailure("Host selected an unsupported video format."); return false
        }
        do {
            let color = VideoColor(primaries: description.bitDepth == 10 ? 9 : 1,
                transfer: description.bitDepth == 10 ? 16 : 1, matrix: description.bitDepth == 10 ? 9 : 1,
                fullRange: false, chromaLocation: 1)
            let newDecoder = try VideoDecoder(codec: codec, maxFramesInFlight: 2,
                width: description.width, height: description.height, bitDepth: description.bitDepth,
                chromaFormat: description.isYUV444 ? 3 : 1, fallbackColor: codec == .pyrowave ? color : nil)
            lock.lock()
            guard accepting else { lock.unlock(); try newDecoder.close(); return false }
            let old = decoder; decoder = newDecoder; negotiatedStream = description; latestDecodedFormat = nil
            newDecoder.setFrameAvailableHandler(frameAvailableHandler); lock.unlock()
            try old?.close(); return true
        } catch { recordFailure(String(describing: error)); return false }
    }
    func receive(_ input: CompressedVideoFrame) -> Bool {
        lock.lock(); let owner = accepting ? decoder : nil; lock.unlock()
        guard let owner else { return false }
        guard input.presentationTimeUs <= UInt64(Int64.max / 1000) else {
            recordFailure("Host supplied an invalid media timestamp."); return false
        }
        let interval = signposter.beginInterval("Acquire complete frame")
        defer { signposter.endInterval("Acquire complete frame", interval) }
        // The bridge maps common-c timestamps using its exact exported uptime epoch.
        let frame = CompressedFrame(bytes: input.data, id: input.frameID,
            presentationTimeNanoseconds: Int64(input.presentationTimeUs) * 1000,
            randomAccess: input.isIDR, arrivalNanoseconds: input.enqueueUptimeNanoseconds,
            firstPacketNanoseconds: input.receiveUptimeNanoseconds,
            transportTiming: TransportFrameTiming(lastRequiredPacketNanoseconds: input.lastRequiredPacketUptimeNanoseconds,
                fecReadyNanoseconds: input.fecReadyUptimeNanoseconds, queueOfferNanoseconds: input.queueOfferUptimeNanoseconds,
                handoffNanoseconds: input.handoffUptimeNanoseconds, payloadBytes: input.payloadBytes,
                partialFrame: input.transportPartial),
            hostProcessingMilliseconds: input.hostProcessingLatencyMilliseconds,
            pyrowaveFragments: input.pyrowaveFragments.map { .init(offset: $0.offset, size: $0.length, kind: $0.kind.rawValue) },
            pyrowaveCriticalPackets: UInt32(input.pyrowaveCriticalPackets),
            color: Self.transportColor(codec: owner.codec, hdrActive: input.hdrActive, metadata: input.hdrMetadata))
        var result = owner.submit(frame)
        if result == .wouldBlock {
            do {
                try owner.waitForCapacity(timeoutNanoseconds: 100_000_000)
                result = owner.submit(frame)
                if result == .wouldBlock {
                    // Capacity was available, so outstanding work may be holding a format
                    // change. Drain on this dedicated pull/control path, then retry same AU.
                    try owner.drain(); result = owner.submit(frame)
                }
            } catch { recordFailure("Decoder admission timed out: \(error)"); return false }
        }
        switch result {
        case .accepted: return true
        case .needsRandomAccess: return false
        case .wouldBlock: recordFailure("Decoder remained backpressured after a controlled drain."); return false
        case .rejected(let code):
            // Independent PyroWave frames recover on the next frame after loss or
            // malformed input; they never require an IDR or poison the session.
            if owner.canRecoverOnNextFrame(from: code) { return false }
            if owner.codec == .pyrowave { recordFailure("PyroWave decoder could not accept the host stream (\(code))."); return false }
            recordFailure("Decoder rejected the host stream (\(code)). Check the host encoder uses low-delay HEVC/AV1 without reordered HEVC B pictures."); return false
        }
    }
    func closeAdmission() { lock.lock(); accepting = false; lock.unlock() }
    /// Vibepollo's sequence header carries no authoritative color description.
    /// The transport captures host HDR state with this frame and requests Rec.709 SDR.
    static func pyrowaveColor(hdrActive: Bool, metadata: TransportHDRMetadata?) -> VideoColor {
        var color = VideoColor(primaries: hdrActive ? 9 : 1, transfer: hdrActive ? 16 : 1,
            matrix: hdrActive ? 9 : 1, fullRange: false, chromaLocation: 1)
        if let fallback = hdrMetadataFallback(hdrActive: hdrActive, metadata: metadata) {
            color.mastering = fallback.mastering; color.contentLight = fallback.contentLight
        }
        return color
    }
    /// HEVC/AV1 bitstream and VideoToolbox fields remain authoritative. Host control
    /// values fill only missing static HDR metadata on this captured access unit.
    static func transportColor(codec: VideoCodec, hdrActive: Bool, metadata: TransportHDRMetadata?) -> VideoColor? {
        if codec == .pyrowave { return pyrowaveColor(hdrActive: hdrActive, metadata: metadata) }
        return hdrMetadataFallback(hdrActive: hdrActive, metadata: metadata)
    }
    private static func hdrMetadataFallback(hdrActive: Bool, metadata: TransportHDRMetadata?) -> VideoColor? {
        guard hdrActive, let metadata else { return nil }
        func u16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
        func u32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        var color = VideoColor(hasColorDescription: false, hasRange: false, hasChromaLocation: false)
        let chromaticities = [metadata.greenX, metadata.greenY, metadata.blueX, metadata.blueY,
            metadata.redX, metadata.redY, metadata.whiteX, metadata.whiteY]
        let maximumLuminance = UInt32(metadata.maxDisplayLuminance) * 10_000
        // Optional control metadata must not reject an otherwise valid compressed
        // frame. Match the native metadata bounds and omit incomplete host blocks.
        if metadata.redX > 0, metadata.maxDisplayLuminance > 0,
           chromaticities.allSatisfy({ $0 <= 50_000 }), UInt32(metadata.minDisplayLuminance) <= maximumLuminance {
            color.mastering = chromaticities.flatMap(u16)
            color.mastering += u32(maximumLuminance)
            color.mastering += u32(UInt32(metadata.minDisplayLuminance))
        }
        if metadata.maxContentLightLevel > 0 || metadata.maxFrameAverageLightLevel > 0,
           metadata.maxContentLightLevel == 0 || metadata.maxFrameAverageLightLevel <= metadata.maxContentLightLevel {
            color.contentLight = u16(metadata.maxContentLightLevel) + u16(metadata.maxFrameAverageLightLevel)
        }
        guard !color.mastering.isEmpty || !color.contentLight.isEmpty else { return nil }
        return color
    }
    func close() {
        lock.lock(); accepting = false; let owner = decoder; decoder = nil; lock.unlock()
        try? owner?.close()
    }
    func takeLatestFrame() -> DecodedFrame? {
        lock.lock(); let owner = accepting ? decoder : nil; lock.unlock()
        return owner?.takeLatestFrame()
    }
    func setFrameAvailableHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        frameAvailableHandler = handler; decoder?.setFrameAvailableHandler(handler)
    }
    func recordPresentationRuntime(_ runtime: PresentationRuntimeDiagnostics) {
        lock.lock(); presentationRuntime = runtime; lock.unlock()
    }
    var presentationDiagnostics: PresentationRuntimeDiagnostics? {
        lock.lock(); defer { lock.unlock() }
        var result = presentationRuntime; result?.edrMetadataUpdates = edrMetadataUpdates
        result?.outputColorSpace = outputColorSpace; result?.layerPixelFormat = layerPixelFormat; return result
    }
    func recordEDRMetadataUpdate(nativePQ: Bool, wantsEDR: Bool? = nil, metadataConfigured: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }; edrMetadataUpdates += 1
        outputColorSpace = nativePQ ? "rec2020PQ" : "linearSRGB"
        layerPixelFormat = nativePQ ? "bgr10a2Unorm" : "rgba16Float"
        if let wantsEDR { presentationRuntime?.wantsExtendedDynamicRangeContent = wantsEDR }
        if let metadataConfigured { presentationRuntime?.edrMetadataConfigured = metadataConfigured }
    }
    var statistics: DecoderStatistics? {
        lock.lock(); let owner = decoder; lock.unlock(); return owner?.statistics
    }
    func reportRendererFailure() { recordFailure("Metal failed to complete video rendering. Reconnect after checking the display and GPU state.") }
    func attachRenderer(_ renderer: MetalVideoRenderer) { lock.lock(); self.renderer = renderer; lock.unlock() }
    func recordFrame(_ frame: DecodedFrame, viewport: CGSize) {
        lock.lock(); defer { lock.unlock() }
        if let codec = decoder?.codec { latestDecodedFormat = DecodedVideoFormat(codec: codec, frame: frame) }
        latestViewport = viewport
    }
    var decodedFormat: DecodedVideoFormat? { lock.lock(); defer { lock.unlock() }; return latestDecodedFormat }
    var decodedColorDiagnostics: DecodedColorDiagnostics? {
        decodedFormat.map { DecodedColorDiagnostics(color: $0.color) }
    }
    var streamDescription: VideoStreamDescription? { lock.lock(); defer { lock.unlock() }; return negotiatedStream }
    var decodedDetail: String {
        lock.lock(); let format = latestDecodedFormat, viewport = latestViewport; lock.unlock()
        guard let format else { return "Waiting for decoded output" }
        let chroma = StreamStatisticsSampler.chromaDescription(format.chromaFormat).map { " · \($0)" } ?? ""
        return "Decoded \(format.width) × \(format.height) · \(format.bitDepth)-bit\(chroma) · viewport \(Int(viewport.width)) × \(Int(viewport.height))"
    }
    var renderStatistics: RenderStatistics? { lock.lock(); let renderer = renderer; lock.unlock(); return renderer?.statistics }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    private func recordFailure(_ message: String) { lock.lock(); if failure == nil { failure = message }; lock.unlock() }
}
