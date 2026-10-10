import Foundation

public struct TrackpadContact: Equatable, Sendable {
    public let id: Int
    public let position: CGPoint
    public init(id: Int, position: CGPoint) { self.id = id; self.position = position }
}
public enum TrackpadTouchPhase: Equatable, Sendable { case began, moved, ended, cancelled }
public enum TrackpadAction: Equatable, Sendable {
    case move(dx: Int16, dy: Int16)
    case button(button: Int, pressed: Bool)
    case scroll(vertical: Int16, horizontal: Int16)
}

/// Relative finger input, independent of UIKit and host geometry. Each batch
/// contains changed contacts; IDs remain stable until they end or are cancelled.
/// Three-finger gestures belong to local UI and suppress this entire gesture.
public struct TrackpadInputState: Sendable {
    private struct Contact: Sendable {
        let start: CGPoint
        var position: CGPoint
    }
    private var contacts: [Int: Contact] = [:]
    private var gestureStartedAt: TimeInterval?
    private var lastEventAt: TimeInterval?
    private var lastTapAt: TimeInterval?
    private var peakContacts = 0
    private var tapEligible = false
    private var suppressed = false
    private var leftHeld = false
    private var scrolling = false
    private var scrollAnchor: CGPoint?
    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0
    private static let maximumContacts = 10
    private static let tapTolerance: CGFloat = 6
    private static let maximumTapDuration: TimeInterval = 0.3
    private static let doubleTapInterval: TimeInterval = 0.25

    public init() {}

    public mutating func consume(_ changed: [TrackpadContact], phase: TrackpadTouchPhase,
                                 at timestamp: TimeInterval) -> [TrackpadAction] {
        guard timestamp.isFinite, timestamp >= 0, changed.count <= Self.maximumContacts,
              changed.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite }),
              Set(changed.map(\.id)).count == changed.count else { return reset() }
        if let lastEventAt, timestamp < lastEventAt { return [] }
        if phase == .cancelled {
            // A late cancellation of an unknown touch cannot cancel a new drag.
            guard changed.isEmpty || changed.contains(where: { contacts[$0.id] != nil }) else { return [] }
            return reset()
        }
        switch phase {
        case .began:
            let added = changed.filter { contacts[$0.id] == nil }
            guard !added.isEmpty else { return [] }
            guard contacts.count + added.count <= Self.maximumContacts else { return reset() }
            let previousCount = contacts.count
            let startsDrag = previousCount == 0 && added.count == 1 && lastTapAt.map {
                timestamp >= $0 && timestamp - $0 <= Self.doubleTapInterval
            } == true
            if previousCount == 0 {
                gestureStartedAt = timestamp; peakContacts = 0
                tapEligible = true; suppressed = false; lastTapAt = nil
                resetMotion()
            }
            for touch in added { contacts[touch.id] = Contact(start: touch.position, position: touch.position) }
            peakContacts = max(peakContacts, contacts.count)
            lastEventAt = timestamp
            if peakContacts >= 3 {
                suppressed = true; tapEligible = false; lastTapAt = nil
                resetMotion()
                return releaseDrag()
            }
            if contacts.count == 2 && previousCount < 2 {
                let actions = releaseDrag()
                if !actions.isEmpty { tapEligible = false }
                lastTapAt = nil; resetMotion(); scrollAnchor = centroid()
                return actions
            }
            if startsDrag {
                leftHeld = true; tapEligible = false
                return [.button(button: 1, pressed: true)]
            }
            return []
        case .moved, .ended:
            let known = changed.filter { contacts[$0.id] != nil }
            guard !known.isEmpty else { return [] }
            let previousPoint = contacts.count == 1 ? contacts.values.first?.position : nil
            for touch in known {
                guard var contact = contacts[touch.id] else { continue }
                contact.position = touch.position; contacts[touch.id] = contact
                let dx = contact.position.x - contact.start.x, dy = contact.position.y - contact.start.y
                if dx * dx + dy * dy > Self.tapTolerance * Self.tapTolerance { tapEligible = false }
            }
            lastEventAt = timestamp
            if phase == .ended {
                for touch in known { contacts[touch.id] = nil }
                guard contacts.isEmpty else { resetMotion(); return [] }
                var actions = releaseDrag()
                if !suppressed, tapEligible, let started = gestureStartedAt,
                   timestamp - started <= Self.maximumTapDuration {
                    let button = peakContacts == 2 ? 3 : 1
                    actions += [.button(button: button, pressed: true), .button(button: button, pressed: false)]
                    if peakContacts == 1 { lastTapAt = timestamp }
                }
                gestureStartedAt = nil; peakContacts = 0
                tapEligible = false; suppressed = false; resetMotion()
                return actions
            }
            guard !suppressed else { return [] }
            if peakContacts == 1, contacts.count == 1, let previousPoint,
               let point = contacts.values.first?.position {
                let dx = point.x - previousPoint.x, dy = point.y - previousPoint.y
                guard dx.isFinite, dy.isFinite else { return reset() }
                let x = Self.quantize(dx, remainder: &remainderX), y = Self.quantize(dy, remainder: &remainderY)
                return x == 0 && y == 0 ? [] : [.move(dx: x, dy: y)]
            }
            if peakContacts == 2, contacts.count == 2, let point = centroid(), let anchor = scrollAnchor {
                // Keep small tap jitter from also scrolling. Once either finger
                // moves beyond tap tolerance, accumulated centroid motion scrolls.
                if !tapEligible { scrolling = true }
                guard scrolling else { return [] }
                scrollAnchor = point
                let horizontal = -(point.x - anchor.x) * 7, vertical = (point.y - anchor.y) * 7
                guard horizontal.isFinite, vertical.isFinite else { return reset() }
                let x = Self.quantize(horizontal, remainder: &remainderX), y = Self.quantize(vertical, remainder: &remainderY)
                return x == 0 && y == 0 ? [] : [.scroll(vertical: y, horizontal: x)]
            }
            return []
        case .cancelled:
            return []
        }
    }

    /// Capture loss, local gestures, and mode changes must release a held drag
    /// and discard both live contacts and the first-tap latch.
    public mutating func reset() -> [TrackpadAction] {
        let actions = releaseDrag()
        contacts = [:]; gestureStartedAt = nil; lastEventAt = nil; lastTapAt = nil
        peakContacts = 0; tapEligible = false; suppressed = false; resetMotion()
        return actions
    }

    private mutating func releaseDrag() -> [TrackpadAction] {
        guard leftHeld else { return [] }
        leftHeld = false
        return [.button(button: 1, pressed: false)]
    }
    private mutating func resetMotion() {
        scrolling = false; scrollAnchor = nil; remainderX = 0; remainderY = 0
    }
    private func centroid() -> CGPoint? {
        guard contacts.count == 2 else { return nil }
        let points = contacts.values.map(\.position)
        return CGPoint(x: points[0].x / 2 + points[1].x / 2, y: points[0].y / 2 + points[1].y / 2)
    }
    private static func quantize(_ delta: CGFloat, remainder: inout CGFloat) -> Int16 {
        let total = delta + remainder
        let integral = total.rounded(.towardZero)
        // Preserve only the fractional part. A very large event is bounded once
        // instead of queuing excess movement into future stationary samples.
        remainder = total - integral
        return Int16(min(CGFloat(Int16.max), max(CGFloat(Int16.min), integral)))
    }
}
