import Foundation
import Security
import Testing
@testable import SwiftlightHost

@Test func identityAndPinReadsAreCachedOnlyWithinTheirStore() async throws {
    let identity = try HostIdentityEnvelope.generate()
    let memory = MemoryKeychainIO(items: ["identity-v1": try JSONEncoder().encode(identity), "host-pin:paired": Data([1, 2, 3])])
    let store = HostIdentityStore(keychain: memory)
    for _ in 0..<3 {
        #expect(try await store.identity().uniqueID == identity.uniqueID)
        #expect(try await store.pin("paired") == Data([1, 2, 3]))
        #expect(try await store.pin("missing") == nil)
    }
    #expect(memory.readCount("identity-v1") == 1)
    #expect(memory.readCount("host-pin:paired") == 1)
    #expect(memory.readCount("host-pin:missing") == 1)
    // A fresh process/store must check current Keychain state, not persisted cache.
    let next = HostIdentityStore(keychain: memory)
    #expect(try await next.pin("paired") == Data([1, 2, 3]))
    #expect(memory.readCount("host-pin:paired") == 2)
}

@Test func pairingUpdatesAndForgetInvalidateCachedPins() async throws {
    let memory = MemoryKeychainIO(), store = HostIdentityStore(keychain: memory)
    #expect(try await store.pin("address") == nil)
    let first = Data([1, 2, 3]), replacement = Data([4, 5, 6])
    try await store.savePin(first, keys: ["address", "host-id"])
    #expect(try await store.pin("address") == first)
    #expect(try await store.pin("host-id") == first)
    try await store.savePin(replacement, keys: ["address", "host-id"])
    #expect(try await store.pin("address") == replacement)
    #expect(try await store.pin("host-id") == replacement)
    try await store.removePins(["address", "host-id"])
    #expect(try await store.pin("address") == nil)
    #expect(try await store.pin("host-id") == nil)
    #expect(memory.readCount("host-pin:address") == 1)
    #expect(memory.readCount("host-pin:host-id") == 0)
    try await store.savePin(first, keys: ["address"])
    #expect(try await store.pin("address") == first)
}

@Test func keychainErrorsAreNotCachedOrTreatedAsSuccessfulMutation() async throws {
    let memory = MemoryKeychainIO(items: ["host-pin:paired": Data([1])]), store = HostIdentityStore(keychain: memory)
    memory.failNext(.read)
    await #expect(throws: HostError.keychain(errSecAuthFailed)) { try await store.pin("paired") }
    #expect(try await store.pin("paired") == Data([1]))
    #expect(memory.readCount("host-pin:paired") == 2)
    memory.failNext(.write)
    await #expect(throws: HostError.keychain(errSecAuthFailed)) { try await store.savePin(Data([2]), keys: ["paired"]) }
    #expect(try await store.pin("paired") == Data([1]))
    memory.failNext(.remove)
    await #expect(throws: HostError.keychain(errSecAuthFailed)) { try await store.removePins(["paired"]) }
    #expect(try await store.pin("paired") == Data([1]))
    try await store.removePins(["paired"])
    #expect(try await store.pin("paired") == nil)
}

@Test func explicitClientUnpairAndForgetRemoveEveryCachedTrustAlias() async throws {
    let identity = try HostIdentityEnvelope.generate()
    let address = try HostAddress("fixture.invalid")
    for remoteUnpair in [false, true] {
        let memory = MemoryKeychainIO(items: ["identity-v1": try JSONEncoder().encode(identity),
            "host-pin:" + address.description: Data([1]), "host-pin:host-id": Data([1])])
        let store = HostIdentityStore(keychain: memory), transport = UnpairFixtureTransport()
        let client = HostClient(address: address, hostID: "host-id", identityStore: store, transport: transport)
        #expect(try await store.pin(address.description) == Data([1]))
        #expect(try await store.pin("host-id") == Data([1]))
        if remoteUnpair { try await client.unpair() } else { try await client.forgetPairing() }
        #expect(try await store.pin(address.description) == nil)
        #expect(try await store.pin("host-id") == nil)
        #expect(memory.readCount("host-pin:" + address.description) == 1)
        #expect(memory.readCount("host-pin:host-id") == 1)
        #expect(await transport.requests == (remoteUnpair ? ["/unpair"] : []))
        let reopened = HostIdentityStore(keychain: memory)
        #expect(try await reopened.pin(address.description) == nil)
        #expect(try await reopened.pin("host-id") == nil)
    }
}

private actor UnpairFixtureTransport: HostHTTPTransport {
    var requests: [String] = []
    func fetch(_ request: HostHTTPRequest, identity: HostIdentityEnvelope, pin: Data?) throws -> Data {
        guard request.url.scheme == "http", request.url.path == "/unpair", pin == nil else { throw HostError.invalidResponse }
        requests.append(request.url.path)
        return Data("<root status_code=\"200\"><paired>0</paired></root>".utf8)
    }
}

private final class MemoryKeychainIO: HostKeychainIO, @unchecked Sendable {
    enum Operation { case read, write, remove }
    private let lock = NSLock()
    private var items: [String: Data]
    private var reads: [String: Int] = [:]
    private var nextFailure: Operation?
    init(items: [String: Data] = [:]) { self.items = items }
    func failNext(_ operation: Operation) { lock.lock(); defer { lock.unlock() }; nextFailure = operation }
    func readCount(_ account: String) -> Int { lock.lock(); defer { lock.unlock() }; return reads[account, default: 0] }
    private func checkFailure(_ operation: Operation) throws {
        if nextFailure == operation { nextFailure = nil; throw HostError.keychain(errSecAuthFailed) }
    }
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        reads[account, default: 0] += 1
        try checkFailure(.read)
        return items[account]
    }
    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try checkFailure(.write); items[account] = data
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        try checkFailure(.remove); items.removeValue(forKey: account)
    }
}
