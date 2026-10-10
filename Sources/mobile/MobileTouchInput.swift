#if os(iOS)
import SwiftlightCore
import SwiftlightTransport
import UIKit

enum MobileTouchInputIssue: Equatable, Sendable {
    case unsupported, denied, failed
    var message: String {
        switch self {
        case .unsupported:
            "This computer does not support native touch. Trackpad gestures will be used for this stream."
        case .denied:
            "Native touch is not allowed for this client on your computer. Enable its touch input permission, or select Trackpad in Settings for your next stream."
        case .failed:
            "Touch input could not be sent. Lift your fingers and try again."
        }
    }
}

/// UIKit identity and protocol routing stay on the main actor. Gesture state is
/// value-owned; no UITouch or delayed touch callback survives an input reset.
@MainActor final class MobileTouchInput {
    private let mode: MobileTouchMode
    private let transport: StreamTransport
    private let reportIssue: (MobileTouchInputIssue) -> Void
    private var trackpad = TrackpadInputState()
    private var native = NativeTouchInputState()
    private var contacts: [ObjectIdentifier: Int] = [:]
    private var physicalContacts: Set<ObjectIdentifier> = []
    private var nextID = 0
    private var trackpadFallback = false
    private var reportedUnavailable = false
    private var localGesture = false

    init(mode: MobileTouchMode, transport: StreamTransport,
         reportIssue: @escaping (MobileTouchInputIssue) -> Void) {
        self.mode = mode; self.transport = transport; self.reportIssue = reportIssue
    }

    func consume(_ touches: Set<UITouch>, phase: TrackpadTouchPhase, in view: UIView,
                 geometry: NativeTouchGeometry?) {
        if phase == .cancelled {
            guard touches.contains(where: { physicalContacts.contains(ObjectIdentifier($0)) }) else { return }
            cancel(); return
        }
        if phase == .began {
            if mode == .nativeTouch, !trackpadFallback {
                switch transport.nativeTouchAvailability {
                case .supported: break
                case .unsupported:
                    trackpadFallback = true
                    cancel()
                    notifyUnavailable(.unsupported)
                    return
                case .denied:
                    cancel()
                    notifyUnavailable(.denied)
                    return
                case .notStreaming: return
                }
            }
            for touch in touches where touch.type == .direct || touch.type == .pencil {
                let key = ObjectIdentifier(touch)
                if physicalContacts.count < 16 { physicalContacts.insert(key) }
                // The left edge belongs to the local disconnect gesture. Never
                // start a remote contact that would later become an edge swipe.
                guard touch.location(in: view).x - view.bounds.minX > 24,
                      contacts.count < 10 else { continue }
                guard contacts[key] == nil else { continue }
                contacts[key] = nextID
                nextID = nextID == Int.max ? 0 : nextID + 1
            }
            if physicalContacts.count >= 3 {
                // Three-finger tap/hold are local shortcuts in both modes.
                // Retain identities until lift so a remaining finger cannot
                // restart a remote gesture after the shortcut cancels it.
                send(trackpad.reset()); send(native.reset())
                localGesture = true
            }
        }
        let batch = touches.compactMap { touch -> TrackpadContact? in
            guard let id = contacts[ObjectIdentifier(touch)] else { return nil }
            return TrackpadContact(id: id, position: touch.location(in: view))
        }
        if !localGesture, !batch.isEmpty {
            if mode == .trackpad || trackpadFallback {
                send(trackpad.consume(batch, phase: phase, at: touches.map(\.timestamp).max() ?? 0))
            } else if let geometry {
                send(native.consume(batch, phase: phase, geometry: geometry))
            } else {
                send(native.reset())
            }
        }
        if phase == .ended {
            for touch in touches {
                contacts.removeValue(forKey: ObjectIdentifier(touch))
                physicalContacts.remove(ObjectIdentifier(touch))
            }
            if physicalContacts.isEmpty { localGesture = false }
        }
    }

    func cancel() {
        send(trackpad.reset()); send(native.reset())
        contacts.removeAll(keepingCapacity: true)
        physicalContacts.removeAll(keepingCapacity: true)
        localGesture = false
    }

    private func notifyUnavailable(_ issue: MobileTouchInputIssue) {
        guard !reportedUnavailable else { return }
        reportedUnavailable = true
        reportIssue(issue)
    }

    private func send(_ actions: [TrackpadAction]) {
        for action in actions {
            switch action {
            case let .move(dx, dy): transport.mouseMove(dx: dx, dy: dy)
            case let .button(button, pressed): transport.mouseButton(button, pressed: pressed)
            case let .scroll(vertical, horizontal): transport.scroll(vertical: vertical, horizontal: horizontal)
            }
        }
    }
    private func send(_ actions: [NativeTouchAction]) {
        var failed = false
        for action in actions {
            let event: TouchEventPhase
            switch action.event {
            case .down: event = .down
            case .move: event = .move
            case .up: event = .up
            case .cancel: event = .cancel
            }
            if transport.touch(event: event, id: action.id, x: action.x, y: action.y) != 0 {
                failed = true
                break
            }
        }
        if failed {
            // The C bridge retains failed terminal events until this cleanup.
            // Drop the entire local interaction; late moves/ups cannot revive it.
            _ = native.reset()
            contacts.removeAll(keepingCapacity: true); physicalContacts.removeAll(keepingCapacity: true)
            localGesture = false
            transport.releaseAllInputs()
            reportIssue(.failed)
        }
    }
}
#endif
