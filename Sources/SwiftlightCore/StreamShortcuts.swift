import Foundation

public enum StreamShortcutAction: String, Equatable, Sendable {
    case disconnect = "q", toggleStatistics = "s", releaseInput = "z"
}

/// Platform adapters supply the key and exact Control/Option/Shift chord. Keep
/// the entire local key gesture out of the remote input stream, including repeats
/// and a key-up that arrives after its modifiers have already been released.
public struct StreamShortcutState: Sendable {
    public enum Decision: Equatable, Sendable {
        case forward, consume(StreamShortcutAction?)
    }
    private var pressed: Set<String> = []
    public init() {}
    public mutating func keyDown(_ key: String, chordMatches: Bool, isRepeat: Bool) -> Decision {
        let key = key.lowercased()
        if pressed.contains(key) { return .consume(nil) }
        // A repeat whose original down was forwarded still belongs to the host.
        // Consuming it now would also swallow its up and leave a remote key held.
        guard !isRepeat, chordMatches, let action = StreamShortcutAction(rawValue: key) else { return .forward }
        pressed.insert(key)
        return .consume(action)
    }
    public mutating func keyUp(_ key: String) -> Decision {
        pressed.remove(key.lowercased()) == nil ? .forward : .consume(nil)
    }
}
