import CoreGraphics
import Foundation

/// Maps UIKit points through the rendered crop and drawable viewport into the
/// full-frame normalized coordinate space expected by the host touch protocol.
public struct NativeTouchGeometry: Sendable {
    public let frameSize: CGSize
    public let contentRect: CGRect
    public let viewBounds: CGRect
    public let drawableSize: CGSize
    public let scaling: VideoScaling

    public init(frameSize: CGSize, contentRect: CGRect, viewBounds: CGRect,
                drawableSize: CGSize, scaling: VideoScaling) {
        self.frameSize = frameSize; self.contentRect = contentRect
        self.viewBounds = viewBounds; self.drawableSize = drawableSize; self.scaling = scaling
    }

    /// A new contact must begin inside visible video. Already-held contacts can
    /// be clamped to its edge so leaving the viewport never strands a host touch.
    public func normalizedPoint(at point: CGPoint, clamping: Bool = false) -> CGPoint? {
        func valid(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        }
        func valid(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite && valid(rect.size)
                && rect.maxX.isFinite && rect.maxY.isFinite
        }
        guard point.x.isFinite, point.y.isFinite, valid(frameSize), valid(contentRect),
              valid(viewBounds), valid(drawableSize), contentRect.minX >= 0, contentRect.minY >= 0,
              contentRect.maxX <= frameSize.width, contentRect.maxY <= frameSize.height else { return nil }
        let destination = CGRect(origin: .zero, size: drawableSize)
        let transform = ViewportTransform(source: contentRect.size, destination: destination, scaling: scaling)
        let viewport = transform.viewport
        let visible = viewport.intersection(destination)
        guard valid(viewport), valid(visible) else { return nil }
        var drawablePoint = CGPoint(
            x: (point.x - viewBounds.minX) / viewBounds.width * drawableSize.width,
            y: (point.y - viewBounds.minY) / viewBounds.height * drawableSize.height)
        guard drawablePoint.x.isFinite, drawablePoint.y.isFinite else { return nil }
        if clamping {
            drawablePoint.x = min(max(drawablePoint.x, visible.minX), visible.maxX)
            drawablePoint.y = min(max(drawablePoint.y, visible.minY), visible.maxY)
        } else {
            guard viewBounds.contains(point), visible.contains(drawablePoint) else { return nil }
        }
        let x = (contentRect.minX + (drawablePoint.x - viewport.minX) / viewport.width * contentRect.width)
            / frameSize.width
        let y = (contentRect.minY + (drawablePoint.y - viewport.minY) / viewport.height * contentRect.height)
            / frameSize.height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

public enum NativeTouchEvent: UInt8, Sendable, Equatable {
    case down = 1, up = 2, move = 3, cancel = 4
}

public struct NativeTouchAction: Sendable, Equatable {
    public let event: NativeTouchEvent
    public let id: UInt32
    public let x: Float
    public let y: Float

    public init(event: NativeTouchEvent, id: UInt32, x: Float, y: Float) {
        self.event = event; self.id = id; self.x = x; self.y = y
    }
}

/// Bounded value-state ownership of contacts already admitted to a native touch
/// stream. The UIKit owner supplies stable local IDs and serializes all calls.
public struct NativeTouchInputState: Sendable {
    private struct Contact: Sendable {
        let id: UInt32
        var point: CGPoint
    }
    private var contacts: [Int: Contact] = [:]
    private var nextPointerID: UInt32
    public var activeContactCount: Int { contacts.count }

    public init(nextPointerID: UInt32 = 0) { self.nextPointerID = nextPointerID }

    /// Each list contains the contacts whose phase changed in this callback.
    /// Unknown or rejected contacts cannot acquire a host ID through a move/up.
    public mutating func consume(_ changedContacts: [TrackpadContact], phase: TrackpadTouchPhase,
                                 geometry: NativeTouchGeometry) -> [NativeTouchAction] {
        var actions: [NativeTouchAction] = []
        var processed: Set<Int> = []
        for changed in changedContacts where processed.insert(changed.id).inserted {
            switch phase {
            case .began:
                guard contacts[changed.id] == nil, contacts.count < 10,
                      let point = geometry.normalizedPoint(at: changed.position) else { continue }
                let contact = Contact(id: allocatePointerID(), point: point)
                contacts[changed.id] = contact
                actions.append(action(.down, contact))
            case .moved:
                guard var contact = contacts[changed.id],
                      let point = geometry.normalizedPoint(at: changed.position, clamping: true) else { continue }
                contact.point = point; contacts[changed.id] = contact
                actions.append(action(.move, contact))
            case .ended:
                guard var contact = contacts.removeValue(forKey: changed.id) else { continue }
                if let point = geometry.normalizedPoint(at: changed.position, clamping: true) { contact.point = point }
                actions.append(action(.up, contact))
            case .cancelled:
                guard let contact = contacts.removeValue(forKey: changed.id) else { continue }
                actions.append(action(.cancel, contact))
            }
        }
        return actions
    }

    /// Retire IDs before emitting terminal events. Delayed moves from those
    /// contacts remain ignored and cannot revive an earlier stream generation.
    public mutating func reset() -> [NativeTouchAction] {
        let retired = contacts.values.sorted { $0.id < $1.id }
        contacts.removeAll(keepingCapacity: true)
        return retired.map { action(.cancel, $0) }
    }

    private mutating func allocatePointerID() -> UInt32 {
        let held = Set(contacts.values.map(\.id))
        while held.contains(nextPointerID) { nextPointerID &+= 1 }
        let id = nextPointerID; nextPointerID &+= 1
        return id
    }

    private func action(_ event: NativeTouchEvent, _ contact: Contact) -> NativeTouchAction {
        NativeTouchAction(event: event, id: contact.id, x: Float(contact.point.x), y: Float(contact.point.y))
    }
}
