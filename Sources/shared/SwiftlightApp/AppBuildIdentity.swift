import Foundation
import SwiftUI

struct AppBuildIdentity: Equatable, Sendable {
    static let current = AppBuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let version: String
    let buildNumber: String?
    let commitSHA: String?

    init(infoDictionary: [String: Any]) {
        version = Self.string(infoDictionary["CFBundleShortVersionString"]) ?? "Development"
        buildNumber = Self.string(infoDictionary["CFBundleVersion"])
        let commit = Self.string(infoDictionary["GitCommitSHA"])
        if let commit, [40, 64].contains(commit.utf8.count),
           commit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            commitSHA = commit.lowercased()
        } else {
            commitSHA = nil
        }
    }

    var shortCommitSHA: String? { commitSHA.map { String($0.prefix(7)) } }

    var displayVersion: String {
        let details = [buildNumber, shortCommitSHA].compactMap { $0 }.joined(separator: ", ")
        return details.isEmpty ? version : "\(version) (\(details))"
    }

    var accessibilityValue: String {
        ([version] + [buildNumber.map { "build \($0)" }, shortCommitSHA.map { "commit \($0)" }]
            .compactMap { $0 }).joined(separator: ", ")
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

struct AppBuildIdentitySection: View {
    let identity: AppBuildIdentity

    init(identity: AppBuildIdentity = .current) { self.identity = identity }

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: identity.displayVersion)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("App version")
                .accessibilityValue(identity.accessibilityValue)
                .accessibilityIdentifier("appBuildIdentity")
        }
    }
}
