#if os(iOS)
import QuartzCore
import SwiftlightVideo
import UIKit

/// Capabilities of the screen that owns this window, rather than UIScreen.main.
/// Current headroom may be 1 before an EDR layer is enabled; negotiation uses
/// potential headroom. Missing or invalid observations remain unavailable.
struct MobileHDRDisplayCapabilities: Equatable, Sendable {
    let potentialHeadroom: Double?
    let currentHeadroom: Double?
    let systemToneMappingAvailable: Bool

    var supportsHDR: Bool { systemToneMappingAvailable && (potentialHeadroom ?? 1) > 1 }

    @MainActor static func capture(from window: UIWindow?) -> Self {
        guard let screen = window?.windowScene?.screen else {
            return Self(potentialHeadroom: nil, currentHeadroom: nil, systemToneMappingAvailable: false)
        }
        func validHeadroom(_ value: CGFloat) -> Double? {
            value.isFinite && value >= 1 ? Double(value) : nil
        }
        return Self(potentialHeadroom: validHeadroom(screen.potentialEDRHeadroom),
                    currentHeadroom: validHeadroom(screen.currentEDRHeadroom),
                    systemToneMappingAvailable: CAEDRMetadata.isAvailable)
    }
}

/// Narrow UIKit edge for the production renderer's extended-linear sRGB output
/// and its explicitly enabled diagnostic PQ output.
/// Call before acquiring the drawable for this frame. If a display-link drawable
/// is already acquired and this returns true, use the next drawable instead.
@MainActor struct MobileHDRLayerState {
    private var metadataState = HDRMetadataState()
    private(set) var outputColorSpace = VideoOutputColorSpace.linearSRGB

    @discardableResult mutating func apply(color: VideoColor, to layer: CAMetalLayer,
                                          nativePQOutput: Bool = false) throws -> Bool {
        // Reuse the shared renderer's canonical PQ path only for matching HDR10
        // signaling. SDR and other supported color formats keep linear output.
        let usePQ = nativePQOutput && color.transfer == 16 && color.primaries == 9 && color.matrix == 9
        let nextOutput: VideoOutputColorSpace = usePQ ? .rec2020PQ : .linearSRGB
        let outputChanged = nextOutput != outputColorSpace
        let metadata = HDRMetadataValue(color: color)
        let wantsEDR = metadata != .none
        guard !wantsEDR || CAEDRMetadata.isAvailable else {
            throw RendererFailure.unavailable("HDR tone mapping is unavailable on this device")
        }
        let metadataChanged = metadataState.value != metadata
        let enabledChanged = layer.wantsExtendedDynamicRangeContent != wantsEDR
        // The freshly created SDR layer already has the correct defaults. Avoid
        // dropping its first display-link drawable for a no-op configuration.
        guard outputChanged || enabledChanged || (metadataChanged && (wantsEDR || layer.edrMetadata != nil)) else {
            _ = metadataState.update(metadata)
            return false
        }
        let nextMetadata: CAEDRMetadata?
        switch metadata {
        case .none:
            nextMetadata = nil
        case .hdr10(let mastering, let contentLight):
            guard mastering.isEmpty || mastering.count == 24,
                  contentLight.isEmpty || contentLight.count == 4 else {
                throw RendererFailure.unsupportedColor("Invalid HDR10 mastering or content light metadata")
            }
            // Linear output uses 1.0 = 203 nits. Apple's normalized PQ format
            // assumes a 10,000-nit scale. Retain MDCV/CLLI in both experiments;
            // dropping HDR metadata would confound presentation and correctness.
            nextMetadata = .hdr10(displayInfo: mastering.isEmpty ? nil : mastering,
                                  contentInfo: contentLight.isEmpty ? nil : contentLight,
                                  opticalOutputScale: usePQ ? 10_000 : 203)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if outputChanged {
            layer.pixelFormat = usePQ ? .bgr10a2Unorm : .rgba16Float
            layer.colorspace = CGColorSpace(name: usePQ ? CGColorSpace.itur_2100_PQ : CGColorSpace.extendedLinearSRGB)
        }
        layer.wantsExtendedDynamicRangeContent = wantsEDR
        layer.edrMetadata = nextMetadata
        CATransaction.commit()
        _ = metadataState.update(metadata)
        outputColorSpace = nextOutput
        return true
    }

    mutating func reset(_ layer: CAMetalLayer) {
        metadataState = HDRMetadataState()
        guard layer.edrMetadata != nil || layer.wantsExtendedDynamicRangeContent || outputColorSpace != .linearSRGB else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.edrMetadata = nil
        layer.wantsExtendedDynamicRangeContent = false
        if outputColorSpace != .linearSRGB {
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            outputColorSpace = .linearSRGB
        }
        CATransaction.commit()
    }
}

#endif
