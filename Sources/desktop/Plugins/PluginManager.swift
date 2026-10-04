#if os(macOS)
import Combine
import Foundation
import SwiftlightPlugins

struct InstalledPlugin: Identifiable, Sendable {
    let id: UUID
    let source: String
    let sourceBookmark: Data?
    let manifestYAML: String
    let manifest: PluginManifest
    var enabled: Bool
    /// Secret fields exist here only in memory; StoredPlugin omits them.
    var values: [String: String]
    var pythonExecutable: String
    var swiftExecutable: String
}

@MainActor
final class PluginManager: ObservableObject {
    static let maximumPlugins = 16
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var isImporting = false
    private let storageURL: URL
    private let secretStore: any PluginSecretStore
    private let runner: PluginJobRunner
    @Published private var secretLoads: Set<UUID> = []
    @Published private var saving: Set<UUID> = []
    private var revisions: [UUID: Int] = [:]
    private struct SessionSnapshot {
        let context: PluginStreamContext
        let plugins: [InstalledPlugin]
    }
    private var sessions: [String: SessionSnapshot] = [:]
    private var shuttingDown = false

    init(storageURL: URL? = nil, secretStore: any PluginSecretStore = KeychainPluginSecretStore(),
         runner: PluginJobRunner? = nil, loadsSavedPlugins: Bool = true) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftlight/Plugins/installed-v1.json")
        self.secretStore = secretStore; self.runner = runner ?? PluginJobRunner()
        self.runner.setCompletion { [weak self] _, result in
            Task { @MainActor [weak self] in self?.status = result.description }
        }
        if loadsSavedPlugins { loadSavedPlugins() }
    }

    func clearError() { error = nil }
    func isBusy(pluginID: UUID) -> Bool {
        secretLoads.contains(pluginID) || saving.contains(pluginID) || isImporting || shuttingDown
    }

    func importPlugin(from source: URL) async {
        guard !isImporting, !shuttingDown else { return }
        guard plugins.count < Self.maximumPlugins else { error = "At most 16 plugins can be installed."; return }
        isImporting = true; error = nil; defer { isImporting = false }
        do {
            let data = try await PluginManifestImporter.read(source)
            let manifest = try PluginManifest.parse(data: data)
            let bookmark = await PluginManifestImporter.bookmark(for: source)
            guard let yaml = String(data: data, encoding: .utf8) else { throw PluginStorageError.invalidSource }
            guard !plugins.contains(where: { $0.manifest.id == manifest.id }) else {
                error = "A plugin with this identifier is already installed. Refresh its reviewed manifest instead."; return
            }
            guard !shuttingDown else { return }
            let plugin = InstalledPlugin(id: UUID(), source: source.isFileURL ? source.standardizedFileURL.path : source.absoluteString, sourceBookmark: bookmark,
                manifestYAML: yaml, manifest: manifest, enabled: false, values: Self.defaults(manifest),
                pythonExecutable: PluginRuntimePaths.defaultPythonExecutable, swiftExecutable: PluginRuntimePaths.defaultSwiftExecutable)
            plugins.append(plugin)
            do { try persist() } catch { plugins.removeAll { $0.id == plugin.id }; throw error }
            status = "Plugin imported disabled. Review its scripts and save its configuration before enabling it."
        } catch { self.error = Self.safeDescription(error) }
    }

    func refreshPlugin(_ id: UUID) async {
        guard !isImporting, !saving.contains(id), !secretLoads.contains(id), !shuttingDown,
              let previous = plugins.first(where: { $0.id == id }), let original = Self.sourceURL(previous.source) else { return }
        isImporting = true; error = nil; defer { isImporting = false }
        // Disable before network/file access. Failed refresh cannot keep old code armed.
        do {
            guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
            plugins[index].enabled = false
            try persist()
            let source = try previous.sourceBookmark.map(PluginManifestImporter.resolveBookmark) ?? original
            let data = try await PluginManifestImporter.read(source)
            let bookmark = await PluginManifestImporter.bookmark(for: source)
            let manifest = try PluginManifest.parse(data: data)
            guard manifest.id == previous.manifest.id, let yaml = String(data: data, encoding: .utf8),
                  let index = plugins.firstIndex(where: { $0.id == id }), !shuttingDown else {
                throw PluginStorageError.invalidSource
            }
            var values = Self.defaults(manifest)
            for field in manifest.fields where previous.manifest.fields.contains(where: { $0.id == field.id && $0.type == field.type }) {
                values[field.id] = previous.values[field.id] ?? values[field.id]
            }
            revisions[id, default: 0] += 1
            plugins[index] = InstalledPlugin(id: id, source: previous.source, sourceBookmark: bookmark, manifestYAML: yaml, manifest: manifest,
                enabled: false, values: values, pythonExecutable: previous.pythonExecutable, swiftExecutable: previous.swiftExecutable)
            try persist()
            let removedSecrets = previous.manifest.fields.filter { old in
                old.type == .secret && !manifest.fields.contains(where: { $0.id == old.id && $0.type == .secret })
            }, store = secretStore
            _ = await Task.detached(priority: .utility) {
                for field in removedSecrets { try? store.remove(pluginID: id, fieldID: field.id) }
            }.value
            status = "Updated manifest is disabled. Review it before enabling the plugin."
        } catch { self.error = Self.safeDescription(error) }
    }

    func removePlugin(_ id: UUID) {
        guard !isBusy(pluginID: id) else { error = "Wait for plugin configuration and Keychain access to finish."; return }
        guard let plugin = plugins.first(where: { $0.id == id }) else { return }
        let previous = plugins; plugins.removeAll { $0.id == id }; revisions[id, default: 0] += 1
        do { try persist() } catch { plugins = previous; self.error = Self.safeDescription(error); return }
        let store = secretStore
        Task.detached(priority: .utility) {
            for field in plugin.manifest.fields where field.type == .secret { try? store.remove(pluginID: id, fieldID: field.id) }
        }
        status = "Plugin removed. An existing stream retains its reviewed end hooks until it ends."
    }

    func saveConfiguration(pluginID id: UUID, values: [String: String], pythonExecutable: String, swiftExecutable: String) async -> Bool {
        guard !saving.contains(id), !secretLoads.contains(id), !isImporting, !shuttingDown,
              let previous = plugins.first(where: { $0.id == id }) else { return false }
        error = nil
        let validated: [String: String]
        do {
            validated = try previous.manifest.validatedValues(values)
            try Self.validateExecutablePath(pythonExecutable, required: previous.manifest.hooks.contains { $0.runtime == .python })
            try Self.validateExecutablePath(swiftExecutable, required: previous.manifest.hooks.contains { $0.runtime == .swift })
        } catch { self.error = "Check required fields, field formats, and absolute interpreter paths."; return false }
        saving.insert(id); defer { saving.remove(id) }
        let revision = revisions[id, default: 0], store = secretStore
        let secretFields = previous.manifest.fields.filter { $0.type == .secret }
        let secretResult = await Task.detached(priority: .utility) { () -> Bool in
            var saved: [(String, String?)] = []
            do {
                for field in secretFields {
                    let old = try store.read(pluginID: id, fieldID: field.id)
                    try store.write(validated[field.id] ?? "", pluginID: id, fieldID: field.id)
                    saved.append((field.id, old))
                }
                return true
            } catch {
                for (fieldID, old) in saved {
                    if let old { try? store.write(old, pluginID: id, fieldID: fieldID) }
                    else { try? store.remove(pluginID: id, fieldID: fieldID) }
                }
                return false
            }
        }.value
        guard secretResult else { error = "Plugin secrets could not be saved in Keychain. Configuration was not enabled."; return false }
        guard revisions[id, default: 0] == revision, let index = plugins.firstIndex(where: { $0.id == id }), !shuttingDown else {
            _ = await Task.detached(priority: .utility) {
                for field in secretFields { try? store.write(previous.values[field.id] ?? "", pluginID: id, fieldID: field.id) }
            }.value
            return false
        }
        plugins[index].values = validated; plugins[index].pythonExecutable = pythonExecutable; plugins[index].swiftExecutable = swiftExecutable
        do { try persist() } catch {
            plugins[index] = previous; plugins[index].enabled = false
            _ = await Task.detached(priority: .utility) {
                for field in secretFields { try? store.write(previous.values[field.id] ?? "", pluginID: id, fieldID: field.id) }
            }.value
            try? persist()
            self.error = Self.safeDescription(error); return false
        }
        status = "Plugin configuration saved."
        return true
    }

    func setEnabled(pluginID id: UUID, _ enabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        if enabled {
            guard !saving.contains(id), !secretLoads.contains(id), !isImporting, !shuttingDown else {
                error = "Wait for plugin configuration and Keychain access to finish."; return
            }
            do {
                _ = try plugins[index].manifest.validatedValues(plugins[index].values)
            } catch { self.error = "Save valid required fields and select available interpreters before enabling the plugin."; return }
            if let runtimeError = Self.runtimeConfigurationError(plugins[index]) { error = runtimeError; return }
        }
        let previous = plugins[index].enabled; plugins[index].enabled = enabled
        do { try persist() } catch { plugins[index].enabled = enabled ? previous : false; self.error = Self.safeDescription(error) }
    }

    func beginStream(_ context: PluginStreamContext) {
        guard !shuttingDown, sessions[context.sessionID] == nil else { return }
        let active = plugins.filter { $0.enabled && !saving.contains($0.id) && !secretLoads.contains($0.id) }
        guard !active.isEmpty else { return }
        guard sessions.count < 2 else { status = "Plugin session capacity was reached."; return }
        let snapshot = SessionSnapshot(context: context, plugins: active)
        sessions[context.sessionID] = snapshot
        enqueue(event: .streamStarted, snapshot: snapshot)
    }

    func endStream(sessionID: String, reason: String) {
        guard let snapshot = sessions.removeValue(forKey: sessionID) else { return }
        let context = PluginStreamContext(sessionID: snapshot.context.sessionID, hostID: snapshot.context.hostID,
            hostName: snapshot.context.hostName, appID: snapshot.context.appID, appName: snapshot.context.appName, endReason: reason)
        enqueue(event: .streamEnded, snapshot: SessionSnapshot(context: context, plugins: snapshot.plugins))
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        for id in Array(sessions.keys) { endStream(sessionID: id, reason: "shutdown") }
        await runner.shutdown()
    }

    private func enqueue(event: PluginEvent, snapshot: SessionSnapshot) {
        var jobs: [PluginJob] = []
        for plugin in snapshot.plugins {
            for hook in plugin.manifest.hooks where hook.matches(event: event, context: snapshot.context) {
                jobs.append(PluginJob(pluginID: plugin.id, hook: hook, context: snapshot.context, values: plugin.values,
                    pythonExecutable: plugin.pythonExecutable, swiftExecutable: plugin.swiftExecutable))
            }
        }
        if !runner.enqueue(jobs) { status = "Plugin queue capacity was reached; these hooks were skipped." }
    }

    private func loadSavedPlugins() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try PluginManifestImporter.readRegularFile(storageURL, maximumBytes: 32 * 1024 * 1024)
            let document = try JSONDecoder().decode(PluginStorageDocument.self, from: data)
            guard document.version == 1, document.plugins.count <= Self.maximumPlugins else { throw PluginStorageError.storageFailed }
            var ids = Set<UUID>(), manifestIDs = Set<String>(), desiredEnabled: [UUID: Bool] = [:]
            for stored in document.plugins {
                let manifest = try PluginManifest.parse(data: Data(stored.manifestYAML.utf8))
                guard ids.insert(stored.id).inserted, manifestIDs.insert(manifest.id).inserted,
                      Self.sourceURL(stored.source) != nil else { throw PluginStorageError.storageFailed }
                // A disabled imported plugin may have no installed interpreter yet.
                try Self.validateExecutablePath(stored.pythonExecutable, required: false)
                try Self.validateExecutablePath(stored.swiftExecutable, required: false)
                var values = Self.defaults(manifest)
                for field in manifest.fields where field.type != .secret { values[field.id] = stored.values[field.id] ?? values[field.id] }
                plugins.append(InstalledPlugin(id: stored.id, source: stored.source, sourceBookmark: stored.sourceBookmark, manifestYAML: stored.manifestYAML,
                    manifest: manifest, enabled: stored.enabled, values: values, pythonExecutable: stored.pythonExecutable, swiftExecutable: stored.swiftExecutable))
                desiredEnabled[stored.id] = stored.enabled
            }
            hydrateSecrets(desiredEnabled: desiredEnabled)
        } catch { plugins = []; self.error = "Saved plugins could not be loaded. The saved file was preserved." }
    }

    private func hydrateSecrets(desiredEnabled: [UUID: Bool]) {
        let snapshot = plugins, store = secretStore
        secretLoads = Set(snapshot.map(\.id))
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [UUID: [String: String]]? in
                do {
                    var result: [UUID: [String: String]] = [:]
                    for plugin in snapshot {
                        var values: [String: String] = [:]
                        for field in plugin.manifest.fields where field.type == .secret {
                            values[field.id] = try store.read(pluginID: plugin.id, fieldID: field.id) ?? ""
                        }
                        result[plugin.id] = values
                    }
                    return result
                } catch { return nil }
            }.value
            guard let self else { return }
            defer { self.secretLoads.removeAll() }
            guard let loaded else {
                for index in self.plugins.indices { self.plugins[index].enabled = false }
                self.error = "Plugin secrets could not be read from Keychain. Plugins remain disabled."; return
            }
            for plugin in snapshot {
                guard let index = self.plugins.firstIndex(where: { $0.id == plugin.id }), self.revisions[plugin.id, default: 0] == 0 else { continue }
                self.plugins[index].values.merge(loaded[plugin.id] ?? [:]) { _, secret in secret }
                if desiredEnabled[plugin.id] == true,
                   (try? plugin.manifest.validatedValues(self.plugins[index].values)) == nil
                    || Self.runtimeConfigurationError(self.plugins[index]) != nil { self.plugins[index].enabled = false }
            }
        }
    }

    private func persist() throws {
        let stored = plugins.map { plugin in
            let secrets = Set(plugin.manifest.fields.filter { $0.type == .secret }.map(\.id))
            return StoredPlugin(id: plugin.id, source: plugin.source, sourceBookmark: plugin.sourceBookmark, manifestYAML: plugin.manifestYAML,
                enabled: plugin.enabled, values: plugin.values.filter { !secrets.contains($0.key) },
                pythonExecutable: plugin.pythonExecutable, swiftExecutable: plugin.swiftExecutable)
        }
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(PluginStorageDocument(version: 1, plugins: stored)).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private static func defaults(_ manifest: PluginManifest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: manifest.fields.map { ($0.id, $0.defaultValue ?? ($0.type == .boolean ? "false" : "")) })
    }
    private static func validateExecutablePath(_ path: String, required: Bool = true) throws {
        if path.isEmpty && !required { return }
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw PluginStorageError.invalidSource }
    }
    private static func runtimeConfigurationError(_ plugin: InstalledPlugin) -> String? {
        for hook in plugin.manifest.hooks where hook.runtime != .bash {
            let path = hook.runtime == .python ? plugin.pythonExecutable : plugin.swiftExecutable
            if PluginRuntimePaths.isXcrunShim(path) {
                return "Choose the direct installed Python or Swift executable. The /usr/bin xcrun shims cannot run inside the macOS App Sandbox."
            }
            guard (try? validateExecutablePath(path)) != nil, FileManager.default.isExecutableFile(atPath: path) else {
                return "Choose an available installed interpreter before enabling the plugin."
            }
            if hook.runtime == .swift && PluginRuntimePaths.swiftSDKPath(for: path) == nil {
                return "The Swift interpreter needs an accessible macOS SDK from its Xcode installation or installed Command Line Tools."
            }
        }
        return nil
    }
    private static func sourceURL(_ source: String) -> URL? {
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        guard let url = URL(string: source), (try? PluginManifestImporter.normalizedSource(url)) != nil else { return nil }
        return url
    }
    private static func safeDescription(_ error: Error) -> String {
        if let error = error as? PluginValidationError { return error.localizedDescription }
        return switch error {
        case PluginStorageError.invalidSource: "Choose a local YAML file or an HTTPS YAML/GitHub blob URL."
        case PluginStorageError.tooLarge: "Plugin manifests must be at most 256 KiB."
        case PluginStorageError.downloadFailed: "The plugin manifest could not be downloaded over HTTPS."
        case PluginStorageError.secretUnavailable: "Plugin secrets could not be accessed in Keychain."
        default: "The plugin could not be loaded or saved. Check its YAML schema and local file permissions."
        }
    }
}
#endif
