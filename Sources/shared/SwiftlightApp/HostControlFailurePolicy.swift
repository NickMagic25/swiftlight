import SwiftlightHost

/// Host-control decisions shared by platform coordinators. A quit refusal is an
/// operation permission error; it must not make a changed certificate or host
/// identity eligible for recovery using stale authenticated library state.
enum HostControlFailurePolicy {
    static func requiresTrustReview(_ error: any Error) -> Bool {
        switch error {
        case HostError.certificateChanged, HostError.identityChanged: true
        default: false
        }
    }

    static func permitsQuitRefusalRefresh(_ error: any Error, confirmedQuit: Bool) -> Bool {
        guard confirmedQuit else { return false }
        if case HostError.permissionDenied = error { return true }
        return false
    }
}
