import Foundation

public enum SessionPhase: String, Codable, Sendable {
    case idle, ready, connecting, negotiating, streaming, reconfiguring, suspending, disconnecting, failed
}
public enum SessionEvent: Sendable {
    case ready, connect, negotiated, firstFrame, cancel, disconnect, stopped
    case settingsChanged, suspend, resume, pathLost, failure(String)
}
public enum SessionEffect: Equatable, Sendable {
    case start, releaseInputs, stop, resume, clearPresentation
}
/// Pure state machine. Every callback must carry the generation captured at start.
/// Cancellation retires that identity before teardown, so a late success cannot resurrect a session.
public struct SessionState: Sendable {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var generation: UInt64 = 0
    public private(set) var error: String?
    private var restartAfterStop = false
    public init() {}
    @discardableResult public mutating func apply(_ event: SessionEvent, generation callbackGeneration: UInt64? = nil) -> [SessionEffect] {
        if let callbackGeneration, callbackGeneration != generation { return [] }
        switch event {
        case .ready:
            guard phase == .idle || phase == .failed else { return [] }; phase = .ready
        case .connect:
            guard [.idle, .ready, .failed].contains(phase) else { return [] }
            generation &+= 1; phase = .connecting; error = nil; return [.start]
        case .negotiated:
            guard phase == .connecting else { return [] }; phase = .negotiating
        case .firstFrame:
            guard phase == .negotiating else { return [] }; phase = .streaming
        case .cancel, .disconnect:
            guard ![.idle, .ready, .disconnecting].contains(phase) else { return [] }
            generation &+= 1; restartAfterStop = false; phase = .disconnecting
            return [.releaseInputs, .clearPresentation, .stop]
        case .settingsChanged:
            guard phase == .streaming else { return [] }
            generation &+= 1; phase = .reconfiguring; restartAfterStop = true
            return [.releaseInputs, .clearPresentation, .stop]
        case .suspend:
            guard [.connecting, .negotiating, .streaming].contains(phase) else { return [] }
            generation &+= 1; restartAfterStop = false; phase = .suspending
            return [.releaseInputs, .clearPresentation, .stop]
        case .stopped:
            if phase == .reconfiguring && restartAfterStop {
                restartAfterStop = false; generation &+= 1; phase = .connecting; return [.start]
            }
            if phase == .disconnecting { phase = .ready }
        case .resume:
            guard phase == .suspending else { return [] }
            generation &+= 1; phase = .connecting; return [.resume]
        case .pathLost:
            guard [.connecting, .negotiating, .streaming, .reconfiguring].contains(phase) else { return [] }
            generation &+= 1; restartAfterStop = false; phase = .failed
            error = "Network path lost. Reconnect when the host is reachable."
            return [.releaseInputs, .clearPresentation, .stop]
        case .failure(let message):
            guard phase != .disconnecting && phase != .idle && phase != .ready else { return [] }
            generation &+= 1; restartAfterStop = false; phase = .failed; error = message
            return [.releaseInputs, .clearPresentation, .stop]
        }
        return []
    }
}

public struct HeldInputs: Sendable {
    public private(set) var keys: Set<UInt16> = []
    public private(set) var mouseButtons: Set<UInt8> = []
    public private(set) var controllers: Set<Int> = []
    public init() {}
    public mutating func key(_ value: UInt16, down: Bool) { if down { keys.insert(value) } else { keys.remove(value) } }
    public mutating func mouse(_ value: UInt8, down: Bool) { if down { mouseButtons.insert(value) } else { mouseButtons.remove(value) } }
    public mutating func controller(_ index: Int) { controllers.insert(index) }
    public mutating func releaseAll() -> (keys: [UInt16], mouse: [UInt8], controllers: [Int]) {
        let result = (Array(keys).sorted(), Array(mouseButtons).sorted(), Array(controllers).sorted())
        keys.removeAll(); mouseButtons.removeAll(); controllers.removeAll(); return result
    }
}
