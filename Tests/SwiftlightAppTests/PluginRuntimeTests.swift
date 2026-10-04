#if os(macOS)
import Darwin
import Foundation
import SwiftlightPlugins
import Testing
@testable import SwiftlightApp

private final class PluginTestSecrets: PluginSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var blockedValue: String?
    let writeStarted = DispatchSemaphore(value: 0)
    let allowWrite = DispatchSemaphore(value: 0)
    func blockNextWrite(_ value: String) {
        lock.lock(); blockedValue = value; lock.unlock()
    }
    func waitForWriteStarted() -> Bool { writeStarted.wait(timeout: .now() + 3) == .success }
    func read(pluginID: UUID, fieldID: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; return values[pluginID.uuidString + fieldID]
    }
    func write(_ value: String, pluginID: UUID, fieldID: String) throws {
        lock.lock()
        let blocks = blockedValue == value
        if blocks { blockedValue = nil }
        lock.unlock()
        if blocks { writeStarted.signal(); _ = allowWrite.wait(timeout: .now() + 5) }
        lock.lock(); defer { lock.unlock() }; values[pluginID.uuidString + fieldID] = value
    }
    func remove(pluginID: UUID, fieldID: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: pluginID.uuidString + fieldID)
    }
}

struct PluginRuntimeTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlight-plugin-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func context(_ id: String = "session") -> PluginStreamContext {
        PluginStreamContext(sessionID: id, hostID: "host", hostName: "Host", appID: 42, appName: "Game")
    }
    private func job(script: String, values: [String: String], timeout: Int = 5, runtime: PluginRuntime = .bash) -> PluginJob {
        PluginJob(pluginID: UUID(), hook: PluginHook(event: .streamStarted, runtime: runtime, script: script, timeoutSeconds: timeout),
                  context: context(), values: values, pythonExecutable: PluginRuntimePaths.defaultPythonExecutable,
                  swiftExecutable: PluginRuntimePaths.defaultSwiftExecutable)
    }
    private func yaml() -> String {
        """
        schema_version: 1
        id: test_plugin
        name: Test plugin
        fields:
          - id: output
            label: Output
            type: string
            required: true
          - id: value
            label: Value
            type: string
          - id: token
            label: Token
            type: secret
        hooks:
          - event: stream.started
            runtime: bash
            script: |
              printf '%s|%s\\n' "$SWIFTLIGHT_EVENT" "$SWIFTLIGHT_FIELD_VALUE" >> "$SWIFTLIGHT_FIELD_OUTPUT"
          - event: stream.ended
            runtime: bash
            script: |
              printf '%s|%s\\n' "$SWIFTLIGHT_EVENT" "$SWIFTLIGHT_FIELD_VALUE" >> "$SWIFTLIGHT_FIELD_OUTPUT"
        """
    }

    @Test func bashFieldsArePassedLiterallyWithoutShellInterpolation() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output"), injected = directory.appendingPathComponent("injected")
        let literal = "$(touch " + injected.path + "); `echo injected`\nsecond line"
        let runner = PluginJobRunner()
        #expect(runner.enqueue([job(script: "printf '%s' \"$SWIFTLIGHT_FIELD_VALUE\" > \"$SWIFTLIGHT_FIELD_OUTPUT\"",
                                   values: ["value": literal, "output": output.path])]))
        #expect(await runner.waitUntilIdle())
        #expect(try String(contentsOf: output, encoding: .utf8) == literal)
        #expect(!FileManager.default.fileExists(atPath: injected.path))
    }

    @Test func installedPythonInterpreterReceivesLiteralFields() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output"), value = "literal $(echo value)"
        let runner = PluginJobRunner()
        #expect(runner.enqueue([job(script: "import os\nwith open(os.environ['SWIFTLIGHT_FIELD_OUTPUT'], 'w') as out:\n    out.write(os.environ['SWIFTLIGHT_FIELD_VALUE'])\n",
            values: ["output": output.path, "value": value], timeout: 15, runtime: .python)]))
        #expect(await runner.waitUntilIdle(timeout: 20))
        #expect(try String(contentsOf: output, encoding: .utf8) == value)
    }

    @Test func installedSwiftInterpreterUsesItsPrivateCompilerCache() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output"), value = "literal ; echo value"
        let script = """
        import Foundation
        let env = ProcessInfo.processInfo.environment
        try env["SWIFTLIGHT_FIELD_VALUE"]!.write(toFile: env["SWIFTLIGHT_FIELD_OUTPUT"]!, atomically: true, encoding: .utf8)
        """
        let runner = PluginJobRunner()
        #expect(runner.enqueue([job(script: script, values: ["output": output.path, "value": value], timeout: 30, runtime: .swift)]))
        #expect(await runner.waitUntilIdle(timeout: 35))
        #expect(try String(contentsOf: output, encoding: .utf8) == value)
    }

    @Test func swiftSDKDerivesFromSelectedToolchainAndFallsBackToLocalCommandLineTools() {
        let developer = "/Applications/ExampleXcode.app/Contents/Developer"
        let xcodeSDK = developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        let executable = developer + "/Toolchains/Example.xctoolchain/usr/bin/swift"
        #expect(PluginRuntimePaths.swiftSDKPath(for: executable, directoryExists: { $0 == xcodeSDK }) == xcodeSDK)
        let cltSDK = PluginRuntimePaths.commandLineToolsRoot + "/SDKs/MacOSX.sdk"
        #expect(PluginRuntimePaths.swiftSDKPath(for: "/custom/toolchain/usr/bin/swift", directoryExists: { $0 == cltSDK }) == cltSDK)
        #expect(PluginRuntimePaths.swiftSDKPath(for: executable, directoryExists: { _ in false }) == nil)
        #expect(PluginRuntimePaths.swiftSDKPath(for: "swift", directoryExists: { _ in true }) == nil)
    }

    @Test @MainActor func bashOnlyConfigurationCanKeepHiddenRuntimePathsEmpty() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plugin.yaml")
        try Data(yaml().utf8).write(to: source)
        let manager = PluginManager(storageURL: directory.appendingPathComponent("installed.json"), secretStore: PluginTestSecrets(), loadsSavedPlugins: false)
        await manager.importPlugin(from: source)
        let plugin = try #require(manager.plugins.first)
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: ["output": "/unused", "value": "", "token": ""], pythonExecutable: "", swiftExecutable: ""))
        manager.setEnabled(pluginID: plugin.id, true)
        #expect(manager.plugins.first?.enabled == true)
        await manager.shutdown()
    }

    @Test func timeoutTerminatesBackgroundDescendants() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker")
        let runner = PluginJobRunner()
        #expect(runner.enqueue([job(script: "(/bin/sleep 2; printf bad > \"$SWIFTLIGHT_FIELD_MARKER\") &\nwait",
                                   values: ["marker": marker.path], timeout: 1)]))
        #expect(await runner.waitUntilIdle(timeout: 4))
        try await Task.sleep(for: .milliseconds(1400))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func normalCompletionAlsoRetiresBackgroundDescendants() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("marker")
        let runner = PluginJobRunner()
        #expect(runner.enqueue([job(script: "(/bin/sleep 1; printf bad > \"$SWIFTLIGHT_FIELD_MARKER\") &",
                                   values: ["marker": marker.path])]))
        #expect(await runner.waitUntilIdle())
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func shutdownCancelsActiveGroupAndClosesAdmission() async throws {
        let runner = PluginJobRunner()
        #expect(runner.enqueue([job(script: "/bin/sleep 20", values: [:], timeout: 30)]))
        try await Task.sleep(for: .milliseconds(100))
        let started = ProcessInfo.processInfo.systemUptime
        await runner.shutdown(graceSeconds: 0)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(await runner.waitUntilIdle(timeout: 1))
        #expect(!runner.enqueue([job(script: "true", values: [:])]))
    }

    @Test func queueRejectsAnOversizedBatchWithoutPartialAdmission() async {
        let runner = PluginJobRunner(), repeated = job(script: "true", values: [:])
        #expect(!runner.enqueue(Array(repeating: repeated, count: PluginJobRunner.maximumJobs + 1)))
        #expect(await runner.waitUntilIdle())
    }

    @Test func importerNormalizesGitHubAndRejectsNonHTTPSCredentials() throws {
        let github = try #require(URL(string: "https://github.com/example/repository/blob/main/plugin.yaml?raw=true"))
        #expect(try PluginManifestImporter.normalizedSource(github).absoluteString == "https://raw.githubusercontent.com/example/repository/main/plugin.yaml")
        for source in ["http://example.com/plugin.yaml", "https://user:password@example.com/plugin.yaml", "https://github.com/example/repository"] {
            let url = try #require(URL(string: source))
            #expect(throws: (any Error).self) { try PluginManifestImporter.normalizedSource(url) }
        }
    }

    @Test func localImportBoundsBeforeParsing() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.yaml")
        try Data(repeating: 65, count: PluginManifestImporter.maximumBytes + 1).write(to: source)
        await #expect(throws: (any Error).self) { try await PluginManifestImporter.read(source) }
    }

    @Test func localImportRejectsNamedPipesWithoutWaitingForAWriter() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("not-a-yaml-file")
        #expect(mkfifo(source.path, 0o600) == 0)
        let start = ProcessInfo.processInfo.systemUptime
        await #expect(throws: (any Error).self) { try await PluginManifestImporter.read(source) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func externalContextIsUTF8BoundedAndHasNoNUL() {
        let job = PluginJob(pluginID: UUID(), hook: PluginHook(event: .streamStarted, runtime: .bash, script: "true"),
            context: PluginStreamContext(sessionID: "id\0", hostID: "host", hostName: "a" + String(repeating: "\u{301}", count: 10000), appID: 1, appName: "Game"),
            values: [:], pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift")
        let environment = PluginJobRunner.environment(for: job, temporaryDirectory: FileManager.default.temporaryDirectory)
        #expect(environment["SWIFTLIGHT_HOST_NAME"]!.utf8.count <= 4096)
        #expect(environment["SWIFTLIGHT_SESSION_ID"] == "id")
    }

    @Test @MainActor func importRefreshAndStorageKeepCodeDisabledAndSecretsOutOfJSON() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plugin.yaml"), storage = directory.appendingPathComponent("installed.json")
        try Data(yaml().utf8).write(to: source)
        let secrets = PluginTestSecrets()
        let manager = PluginManager(storageURL: storage, secretStore: secrets, loadsSavedPlugins: false)
        await manager.importPlugin(from: source)
        let plugin = try #require(manager.plugins.first)
        #expect(!plugin.enabled)
        let values = ["output": directory.appendingPathComponent("output").path, "value": "before", "token": "secret-not-for-json"]
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: values, pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        manager.setEnabled(pluginID: plugin.id, true)
        #expect(manager.plugins.first?.enabled == true)
        let json = try String(contentsOf: storage, encoding: .utf8)
        #expect(!json.contains("secret-not-for-json"))
        #expect(try secrets.read(pluginID: plugin.id, fieldID: "token") == "secret-not-for-json")
        await manager.refreshPlugin(plugin.id)
        #expect(manager.plugins.first?.enabled == false)
        let reloaded = PluginManager(storageURL: storage, secretStore: secrets)
        for _ in 0..<20 where reloaded.plugins.first?.values["token"] != "secret-not-for-json" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reloaded.plugins.first?.values["token"] == "secret-not-for-json")
        #expect(reloaded.plugins.first?.enabled == false)
        await manager.shutdown(); await reloaded.shutdown()
    }

    @Test @MainActor func endHooksUseTheStartedStreamsImmutableConfigurationAfterRemoval() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plugin.yaml"), output = directory.appendingPathComponent("output")
        try Data(yaml().utf8).write(to: source)
        let runner = PluginJobRunner()
        let manager = PluginManager(storageURL: directory.appendingPathComponent("installed.json"), secretStore: PluginTestSecrets(), runner: runner, loadsSavedPlugins: false)
        await manager.importPlugin(from: source)
        let plugin = try #require(manager.plugins.first)
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: ["output": output.path, "value": "original", "token": ""], pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        manager.setEnabled(pluginID: plugin.id, true)
        manager.beginStream(context())
        manager.beginStream(context())
        #expect(await runner.waitUntilIdle())
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: ["output": output.path, "value": "changed", "token": ""], pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        manager.removePlugin(plugin.id)
        manager.endStream(sessionID: "session", reason: "disconnected")
        manager.endStream(sessionID: "session", reason: "disconnected")
        #expect(await runner.waitUntilIdle())
        #expect(try String(contentsOf: output, encoding: .utf8) == "stream.started|original\nstream.ended|original\n")
        await manager.shutdown()
    }

    @Test @MainActor func invalidSavedStateIsPreservedAndNeverEnabled() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("installed.json"), data = Data("corrupt-plugin-state".utf8)
        try data.write(to: storage)
        let manager = PluginManager(storageURL: storage, secretStore: PluginTestSecrets())
        #expect(manager.plugins.isEmpty)
        #expect(manager.error != nil)
        #expect(try Data(contentsOf: storage) == data)
    }

    @Test @MainActor func failedConfigurationPersistenceRestoresSecretsAndDisablesInMemory() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("installed.json"), source = directory.appendingPathComponent("plugin.yaml")
        try Data(yaml().utf8).write(to: source)
        let secrets = PluginTestSecrets()
        let configured = PluginManager(storageURL: storage, secretStore: secrets, loadsSavedPlugins: false)
        await configured.importPlugin(from: source)
        let plugin = try #require(configured.plugins.first)
        let values = ["output": directory.appendingPathComponent("output").path, "value": "old", "token": "old-secret"]
        #expect(await configured.saveConfiguration(pluginID: plugin.id, values: values, pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        configured.setEnabled(pluginID: plugin.id, true)
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        var changed = values; changed["token"] = "new-secret"
        #expect(await configured.saveConfiguration(pluginID: plugin.id, values: changed, pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift") == false)
        #expect(try secrets.read(pluginID: plugin.id, fieldID: "token") == "old-secret")
        #expect(configured.plugins.first?.values["token"] == "old-secret")
        #expect(configured.plugins.first?.enabled == false)
        await configured.shutdown()
    }

    @Test @MainActor func refreshPersistenceFailureDisablesOldCodeBeforeReadingTheSource() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("installed.json"), source = directory.appendingPathComponent("plugin.yaml")
        try Data(yaml().utf8).write(to: source)
        let manager = PluginManager(storageURL: storage, secretStore: PluginTestSecrets(), loadsSavedPlugins: false)
        await manager.importPlugin(from: source)
        let plugin = try #require(manager.plugins.first)
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: ["output": "/unused", "token": "", "value": ""], pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        manager.setEnabled(pluginID: plugin.id, true)
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: source)
        await manager.refreshPlugin(plugin.id)
        #expect(manager.plugins.first?.enabled == false)
        #expect(manager.error != nil)
        await manager.shutdown()
    }

    @Test @MainActor func shutdownDuringKeychainWriteRestoresTheSavedSecret() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("installed.json"), source = directory.appendingPathComponent("plugin.yaml")
        try Data(yaml().utf8).write(to: source)
        let secrets = PluginTestSecrets()
        let manager = PluginManager(storageURL: storage, secretStore: secrets, loadsSavedPlugins: false)
        await manager.importPlugin(from: source)
        let plugin = try #require(manager.plugins.first)
        let previous = ["output": "/unused", "token": "old-secret", "value": "old"]
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: previous, pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        secrets.blockNextWrite("new-secret")
        var changed = previous; changed["token"] = "new-secret"
        let pendingSave = Task { await manager.saveConfiguration(pluginID: plugin.id, values: changed, pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift") }
        let started = await Task.detached { secrets.waitForWriteStarted() }.value
        #expect(started)
        await manager.shutdown()
        secrets.allowWrite.signal()
        #expect(await pendingSave.value == false)
        #expect(try secrets.read(pluginID: plugin.id, fieldID: "token") == "old-secret")
        #expect(manager.plugins.first?.values["token"] == "old-secret")
    }

    @Test @MainActor func enablingRejectsTheKnownXcrunInterpreterShims() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plugin.yaml")
        try Data(yaml().replacingOccurrences(of: "runtime: bash", with: "runtime: python").utf8).write(to: source)
        let manager = PluginManager(storageURL: directory.appendingPathComponent("installed.json"), secretStore: PluginTestSecrets(), loadsSavedPlugins: false)
        await manager.importPlugin(from: source)
        let plugin = try #require(manager.plugins.first)
        #expect(await manager.saveConfiguration(pluginID: plugin.id, values: ["output": "/unused", "value": "", "token": ""], pythonExecutable: "/usr/bin/python3", swiftExecutable: "/usr/bin/swift"))
        manager.setEnabled(pluginID: plugin.id, true)
        #expect(manager.plugins.first?.enabled == false)
        #expect(manager.error?.contains("xcrun") == true)
        await manager.shutdown()
    }
}
#endif
