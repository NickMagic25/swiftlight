import Foundation

/// Bounded public geometry/state observations, not a Direct-presentation verdict.
/// No view/layer names, contents, application text, or media are retained.
struct PresentationHierarchyDiagnostics: Codable, Sendable {
    struct Rect: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    struct ViewState: Codable, Sendable {
        let depth: Int
        let alpha: Double?
        let opaque: Bool
        let hidden: Bool
        let clipsToBounds: Bool
        let transformIsIdentity: Bool
        let boundsInWindow: Rect?
    }
    struct LayerState: Codable, Sendable {
        let depth: Int
        let opacity: Double?
        let opaque: Bool
        let hidden: Bool
        let bounds: Rect?
        let surfaceInBounds: Rect?
        let boundsContainSurface: Bool?
        let masksToBounds: Bool
        let hasMask: Bool
        let cornerRadius: Double?
        let shadowOpacity: Double?
        let shadowRadius: Double?
        let shadowOffsetX: Double?
        let shadowOffsetY: Double?
        let hasShadowPath: Bool
        let shouldRasterize: Bool
        let rasterizationScale: Double?
        let transformIsIdentity: Bool
        let sublayerTransformIsIdentity: Bool
        let allowsGroupOpacity: Bool
        let hasCompositingFilter: Bool
        let hasFilters: Bool
        let hasBackgroundFilters: Bool
    }
    struct PotentialOverlap: Codable, Sendable {
        let parentDepth: Int
        let boundsInSurface: Rect?
        let opacity: Double?
        let opaque: Bool
        let hasMask: Bool
        let cornerRadius: Double?
        let hasShadow: Bool
    }
    let capturedAtMediaTimeSeconds: Double
    let validSurfaceGeometry: Bool
    let surfaceInWindow: Rect?
    let windowBounds: Rect?
    let surfaceInScreen: Rect?
    let screenBounds: Rect?
    let coversWindow: Bool?
    let coversScreen: Bool?
    let views: [ViewState]
    let layers: [LayerState]
    /// Bounds intersections are possible overlaps, not proof of visible pixels.
    let aboveSiblings: [PotentialOverlap]
    let inspectedSiblingCount: Int
    let potentialOverlapCount: Int
    let viewAncestorsTruncated: Bool
    let layerAncestorsTruncated: Bool
    let siblingInspectionTruncated: Bool
    let overlapRecordsTruncated: Bool
    let higherLevelWindowOverlapCount: Int
    let sameLevelOtherWindowOverlapCount: Int
    let appWindowsTruncated: Bool
}
