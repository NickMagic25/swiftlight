import Testing
@testable import SwiftlightApp

struct AppBuildIdentityTests {
    @Test func releaseIdentityKeepsBuildAndShortensCommit() {
        let sha = "A1B2C3D" + String(repeating: "E", count: 33)
        let identity = AppBuildIdentity(infoDictionary: ["CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "42", "GitCommitSHA": sha])
        #expect(identity.commitSHA == sha.lowercased())
        #expect(identity.displayVersion == "0.2.0 (42, a1b2c3d)")
        #expect(identity.accessibilityValue == "0.2.0, build 42, commit a1b2c3d")
    }

    @Test func missingCommitStillShowsVersionAndBuild() {
        let identity = AppBuildIdentity(infoDictionary: ["CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "42"])
        #expect(identity.displayVersion == "0.2.0 (42)")
        #expect(identity.accessibilityValue == "0.2.0, build 42")
        #expect(identity.commitSHA == nil)
    }

    @Test(arguments: ["", "$(SWIFTLIGHT_GIT_COMMIT_SHA)", "a1b2c3d", String(repeating: "g", count: 40)])
    func unavailableOrInvalidCommitIsOmitted(_ commit: String) {
        let identity = AppBuildIdentity(infoDictionary: ["CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "42", "GitCommitSHA": commit])
        #expect(identity.displayVersion == "0.2.0 (42)")
        #expect(identity.commitSHA == nil)
    }

    @Test func unbundledDevelopmentAndMissingBuildHaveNoEmptyDetails() {
        let unbundled = AppBuildIdentity(infoDictionary: [:])
        #expect(unbundled.displayVersion == "Development")
        #expect(unbundled.accessibilityValue == "Development")
        let versionOnly = AppBuildIdentity(infoDictionary: ["CFBundleShortVersionString": " 0.2.0 ",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)"])
        #expect(versionOnly.displayVersion == "0.2.0")
    }
}
