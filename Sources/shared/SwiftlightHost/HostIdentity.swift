import Foundation
import Security
import CryptoKit
import CHostCrypto

enum PairingCrypto {
    static func random(_ count: Int) throws -> Data {
        var result = Data(count: count)
        let status = result.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw HostError.cryptoFailure }; return result
    }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func output(_ call: (UnsafeMutablePointer<SLHostBytes>) -> Int32) throws -> Data {
        var output = SLHostBytes(); defer { sl_host_bytes_free(&output) }
        guard call(&output) == 1, let bytes = output.bytes, output.length > 0 else { throw HostError.cryptoFailure }
        return Data(bytes: bytes, count: output.length)
    }
    static func der(_ certificate: Data) throws -> Data {
        try certificate.withUnsafeBytes { cert in try output { sl_host_certificate_der(cert.bindMemory(to: UInt8.self).baseAddress, cert.count, $0) } }
    }
    static func signature(_ certificate: Data) throws -> Data {
        try certificate.withUnsafeBytes { cert in try output { sl_host_certificate_signature(cert.bindMemory(to: UInt8.self).baseAddress, cert.count, $0) } }
    }
    static func sign(_ data: Data, key: Data) throws -> Data {
        try key.withUnsafeBytes { key in try data.withUnsafeBytes { data in
            try output { sl_host_sign(key.bindMemory(to: UInt8.self).baseAddress, key.count, data.bindMemory(to: UInt8.self).baseAddress, data.count, $0) }
        } }
    }
    static func verify(_ data: Data, signature: Data, certificate: Data) -> Bool {
        certificate.withUnsafeBytes { cert in data.withUnsafeBytes { data in signature.withUnsafeBytes { sign in
            sl_host_verify(cert.bindMemory(to: UInt8.self).baseAddress, cert.count, data.bindMemory(to: UInt8.self).baseAddress, data.count, sign.bindMemory(to: UInt8.self).baseAddress, sign.count) == 1
        } } }
    }
    static func aes(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16, !data.isEmpty, data.count % 16 == 0 else { throw HostError.invalidResponse }
        return try key.withUnsafeBytes { key in try data.withUnsafeBytes { data in
            try output { sl_host_aes_ecb(key.bindMemory(to: UInt8.self).baseAddress, data.bindMemory(to: UInt8.self).baseAddress, data.count, encrypt ? 1 : 0, $0) }
        } }
    }
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}

struct HostIdentityEnvelope: Codable, Sendable {
    let uniqueID: String
    let certificate: Data
    let privateKey: Data
    let pkcs12: Data
    let password: String
    static func generate() throws -> Self {
        let password = try PairingCrypto.random(32).hex
        var raw = SLHostIdentity(); defer { sl_host_identity_free(&raw) }
        guard password.withCString({ sl_host_identity_create($0, &raw) }) == 1 else { throw HostError.cryptoFailure }
        return Self(uniqueID: try PairingCrypto.random(8).hex,
                    certificate: Data(bytes: raw.certificate_pem.bytes!, count: raw.certificate_pem.length),
                    privateKey: Data(bytes: raw.private_key_pem.bytes!, count: raw.private_key_pem.length),
                    pkcs12: Data(bytes: raw.pkcs12.bytes!, count: raw.pkcs12.length), password: password)
    }
    func tlsIdentity() throws -> SecIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15, iOS 18, tvOS 18, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let identity = first[kSecImportItemIdentity as String] else { throw HostError.keychain(status) }
        return identity as! SecIdentity
    }
}

/// Secrets and host trust records are local, non-synchronizing Keychain items.
protocol HostIdentityProviding: Sendable {
    func identity() async throws -> HostIdentityEnvelope
    func pin(_ key: String) async throws -> Data?
    func savePin(_ certificate: Data, keys: [String]) async throws
    func removePins(_ keys: [String]) async throws
}

public enum HostKeychainBackend: Sendable {
    case dataProtection
    #if os(macOS)
    /// Supports a Mac app without restricted provisioning entitlements.
    case login
    #endif
    public static var applicationDefault: Self {
        #if os(macOS)
        .login
        #else
        .dataProtection
        #endif
    }
}

/// Query construction is independent of Keychain I/O for tests that never access credentials.
struct HostKeychainConfiguration: Sendable {
    let service: String
    let backend: HostKeychainBackend
    func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: backend == .dataProtection]
    }
    func item(account: String, data: Data) -> [String: Any] {
        var item = query(account: account); item[kSecValueData as String] = data
        if backend == .dataProtection { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        // Login Keychain uses its lock state and app access controls, not this
        // data-protection accessibility attribute.
        return item
    }
}

public actor HostIdentityStore: HostIdentityProviding {
    public static let shared = HostIdentityStore()
    private let keychain: any HostKeychainIO
    private var cachedIdentity: HostIdentityEnvelope?
    private enum PinSnapshot {
        case missing, certificate(Data)
        var data: Data? { if case .certificate(let data) = self { data } else { nil } }
    }
    private var cachedPins: [String: PinSnapshot] = [:]
    public init(service: String = "net.swiftlight.client.identity", backend: HostKeychainBackend = .applicationDefault) {
        keychain = SecurityHostKeychainIO(configuration: HostKeychainConfiguration(service: service, backend: backend))
    }
    /// Tests inject a memory store so cache behavior never accesses user credentials.
    init(keychain: any HostKeychainIO) {
        self.keychain = keychain
    }
    func identity() throws -> HostIdentityEnvelope {
        if let cachedIdentity { return cachedIdentity }
        let identity: HostIdentityEnvelope
        if let saved = try keychain.read(account: "identity-v1") {
            do { identity = try JSONDecoder().decode(HostIdentityEnvelope.self, from: saved) }
            catch { throw HostError.cryptoFailure }
        } else {
            identity = try HostIdentityEnvelope.generate()
            try keychain.write(JSONEncoder().encode(identity), account: "identity-v1")
        }
        cachedIdentity = identity; return identity
    }
    func pin(_ key: String) throws -> Data? {
        if let cached = cachedPins[key] { return cached.data }
        let certificate = try keychain.read(account: "host-pin:" + key)
        cachePin(certificate, key: key)
        return certificate
    }
    func savePin(_ certificate: Data, keys: [String]) throws {
        for key in Set(keys).sorted() {
            try keychain.write(certificate, account: "host-pin:" + key)
            cachePin(certificate, key: key)
        }
    }
    func removePins(_ keys: [String]) throws {
        for key in Set(keys).sorted() {
            try keychain.remove(account: "host-pin:" + key)
            cachePin(nil, key: key)
        }
    }
    private func cachePin(_ certificate: Data?, key: String) {
        // Bound aliases and negative lookups. Eviction merely rechecks Keychain.
        if cachedPins.count >= 256 && cachedPins[key] == nil { cachedPins.removeAll(keepingCapacity: true) }
        cachedPins[key] = certificate.map(PinSnapshot.certificate) ?? .missing
    }
}

protocol HostKeychainIO: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(account: String) throws
}

private struct SecurityHostKeychainIO: HostKeychainIO {
    let configuration: HostKeychainConfiguration
    func read(account: String) throws -> Data? {
        var query = configuration.query(account: account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HostError.keychain(status) }; return data
    }
    func write(_ data: Data, account: String) throws {
        let match = configuration.query(account: account)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw HostError.keychain(update) }
        let item = configuration.item(account: account, data: data)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HostError.keychain(status) }
    }
    func remove(account: String) throws {
        let status = SecItemDelete(configuration.query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HostError.keychain(status) }
    }
}
