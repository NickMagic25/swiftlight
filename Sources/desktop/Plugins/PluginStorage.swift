#if os(macOS)
import Foundation
import Darwin
import Security
import SwiftlightPlugins

enum PluginStorageError: Error { case invalidSource, downloadFailed, tooLarge, storageFailed, secretUnavailable }

protocol PluginSecretStore: Sendable {
    func read(pluginID: UUID, fieldID: String) throws -> String?
    func write(_ value: String, pluginID: UUID, fieldID: String) throws
    func remove(pluginID: UUID, fieldID: String) throws
}

/// Matches the host identity store's local, nonsynchronizing login-Keychain policy.
struct KeychainPluginSecretStore: PluginSecretStore {
    private func query(pluginID: UUID, fieldID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "net.swiftlight.client.plugin-fields",
         kSecAttrAccount as String: pluginID.uuidString + ":" + fieldID,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: false]
    }
    func read(pluginID: UUID, fieldID: String) throws -> String? {
        var query = query(pluginID: pluginID, fieldID: fieldID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw PluginStorageError.secretUnavailable
        }
        return value
    }
    func write(_ value: String, pluginID: UUID, fieldID: String) throws {
        if value.isEmpty { try remove(pluginID: pluginID, fieldID: fieldID); return }
        let query = query(pluginID: pluginID, fieldID: fieldID)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PluginStorageError.secretUnavailable }
        var item = query; item[kSecValueData as String] = data
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PluginStorageError.secretUnavailable }
    }
    func remove(pluginID: UUID, fieldID: String) throws {
        let status = SecItemDelete(query(pluginID: pluginID, fieldID: fieldID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PluginStorageError.secretUnavailable }
    }
}

struct StoredPlugin: Codable {
    let id: UUID
    let source: String
    let sourceBookmark: Data?
    let manifestYAML: String
    let enabled: Bool
    let values: [String: String]
    let pythonExecutable: String
    let swiftExecutable: String
}

struct PluginStorageDocument: Codable {
    let version: Int
    let plugins: [StoredPlugin]
}

enum PluginManifestImporter {
    static let maximumBytes = 256 * 1024

    static func normalizedSource(_ source: URL) throws -> URL {
        if source.isFileURL {
            guard source.host == nil || source.host == "" || source.host == "localhost" else { throw PluginStorageError.invalidSource }
            return source.standardizedFileURL
        }
        guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil else { throw PluginStorageError.invalidSource }
        if components.host?.lowercased() == "github.com" {
            let parts = components.percentEncodedPath.split(separator: "/").map(String.init)
            guard parts.count >= 5, parts[2] == "blob" else { throw PluginStorageError.invalidSource }
            components.host = "raw.githubusercontent.com"
            components.percentEncodedPath = "/" + ([parts[0], parts[1]] + parts.dropFirst(3)).joined(separator: "/")
            components.query = nil
        }
        components.fragment = nil
        guard let url = components.url else { throw PluginStorageError.invalidSource }
        return url
    }

    static func read(_ source: URL) async throws -> Data {
        let url = try normalizedSource(source)
        if url.isFileURL {
            return try await Task.detached(priority: .utility) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                return try readRegularFile(url, maximumBytes: maximumBytes)
            }.value
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: HTTPSPluginRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let finalURL = response.url, !finalURL.isFileURL,
              (try? normalizedSource(finalURL)) != nil else { throw PluginStorageError.downloadFailed }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw PluginStorageError.tooLarge }
        var data = Data(); data.reserveCapacity(min(maximumBytes, Int(max(0, response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw PluginStorageError.tooLarge }
            data.append(byte)
        }
        return data
    }

    static func bookmark(for source: URL) async -> Data? {
        guard source.isFileURL else { return nil }
        return await Task.detached(priority: .utility) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            return try? source.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }.value
    }

    static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginStorageError.invalidSource }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw PluginStorageError.invalidSource
        }
        guard metadata.st_size <= maximumBytes else { throw PluginStorageError.tooLarge }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw PluginStorageError.tooLarge }
        return data
    }
}

private final class HTTPSPluginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, !url.isFileURL, (try? PluginManifestImporter.normalizedSource(url)) != nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
#endif
