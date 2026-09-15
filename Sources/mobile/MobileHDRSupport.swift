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

/// Narrow UIKit edge for the production renderer's extended-linear sRGB output.
/// Call before acquiring the drawable for this frame. If a display-link drawable
/// is already acquired and this returns true, use the next drawable instead.
@MainActor struct MobileHDRLayerState {
    private var metadataState = HDRMetadataState()

    @discardableResult mutating func apply(color: VideoColor, to layer: CAMetalLayer) throws -> Bool {
        let metadata = HDRMetadataValue(color: color)
        let wantsEDR = metadata != .none
        guard !wantsEDR || CAEDRMetadata.isAvailable else {
            throw RendererFailure.unavailable("HDR tone mapping is unavailable on this device")
        }
        let metadataChanged = metadataState.value != metadata
        let enabledChanged = layer.wantsExtendedDynamicRangeContent != wantsEDR
        // The freshly created SDR layer already has the correct defaults. Avoid
        // dropping its first display-link drawable for a no-op configuration.
        guard enabledChanged || (metadataChanged && (wantsEDR || layer.edrMetadata != nil)) else {
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
            // The renderer maps PQ to extended-linear sRGB with 1.0 = 203 nits.
            // Empty SEI metadata uses Apple's documented system defaults.
            nextMetadata = .hdr10(displayInfo: mastering.isEmpty ? nil : mastering,
                                  contentInfo: contentLight.isEmpty ? nil : contentLight,
                                  opticalOutputScale: 203)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.wantsExtendedDynamicRangeContent = wantsEDR
        layer.edrMetadata = nextMetadata
        CATransaction.commit()
        _ = metadataState.update(metadata)
        return true
    }

    mutating func reset(_ layer: CAMetalLayer) {
        metadataState = HDRMetadataState()
        guard layer.edrMetadata != nil || layer.wantsExtendedDynamicRangeContent else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.edrMetadata = nil
        layer.wantsExtendedDynamicRangeContent = false
        CATransaction.commit()
    }
}

#endif
