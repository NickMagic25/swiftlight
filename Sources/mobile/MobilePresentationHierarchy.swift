#if os(iOS)
import Foundation
import QuartzCore
import UIKit

/// No timer or per-frame traversal. Normal launches and Release return nil;
/// explicit debug captures reuse a cached scalar snapshot for at least a second.
@MainActor struct MobilePresentationHierarchyCapture {
    #if DEBUG
    private let enabled: Bool
    private var lastCaptureTime = -Double.infinity
    private var cached: PresentationHierarchyDiagnostics?

    init() {
        let environment = ProcessInfo.processInfo.environment
        enabled = environment["SWIFTLIGHT_LATENCY_CAPTURE"] == "1" &&
            ["baseline-off", "baseline-on", "candidate-off", "candidate-on"]
                .contains(environment["SWIFTLIGHT_LATENCY_TRIAL"] ?? "")
    }
    #else
    init() {}
    #endif

    mutating func capture(from view: UIView) -> PresentationHierarchyDiagnostics? {
        #if DEBUG
        guard enabled else { return nil }
        let now = CACurrentMediaTime()
        guard now - lastCaptureTime >= 1 else { return cached }
        lastCaptureTime = now
        cached = Self.snapshot(view, now: now)
        return cached
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite &&
            rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
    }
    private static func rectangle(_ rect: CGRect?) -> PresentationHierarchyDiagnostics.Rect? {
        guard let rect, valid(rect) else { return nil }
        return .init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }
    private static func contains(_ outer: CGRect?, _ inner: CGRect?) -> Bool? {
        guard let outer, let inner, valid(outer), valid(inner) else { return nil }
        return outer.contains(inner)
    }

    private static func snapshot(_ view: UIView, now: Double) -> PresentationHierarchyDiagnostics {
        let window = view.window
        let screen = window?.windowScene?.screen
        let inWindow = window.map { view.convert(view.bounds, to: $0) }
        let inScreen: CGRect?
        if let window, let screen, let inWindow { inScreen = window.convert(inWindow, to: screen.coordinateSpace) }
        else { inScreen = nil }
        var views: [PresentationHierarchyDiagnostics.ViewState] = []
        var ancestor: UIView? = view
        while let current = ancestor, views.count < 16 {
            views.append(.init(depth: views.count, alpha: finite(Double(current.alpha)), opaque: current.isOpaque,
                hidden: current.isHidden, clipsToBounds: current.clipsToBounds,
                transformIsIdentity: current.transform.isIdentity,
                boundsInWindow: rectangle(window.map { current.convert(current.bounds, to: $0) })))
            ancestor = current.superview
        }

        var layers: [PresentationHierarchyDiagnostics.LayerState] = []
        var overlaps: [PresentationHierarchyDiagnostics.PotentialOverlap] = []
        var layer: CALayer? = view.layer
        var inspected = 0, overlapCount = 0
        var siblingsTruncated = false
        while let current = layer, layers.count < 16 {
            let surface = view.layer.convert(view.layer.bounds, to: current)
            let depth = layers.count
            layers.append(.init(depth: depth, opacity: finite(Double(current.opacity)), opaque: current.isOpaque,
                hidden: current.isHidden, bounds: rectangle(current.bounds), surfaceInBounds: rectangle(surface),
                boundsContainSurface: contains(current.bounds, surface), masksToBounds: current.masksToBounds,
                hasMask: current.mask != nil, cornerRadius: finite(Double(current.cornerRadius)),
                shadowOpacity: finite(Double(current.shadowOpacity)), shadowRadius: finite(Double(current.shadowRadius)),
                shadowOffsetX: finite(Double(current.shadowOffset.width)), shadowOffsetY: finite(Double(current.shadowOffset.height)),
                hasShadowPath: current.shadowPath != nil, shouldRasterize: current.shouldRasterize,
                rasterizationScale: finite(Double(current.rasterizationScale)),
                transformIsIdentity: CATransform3DIsIdentity(current.transform),
                sublayerTransformIsIdentity: CATransform3DIsIdentity(current.sublayerTransform),
                allowsGroupOpacity: current.allowsGroupOpacity, hasCompositingFilter: current.compositingFilter != nil,
                hasFilters: !(current.filters?.isEmpty ?? true), hasBackgroundFilters: !(current.backgroundFilters?.isEmpty ?? true)))
            if let siblings = current.superlayer?.sublayers {
                let remaining = max(0, 64 - inspected)
                if siblings.count > remaining { siblingsTruncated = true }
                var passedCurrent = false
                for sibling in siblings.prefix(remaining) {
                    inspected += 1
                    if sibling === current { passedCurrent = true; continue }
                    let above = sibling.zPosition > current.zPosition ||
                        (sibling.zPosition == current.zPosition && passedCurrent)
                    guard above, !sibling.isHidden, sibling.opacity > 0 else { continue }
                    let siblingBounds = sibling.convert(sibling.bounds, to: view.layer)
                    guard valid(siblingBounds), valid(view.layer.bounds), siblingBounds.intersects(view.layer.bounds) else { continue }
                    overlapCount += 1
                    if overlaps.count < 8 {
                        overlaps.append(.init(parentDepth: depth + 1, boundsInSurface: rectangle(siblingBounds),
                            opacity: finite(Double(sibling.opacity)), opaque: sibling.isOpaque, hasMask: sibling.mask != nil,
                            cornerRadius: finite(Double(sibling.cornerRadius)), hasShadow: sibling.shadowOpacity > 0))
                    }
                }
            }
            layer = current.superlayer
        }

        let windows = window?.windowScene?.windows ?? []
        var higher = 0, same = 0
        if let window, let inScreen, valid(inScreen), let screen {
            for other in windows.prefix(16) where other !== window && !other.isHidden && other.alpha > 0 {
                let otherBounds = other.convert(other.bounds, to: screen.coordinateSpace)
                guard valid(otherBounds), otherBounds.intersects(inScreen) else { continue }
                if other.windowLevel > window.windowLevel { higher += 1 }
                else if other.windowLevel == window.windowLevel { same += 1 }
            }
        }
        return .init(capturedAtMediaTimeSeconds: now, validSurfaceGeometry: valid(view.bounds) && inScreen.map { valid($0) } == true,
            surfaceInWindow: rectangle(inWindow), windowBounds: rectangle(window?.bounds),
            surfaceInScreen: rectangle(inScreen), screenBounds: rectangle(screen?.bounds),
            coversWindow: contains(inWindow, window?.bounds), coversScreen: contains(inScreen, screen?.bounds),
            views: views, layers: layers, aboveSiblings: overlaps, inspectedSiblingCount: inspected,
            potentialOverlapCount: overlapCount, viewAncestorsTruncated: ancestor != nil, layerAncestorsTruncated: layer != nil,
            siblingInspectionTruncated: siblingsTruncated, overlapRecordsTruncated: overlapCount > overlaps.count,
            higherLevelWindowOverlapCount: higher, sameLevelOtherWindowOverlapCount: same, appWindowsTruncated: windows.count > 16)
    }
    #endif
}
#endif
