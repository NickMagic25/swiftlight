/// Guards user-requested reconnect/resume work across asynchronous teardown.
/// Session callback generations and pending user intent are distinct lifetimes.
public struct SessionIntentGate: Sendable {
    public struct Ticket: Sendable { fileprivate let generation: UInt64; fileprivate let hostID: String }
    private var generation: UInt64 = 0
    public init() {}
    public mutating func retire() { generation &+= 1 }
    public mutating func issue(hostID: String) -> Ticket { retire(); return Ticket(generation: generation, hostID: hostID) }
    public func accepts(_ ticket: Ticket, selectedHostID: String?) -> Bool {
        ticket.generation == generation && ticket.hostID == selectedHostID
    }
}
