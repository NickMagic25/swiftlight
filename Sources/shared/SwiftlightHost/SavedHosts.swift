import Foundation

public struct SavedHost: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var address: HostAddress
    public init(id: String, name: String, address: HostAddress) { self.id = id; self.name = name; self.address = address }
    public init(info: HostInfo, address: HostAddress) { self.init(id: info.id, name: info.name, address: address) }
}

/// Only nonsecret metadata is stored here. Trust pins and client identity use Keychain.
public actor SavedHostStore {
    private let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftlight", isDirectory: true).appendingPathComponent("hosts.json")
    }
    public func load() throws -> [SavedHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedHost].self, from: Data(contentsOf: url))
    }
    public func upsert(_ host: SavedHost) throws {
        var hosts = try load()
        hosts.removeAll { $0.id == host.id || $0.address == host.address }
        hosts.append(host); try save(hosts)
    }
    public func remove(id: String) throws { try save(load().filter { $0.id != id }) }
    private func save(_ hosts: [SavedHost]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }).write(to: url, options: .atomic)
    }
}
