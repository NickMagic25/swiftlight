#if os(macOS)
import Foundation

/// Invoke installed interpreter binaries directly. Apple's /usr/bin Python and
/// Swift entries use xcrun, which cannot execute inside an App Sandbox.
enum PluginRuntimePaths {
    static let commandLineToolsRoot = "/Library/Developer/CommandLineTools"
    static let defaultXcodeDeveloperRoot = "/Applications/Xcode.app/Contents/Developer"

    static var defaultPythonExecutable: String {
        firstExecutable([defaultXcodeDeveloperRoot + "/usr/bin/python3",
                         commandLineToolsRoot + "/usr/bin/python3"]) ?? ""
    }
    static var defaultSwiftExecutable: String {
        firstExecutable([defaultXcodeDeveloperRoot + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
                         commandLineToolsRoot + "/usr/bin/swift"]) ?? ""
    }

    static func isXcrunShim(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return path == "/usr/bin/python3" || path == "/usr/bin/swift"
    }

    static func swiftSDKPath(for executable: String) -> String? {
        swiftSDKPath(for: executable, directoryExists: isDirectory)
    }

    static func swiftSDKPath(for executable: String, directoryExists: (String) -> Bool) -> String? {
        guard executable.hasPrefix("/"), !executable.contains("\0") else { return nil }
        let path = URL(fileURLWithPath: executable).standardizedFileURL.path
        var candidates: [String] = []
        if let toolchains = path.range(of: "/Toolchains/", options: .backwards) {
            let developerRoot = String(path[..<toolchains.lowerBound])
            candidates.append(developerRoot + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        }
        if path.hasPrefix(commandLineToolsRoot + "/") {
            candidates.append(commandLineToolsRoot + "/SDKs/MacOSX.sdk")
        }
        // A separately installed Swift toolchain can use the local CLT SDK.
        candidates.append(commandLineToolsRoot + "/SDKs/MacOSX.sdk")
        return candidates.first(where: directoryExists)
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { path in
            !isXcrunShim(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }
    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
#endif
