#if os(macOS)
import Darwin
import Foundation
import SwiftlightPlugins

struct PluginJob: Sendable {
    let pluginID: UUID
    let hook: PluginHook
    let context: PluginStreamContext
    let values: [String: String]
    let pythonExecutable: String
    let swiftExecutable: String
}

enum PluginJobResult: Sendable, Equatable {
    case succeeded, failed, timedOut, cancelled, runtimeUnavailable
    var description: String {
        switch self {
        case .succeeded: "Plugin hook completed."
        case .failed: "Plugin hook failed. Check the reviewed script and its configuration."
        case .timedOut: "Plugin hook exceeded its time limit and was stopped."
        case .cancelled: "Plugin hook was stopped."
        case .runtimeUnavailable: "The configured plugin interpreter is unavailable or cannot run in this app's sandbox."
        }
    }
}

/// One dedicated serial worker owns child creation/reaping. The condition protects
/// admission, cancellation generations and idle state; stream callbacks never wait.
final class PluginJobRunner: @unchecked Sendable {
    static let maximumJobs = 64
    private let condition = NSCondition()
    private let worker = DispatchQueue(label: "net.swiftlight.plugins.worker", qos: .utility)
    private var jobs: [PluginJob] = []
    private var working = false
    private var cancellationGeneration = 0
    private var accepting = true
    private var completion: @Sendable (UUID, PluginJobResult) -> Void

    init(completion: @escaping @Sendable (UUID, PluginJobResult) -> Void = { _, _ in }) {
        self.completion = completion
    }

    func setCompletion(_ completion: @escaping @Sendable (UUID, PluginJobResult) -> Void) {
        condition.lock(); self.completion = completion; condition.unlock()
    }

    @discardableResult func enqueue(_ newJobs: [PluginJob]) -> Bool {
        guard !newJobs.isEmpty else { return true }
        condition.lock()
        guard accepting, jobs.count + newJobs.count + (working ? 1 : 0) <= Self.maximumJobs else {
            condition.unlock(); return false
        }
        jobs.append(contentsOf: newJobs)
        if !working {
            working = true
            worker.async { self.runLoop() }
        }
        condition.unlock()
        return true
    }

    func cancelAll() {
        condition.lock()
        jobs.removeAll(); cancellationGeneration += 1
        condition.broadcast(); condition.unlock()
    }

    /// End hooks receive a bounded opportunity to run at app shutdown. Timeout
    /// closes the queue and cancels the active process group, including children.
    func shutdown(graceSeconds: TimeInterval = 5) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(max(0, min(graceSeconds, 5)))
                self.condition.lock(); self.accepting = false
                while self.working && Date() < deadline { _ = self.condition.wait(until: deadline) }
                if self.working {
                    self.jobs.removeAll(); self.cancellationGeneration += 1
                    let cancellationDeadline = Date().addingTimeInterval(1)
                    while self.working && Date() < cancellationDeadline { _ = self.condition.wait(until: cancellationDeadline) }
                }
                self.condition.unlock(); continuation.resume()
            }
        }
    }

    func waitUntilIdle(timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(timeout)
                self.condition.lock()
                while self.working && Date() < deadline { _ = self.condition.wait(until: deadline) }
                let idle = !self.working
                self.condition.unlock(); continuation.resume(returning: idle)
            }
        }
    }

    private func runLoop() {
        while true {
            condition.lock()
            guard !jobs.isEmpty else {
                working = false; condition.broadcast(); condition.unlock(); return
            }
            let job = jobs.removeFirst(), generation = cancellationGeneration
            condition.unlock()
            let result = Self.run(job) { self.isCancelled(generation) }
            condition.lock(); let callback = completion; condition.unlock()
            callback(job.pluginID, result)
        }
    }

    private func isCancelled(_ generation: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return generation != cancellationGeneration
    }

    static func environment(for job: PluginJob, temporaryDirectory: URL) -> [String: String] {
        func safe(_ value: String) -> String {
            var bytes = Array(value.utf8.lazy.filter { $0 != 0 }.prefix(4096))
            while !bytes.isEmpty {
                if let result = String(bytes: bytes, encoding: .utf8) { return result }
                bytes.removeLast()
            }
            return ""
        }
        var result = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                      "TMPDIR": temporaryDirectory.path,
                      "CLANG_MODULE_CACHE_PATH": temporaryDirectory.appendingPathComponent("ModuleCache").path,
                      "SWIFT_MODULECACHE_PATH": temporaryDirectory.appendingPathComponent("ModuleCache").path,
                      "SWIFTLIGHT_EVENT": job.hook.event.rawValue,
                      "SWIFTLIGHT_SESSION_ID": safe(job.context.sessionID),
                      "SWIFTLIGHT_HOST_ID": safe(job.context.hostID),
                      "SWIFTLIGHT_HOST_NAME": safe(job.context.hostName),
                      "SWIFTLIGHT_APP_ID": String(job.context.appID),
                      "SWIFTLIGHT_APP_NAME": safe(job.context.appName),
                      "SWIFTLIGHT_END_REASON": safe(job.context.endReason ?? "")]
        for (key, value) in job.values { result["SWIFTLIGHT_FIELD_" + key.uppercased()] = value }
        if job.hook.runtime == .swift, let sdk = PluginRuntimePaths.swiftSDKPath(for: job.swiftExecutable) {
            result["SDKROOT"] = sdk
        }
        return result
    }

    private static func run(_ job: PluginJob, isCancelled: @escaping @Sendable () -> Bool) -> PluginJobResult {
        if isCancelled() { return .cancelled }
        let executable: String, suffix: String
        switch job.hook.runtime {
        case .bash: executable = "/bin/bash"; suffix = "sh"
        case .python: executable = job.pythonExecutable; suffix = "py"
        case .swift: executable = job.swiftExecutable; suffix = "swift"
        }
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            return .runtimeUnavailable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlight-plugin-" + UUID().uuidString)
        let script = directory.appendingPathComponent("hook." + suffix)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(job.hook.script.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        } catch { try? FileManager.default.removeItem(at: directory); return .failed }
        defer { try? FileManager.default.removeItem(at: directory) }

        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .failed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // pgroup zero creates a new process group with the spawned PID atomically,
        // avoiding the launch/setpgid race when a script immediately forks.
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { return .failed }
        let changeDirectoryStatus: Int32
        if #available(macOS 26, *) {
            changeDirectoryStatus = posix_spawn_file_actions_addchdir(&actions, directory.path)
        } else {
            changeDirectoryStatus = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }
        guard changeDirectoryStatus == 0 else { return .failed }
        let runtimeArguments: [String]
        if job.hook.runtime == .swift {
            guard let sdk = PluginRuntimePaths.swiftSDKPath(for: executable) else { return .runtimeUnavailable }
            runtimeArguments = [executable, "-module-cache-path", directory.appendingPathComponent("ModuleCache").path,
                                "-sdk", sdk, script.path]
        } else { runtimeArguments = [executable, script.path] }
        var arguments = runtimeArguments.map { strdup($0) }
        var environment = Self.environment(for: job, temporaryDirectory: directory).sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
        defer { arguments.compactMap { $0 }.forEach { free($0) }; environment.compactMap { $0 }.forEach { free($0) } }
        arguments.append(nil); environment.append(nil)
        var pid: pid_t = 0
        let spawnResult = arguments.withUnsafeMutableBufferPointer { arguments in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        guard spawnResult == 0 else { return .runtimeUnavailable }

        let deadline = ProcessInfo.processInfo.systemUptime + Double(job.hook.timeoutSeconds)
        var status: Int32 = 0
        while true {
            let wait = waitpid(pid, &status, WNOHANG)
            if wait == pid {
                // Background descendants cannot outlive a completed hook.
                kill(-pid, SIGKILL)
                return status == 0 ? .succeeded : .failed
            }
            if wait == -1 && errno != EINTR { kill(-pid, SIGKILL); return .failed }
            let cancelled = isCancelled()
            if cancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                kill(-pid, SIGTERM)
                usleep(100_000)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                return cancelled ? .cancelled : .timedOut
            }
            usleep(20_000)
        }
    }
}
#endif
