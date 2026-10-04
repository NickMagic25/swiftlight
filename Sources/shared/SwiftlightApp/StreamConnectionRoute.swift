import Foundation
import SwiftlightHost

/// Per-attempt endpoint and authenticated information. Library/control clients
/// and SavedHost persistence remain owned by their existing coordinators.
struct StreamConnectionRoute: Sendable {
    let client: HostClient
    let address: HostAddress
    let info: HostInfo

    static func resolve(client: HostClient, hostID: String) async throws -> StreamConnectionRoute {
        try Task.checkCancellation()
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SWIFTLIGHT_TEST_STREAM_HOST"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let address = try HostAddress(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            let alternate = try await client.authenticatedAlternate(address: address, hostID: hostID)
            try Task.checkCancellation()
            return StreamConnectionRoute(client: alternate.client, address: address, info: alternate.info)
        }
        #endif
        let address = await client.address
        let info = try await client.serverInfo()
        try Task.checkCancellation()
        guard info.id == hostID else { throw HostError.identityChanged }
        return StreamConnectionRoute(client: client, address: address, info: info)
    }
}
