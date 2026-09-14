# Xcode Cloud and App Store Connect

Swiftlight's primary app build entrypoint is `Swiftlight.xcodeproj`, locally
and in Xcode Cloud. The distribution migration described here makes Xcode Cloud
the Apple-managed signing authority. GitHub continues to host source and release
downloads, but must not receive an Apple distribution private key once the Cloud
release path is active.

## What is ready in this repository

`Swiftlight.xcodeproj` is a macOS app project that consumes this repository as
a local Swift package. Its checked-in `Swiftlight` scheme is the project and
scheme to select in Xcode Cloud. Follow the [local build guide](README.md#build-and-run-the-app-with-xcode)
for Xcode and `xcodebuild` development. `Package.swift` supplies the shared
modules and test/replay tooling. The secondary `scripts/build-app.sh` path
remains in use by the existing GitHub release workflow until distribution
migration is validated.

Each Cloud action runs in a new build environment. The scripts in
[`ci_scripts/`](../../ci_scripts/) bootstrap the pinned native dependencies and
resolve the committed decoder revision after cloning. Set the non-secret custom
environment variable `SWIFTLIGHT_RUN_VALIDATION=1` on a workflow to run the
repository's existing validation suite before the Xcode action.

## One-time account setup

1. Prepare dependencies using the [local build guide](README.md#build-and-run-the-app-with-xcode),
   then open `Swiftlight.xcodeproj` in Xcode 26.6 / Swift 6.3.3, select the `Swiftlight`
   target, choose the intended Apple Developer team, and retain automatic
   signing. The macOS bundle identifier is `net.edrisil.swiftlight`.
2. Choose **Xcode Cloud** in Xcode and create the first workflow. When Apple
   opens GitHub authorization, install its GitHub App for **only**
   `NickMagic25/swiftlight`.
3. In App Store Connect, grant only the necessary team members access to Xcode
   Cloud and cloud-managed Developer ID certificates. Do not export a
   Developer ID `.p12` for this path.
4. Accept any pending Apple Developer Program agreements before starting the
   build. Xcode Cloud creates or associates the matching macOS app record.

The iOS/iPadOS and tvOS clients are future application targets. The shared
package declares those platforms, but the current UI executable is macOS
AppKit-only. Create their App Store Connect records when their targets and
bundle identifiers exist; do not reserve placeholder records prematurely.

## Workflows to create

Create these workflows in Xcode Cloud after the first project build succeeds:

| Workflow | Start condition | Action | Signing/distribution |
| --- | --- | --- | --- |
| `Swiftlight PR` | Pull requests targeting `main` | Build the shared `Swiftlight` scheme for macOS | None; set `SWIFTLIGHT_RUN_VALIDATION=1`. |
| `Swiftlight macOS direct` | A protected `macos-v*` tag | Archive the shared scheme for macOS | Select Developer ID/direct distribution, then notarize the exported app. |
| `Swiftlight iOS TestFlight` | Later, after the iOS target exists | Archive | TestFlight internal testing first. |
| `Swiftlight tvOS TestFlight` | Later, after the tvOS target exists | Archive | TestFlight internal testing first. |

Use a distinct `macos-v*` tag namespace for the Cloud direct-distribution
workflow while the existing GitHub `v*` release workflow remains enabled. This
prevents a first Cloud test from publishing a duplicate release. The pre-build
script derives `CFBundleShortVersionString` from `macos-vX.Y.Z` and
`CFBundleVersion` from Xcode Cloud's monotonically increasing build number in
its disposable checkout.

## Direct macOS distribution and GitHub Releases

For a Homebrew-compatible direct distribution, use the Developer ID–signed app
export that Xcode Cloud exposes as `CI_DEVELOPER_ID_SIGNED_APP_PATH`. Package
and notarize the DMG inside the Cloud release workflow, then upload only the
verified DMG and checksum to the matching GitHub Release with a short-lived or
fine-grained GitHub credential scoped to this repository's release contents.

Do not move the existing GitHub `Release macOS` workflow to Cloud yet. First
complete one Cloud archive, verify the signed artifact on a clean,
Gatekeeper-enabled Mac, and confirm the Cloud workflow can package a signed,
notarized DMG with the required license notices. The current Xcode Resources
phase is empty; the script-based app packager copies those notices today, so
an Xcode archive is not yet an equivalent distribution bundle. Only then replace
the GitHub P12/app-password release path and
delete its signing secrets. This prevents a signing migration from interrupting
the current direct-download channel.

Apple keeps cloud-managed private keys; GitHub cannot use them to sign a DMG.
Therefore, GitHub's role in the final design is publishing the Cloud-created
artifact rather than recreating or signing it.

## References

- [Connecting Xcode Cloud to GitHub](https://developer.apple.com/documentation/xcode/connecting-xcode-cloud-to-github)
- [Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates)
- [Xcode Cloud environment variables](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
