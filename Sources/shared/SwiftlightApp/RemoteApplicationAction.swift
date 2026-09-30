import Foundation
import SwiftlightHost

/// Shared presentation of an explicitly confirmed remote mutation. The platform
/// coordinator still validates its host/operation generation before performing it.
struct RemoteApplicationAction: Identifiable {
    let id = UUID()
    let hostID: String
    let controlGeneration: UInt64?
    let runningApp: RemoteApp
    let nextApp: RemoteApp?

    init(hostID: String, controlGeneration: UInt64? = nil, runningApp: RemoteApp, nextApp: RemoteApp?) {
        self.hostID = hostID
        self.controlGeneration = controlGeneration
        self.runningApp = runningApp
        self.nextApp = nextApp
    }

    var title: String { nextApp == nil ? "Quit Remote Application?" : "Switch Applications?" }
    var message: String {
        let consequence = "This quits \(runningApp.name) on your computer and ends its current stream. Any unsaved progress may be lost."
        return nextApp.map { consequence + " Then \($0.name) will start." } ?? consequence
    }

    static func library(apps: [RemoteApp], host: HostInfo?) -> [RemoteApp] {
        guard let id = host?.currentAppID, id > 0, host?.isPaired == true,
              !apps.contains(where: { $0.id == id }) else { return apps }
        return apps + [RemoteApp(id: id, name: "Running application")]
    }
}
