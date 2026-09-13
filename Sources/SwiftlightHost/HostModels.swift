import Foundation
import CryptoKit
import Darwin

public enum HostError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress, malformedPairingLink, invalidPIN, notPaired, pairingInProgress
    case incorrectPIN, credentialRejected, credentialUnavailable, certificateChanged, identityChanged
    case invalidResponse, invalidArtwork, unsupportedHost, cryptoFailure, keychain(Int32), permissionDenied, hostStatus(Int)
    case timeout, connectionFailed, networkFailure(Int), pairingFailed, launchFailed
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a hostname, IP address, or [IPv6]:port with an HTTP port from 1 to 65535."
        case .malformedPairingLink: "This Apollo pairing link is malformed. Paste the complete art:// link, or enter its OTP and passphrase."
        case .invalidPIN: "A PIN must contain exactly four digits."
        case .notPaired: "Pair this host before opening its library."
        case .pairingInProgress: "A pairing attempt is already in progress. Cancel it before starting another."
        case .incorrectPIN: "The PIN did not match. Start pairing again and enter the new PIN on the host."
        case .credentialRejected: "Apollo rejected this pairing credential. It may be incorrect, expired, or already used. Generate a new link on the host."
        case .credentialUnavailable: "Apollo reports that OTP pairing is unavailable. Generate a new link on the host."
        case .certificateChanged: "This host's certificate changed. Verify the host, then remove its saved pairing and pair again."
        case .identityChanged: "This address now reports a different host identity. Verify the address before pairing."
        case .invalidResponse: "The host returned an invalid or incomplete response."
        case .invalidArtwork: "The host's cover image is missing, damaged, or too large."
        case .unsupportedHost: "This client requires Sunshine or Apollo with generation 7 or newer pairing."
        case .cryptoFailure: "The cryptographic pairing operation failed."
        case .keychain(let status): "The client identity could not be accessed in Keychain (\(status))."
        case .permissionDenied: "This client does not have permission for that operation. Update its permissions on the host."
        case .hostStatus(let code): "The host rejected the request (\(code))."
        case .timeout: "The host did not respond in time. Check the address and network, then try again."
        case .connectionFailed: "Unable to connect to the host. Check its address, network access, and streaming service."
        case .networkFailure(let code): "Unable to connect to the host (network error \(code)). Check its address, network access, and streaming service."
        case .pairingFailed: "The host did not complete pairing. Cancel other pairing attempts and try again."
        case .launchFailed: "The host did not create a streaming session. Check the host application and display configuration."
        }
    }
}

public struct HostAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public let host: String
    public let httpPort: Int
    public init(host: String, httpPort: Int = 47989) throws {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") { normalized = String(normalized.dropFirst().dropLast()) }
        guard !normalized.isEmpty, (1...65535).contains(httpPort),
              !normalized.contains(where: { $0.isWhitespace }),
              !normalized.contains("/"), !normalized.contains("?"), !normalized.contains("#"), !normalized.contains("@"),
              !normalized.contains("["), !normalized.contains("]") else { throw HostError.invalidAddress }
        if normalized.contains(":") {
            let parts = normalized.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2, parts.count == 1 || (!parts[1].isEmpty && parts[1].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            })) else { throw HostError.invalidAddress }
            var ipv6 = in6_addr()
            guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { throw HostError.invalidAddress }
        }
        self.host = normalized.lowercased(); self.httpPort = httpPort
        _ = try url(path: "serverinfo", secure: false)
    }
    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare IPv6 is accepted with the default port; brackets disambiguate a custom port.
        if !input.contains("://"), !input.hasPrefix("["), input.filter({ $0 == ":" }).count > 1 {
            try self.init(host: input); return
        }
        guard let parts = URLComponents(string: input.contains("://") ? input : "http://" + input),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw HostError.invalidAddress }
        try self.init(host: host, httpPort: parts.port ?? 47989)
    }
    public var description: String { "\(host.contains(":") ? "[\(host)]" : host):\(httpPort)" }
    func url(path: String, secure: Bool, httpsPort: Int? = nil, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(); parts.scheme = secure ? "https" : "http"
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = secure ? (httpsPort ?? httpPort - 5) : httpPort
        guard let port = parts.port, (1...65535).contains(port) else { throw HostError.invalidAddress }
        parts.path = "/" + path; parts.queryItems = query.isEmpty ? nil : query
        guard let result = parts.url else { throw HostError.invalidAddress }; return result
    }
}

/// A short-lived Apollo OTP, never encoded for persistence or included in descriptions.
public struct ApolloPairingCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: HostAddress
    public let hostName: String?
    let otp: String
    let passphrase: String
    public init(address: HostAddress, otp: String, passphrase: String, hostName: String? = nil) throws {
        guard otp.count == 4, otp.utf8.allSatisfy({ (48...57).contains($0) }), !passphrase.isEmpty,
              passphrase.utf8.count <= 4096 else { throw HostError.malformedPairingLink }
        self.address = address; self.otp = otp; self.passphrase = passphrase; self.hostName = hostName
    }
    public init(link: String) throws {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // URLComponents tolerates malformed '%' by escaping it; a credential link
        // must instead reject malformed URI encoding before decoding its secrets.
        let rawBytes = Array(raw.utf8)
        for index in rawBytes.indices where rawBytes[index] == 37 {
            guard index + 2 < rawBytes.count, rawBytes[(index + 1)...(index + 2)].allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw HostError.malformedPairingLink }
        }
        guard let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "art", let host = parts.host,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let query = parts.queryItems else { throw HostError.malformedPairingLink }
        var fields: [String: String] = [:]
        for item in query {
            guard ["pin", "passphrase", "name"].contains(item.name), fields[item.name] == nil,
                  let value = item.value else { throw HostError.malformedPairingLink }
            fields[item.name] = value
        }
        guard let otp = fields["pin"], let passphrase = fields["passphrase"] else { throw HostError.malformedPairingLink }
        do { try self.init(address: HostAddress(host: host, httpPort: parts.port ?? 47989), otp: otp, passphrase: passphrase, hostName: fields["name"]) }
        catch { throw HostError.malformedPairingLink }
    }
    public var description: String { "Apollo pairing credential (redacted)" }
    public var debugDescription: String { description }
    /// Artemis uses uppercase *textual* salt, not the raw salt bytes, in the OTP hash.
    func authentication(salt: Data) -> String { Data(SHA256.hash(data: Data((otp + salt.hex + passphrase).utf8))).hex }
}

public struct HostInfo: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let appVersion: String
    public let gfeVersion: String
    public let httpsPort: Int
    public let isPaired: Bool
    public let currentAppID: Int
    public let codecSupport: UInt32
    public let permissions: UInt32?
    public let rawFields: [String: String]
    public var isStreaming: Bool { currentAppID > 0 }
    public var isApollo: Bool { permissions != nil || rawFields["VirtualDisplayCapable"] != nil }
    public var supportsHEVC: Bool { codecSupport & 0x100 != 0 }
    public var supportsAV1: Bool { codecSupport & 0x10000 != 0 }
}

public struct RemoteApp: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let supportsHDR: Bool
    public let uuid: String?
    public init(id: Int, name: String, supportsHDR: Bool = false, uuid: String? = nil) {
        self.id = id; self.name = name; self.supportsHDR = supportsHDR; self.uuid = uuid
    }
}

/// Ephemeral launch material must also be passed unchanged to moonlight-common-c.
public struct StreamLaunchRequest: Sendable, CustomDebugStringConvertible {
    public let appID: Int
    public let width: Int
    public let height: Int
    public let fps: Int
    public let inputKey: Data
    public let inputKeyID: UInt32
    public var hdr = false
    public var playAudioOnHost = false
    public var controllerMask: UInt32 = 0
    public var surroundAudioInfo: UInt32 = 0x00030002
    public var additionalQuery: [URLQueryItem] = []
    public init(appID: Int, width: Int, height: Int, fps: Int, inputKey: Data, inputKeyID: UInt32) throws {
        guard appID > 0, (1...16384).contains(width), (1...16384).contains(height), (1...1000).contains(fps), inputKey.count == 16 else { throw HostError.invalidResponse }
        self.appID = appID; self.width = width; self.height = height; self.fps = fps; self.inputKey = inputKey; self.inputKeyID = inputKeyID
    }
    public var debugDescription: String { "StreamLaunchRequest(app: \(appID), mode: \(width)x\(height)x\(fps), secrets: redacted)" }
}

public struct StreamLaunchResponse: Sendable {
    public let sessionURL: String
    public let hostInfo: HostInfo
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
    init(strictHex: String) throws {
        guard strictHex.count % 2 == 0, strictHex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw HostError.invalidResponse }
        var data = Data(); data.reserveCapacity(strictHex.count / 2); var index = strictHex.startIndex
        while index < strictHex.endIndex {
            let next = strictHex.index(index, offsetBy: 2)
            guard let value = UInt8(strictHex[index..<next], radix: 16) else { throw HostError.invalidResponse }
            data.append(value); index = next
        }
        self = data
    }
}
