# Xcode Cloud and App Store Connect

`Swiftlight.xcodeproj` is the app build entrypoint for macOS, iOS and iPadOS.
The shared `Swiftlight` scheme builds the Mac app; `SwiftlightMobile` builds
one universal iPhone/iPad app. Xcode Cloud uses the same schemes, pinned
package dependencies and source membership as local Xcode builds.

The repository contains the build hooks and export configuration. Workflows,
Apple account access, tester groups and registered devices are managed in Xcode
or App Store Connect. Editing this repository does not create those remote
workflows, and a local simulator run does not verify Cloud signing or delivery.

## Repository support

| Product | Scheme | Bundle identifier | Minimum OS |
| --- | --- | --- | --- |
| Mac | `Swiftlight` | `net.edrisil.swiftlight` | macOS 14 |
| iPhone and iPad | `SwiftlightMobile` | `net.edrisil.swiftlight.ios` | iOS/iPadOS 26 |

The shared package supplies Core, Host, Transport and Video. The mobile app
uses UIKit and SwiftUI with the production `MoonlightAppleVideo` decoder and
Metal renderer. tvOS remains future work.

Each Cloud action starts in a separate environment. The scripts in
[`ci_scripts/`](../../ci_scripts/) provide these steps:

- `ci_post_clone.sh` prepares native dependencies for the action's scheme and
  resolves the committed package pins. Mobile archives prepare iOS device
  libraries. Other mobile actions prepare device and simulator libraries,
  because Cloud build actions can select either destination type. The Mac
  scheme prepares macOS libraries. iPhone and iPad use the same iOS SDK.
- `ci_pre_xcodebuild.sh` gives every Cloud build its `CI_BUILD_NUMBER`, including
  branch builds. Release tags also set the marketing version. Set
  `SWIFTLIGHT_RUN_VALIDATION=1` to run the existing SwiftPM, Python and native
  host checks before the action. That gate prepares its own macOS dependencies;
  it does not establish an iPhone or iPad runtime result.
- The mobile app's license-copy build phase packages the pinned third-party
  notices before signing. Missing inputs fail the build. The app also includes
  its icon and privacy manifest.

Follow the [local build guide](README.md#build-and-run-the-app-with-xcode) to
prepare a checkout. Mobile commands use `scripts/bootstrap-dependencies.sh
--platform ios-simulator` for Simulator and `--platform ios` for a device or
archive. `--platform all` prepares every supported native SDK variant.

## Account and product setup

1. Open `Swiftlight.xcodeproj` using an Xcode toolchain that supports the
   repository's Swift 6.3 requirement and the desired iOS SDK. Select the
   `SwiftlightMobile` target, the intended Apple Developer team and automatic
   signing. Keep personal team values out of committed project settings.
2. In Xcode's Cloud report navigator, set up the mobile product for
   `NickMagic25/swiftlight`. Retain the existing macOS product. Grant Apple's
   GitHub integration access to this repository, including its pinned recursive
   dependencies. All requested changes must be present on the remote branch
   before a Cloud build can consume them.
3. Set up distribution for `net.edrisil.swiftlight.ios`. Associate the existing
   matching App Store Connect record, or create the iOS app record for this
   target if none exists. iPadOS uses this same record. Confirm the team and
   identifier before creating it.
4. Create an internal TestFlight tester group and add the intended testers.
   Register the physical iPhone and iPad UDIDs in the same Developer team for
   ad-hoc installation. TestFlight does not require UDID registration.
5. Complete any account agreements and the product's required App Store Connect
   metadata, including the actual encryption and privacy declarations. Use the
   app's behavior and [dependency licensing record](../licensing.md), not a
   placeholder answer, when preparing distribution.

Apple's [Cloud distribution setup](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)
can associate or create the app record and configure internal testing. A
matching record and a successful archive are still required before testers
receive a build.

## Workflows

Configure the following in Xcode Cloud. The names are suggested names, not
proof that a workflow with that name exists in the account.

| Workflow | Start condition | Actions and destinations | Distribution |
| --- | --- | --- | --- |
| `Swiftlight PR` | Pull requests targeting `main` | Build `Swiftlight` for macOS; set `SWIFTLIGHT_RUN_VALIDATION=1` | None; preserve the existing Mac gate. |
| `Swiftlight Mobile PR` | Pull requests targeting `main` | Build `SwiftlightMobile` for Any iOS Simulator; test its UI test target on an iPhone and an iPad; set `SWIFTLIGHT_RUN_VALIDATION=1` | None. |
| `Swiftlight Mobile beta` | Changes to `main`, plus manual runs | Test the mobile scheme on both device families; archive `SwiftlightMobile` for iOS with Release configuration; set `SWIFTLIGHT_RUN_VALIDATION=1` | Deployment Preparation: **TestFlight (Internal Testing Only)**. Add an internal TestFlight post-action for the tester group; retain the ad-hoc IPA artifact. |
| `Swiftlight Mobile release` | Protected `ios-v*` tags | Test both families; archive `SwiftlightMobile` for iOS with Release configuration; clean environment and restricted workflow editing; set `SWIFTLIGHT_RUN_VALIDATION=1` | Deployment Preparation: **TestFlight and App Store**. Add the intended TestFlight group; retain the ad-hoc artifact. App Store submission remains a separate action. |
| `Swiftlight macOS direct` | Protected `macos-v*` tags | Archive `Swiftlight` for macOS | Preserve the Developer ID/direct-distribution migration described below. |

Select one iPhone and one iPad on the latest available iOS/iPadOS 26 runtime.
Also run the pair on iOS/iPadOS 27 using an Xcode Cloud environment that actually
provides that SDK and runtime. If the versions cannot coexist in one environment,
clone the mobile PR workflow and select the second Xcode/runtime pair there.
Do not relabel a 26 run as 27 coverage when the 27 environment is unavailable.
Pin the selected Xcode and macOS versions in the workflow so toolchain changes
are reviewable. The app continues to target iOS 26 when built with a newer SDK.

The UI test action exercises launch, host/settings navigation, forms and
rotation and retains screenshots in its result bundle. Test both device
families even though their executable is shared. Test results do not replace a
physical-device stream check: hardware decode, audio, local-network consent,
Keychain access and touch/controller input need an actual compatible host.

For the mobile native cryptography check, first bootstrap the simulator
libraries and boot the intended simulator, then run
`scripts/validate-mobile-crypto.sh <simulator-UDID>`. This exercises the actual
mobile static crypto build with ephemeral test data: random bytes, identity
and PKCS#12 creation, signing, tamper rejection and an AES vector. It saves
results and imported symbols under `.build/native-mobile-tests/`. It does not
use the app's Keychain or establish successful live host pairing. Keep this
as a focused local/device-tool check; the Cloud UI test action uses its normal
scheme and simulator destinations.

Apple distinguishes [build and archive actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
and their deployment preparation settings. Builds marked internal testing only
cannot later be promoted to external testing or the App Store; use a new release
archive for that path. External TestFlight distribution is subject to beta
review, as described in [distribution workflow configuration](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution).

### Version and channel isolation

Mobile release tags use `ios-vX.Y.Z`; Cloud Mac releases use `macos-vX.Y.Z`.
The existing GitHub `v*` workflow remains the macOS direct-download channel.
The pre-build hook rejects a tag from the wrong product and rejects prerelease,
malformed or ambiguous versions before changing either plist.

For example, mobile tag `ios-v0.2.0` and Cloud build `42` produce marketing
version `0.2.0`, build `42`, in `App/Mobile-Info.plist`. A later branch build
uses its checked-in marketing version and its own Cloud build number. Mac
builds update only `App/Info.plist`. Set the mobile Cloud product's next build
number above any previously uploaded build number; do not reset its counter
while reusing an App Store Connect version. Local builds retain their checked-in
version until explicitly versioned or built by Cloud.

Run the version and dispatch regression tests locally with:

```sh
python3 -m unittest discover -s Tests/Release -v
```

## Registered-device ad-hoc delivery

A successful iOS archive can provide a signed ad-hoc IPA as a Cloud artifact.
Apple exposes its export location through `CI_AD_HOC_SIGNED_APP_PATH`; the
TestFlight export uses `CI_APP_STORE_SIGNED_APP_PATH`. These are separate signed
exports of the same universal application. Confirm that both artifacts were
actually produced in the archive's report before calling both channels ready.
See Apple's [environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference).

Download and retain the ad-hoc artifact from the successful Cloud archive. If a
Cloud run did not produce it, download the `.xcarchive` and export locally using
the signing account for the same team:

```sh
scripts/export-mobile-adhoc.sh \
  .build/archives/SwiftlightMobile.xcarchive \
  .build/exports/SwiftlightMobile-ad-hoc
```

The helper checks that the archive is the universal Swiftlight iOS device app,
then uses [`Mobile-AdHoc-ExportOptions.plist`](../../App/Mobile-AdHoc-ExportOptions.plist).
Its `release-testing` method is the current Xcode name for ad-hoc distribution.
It retains the archive's version and team, exports one universal IPA, and allows
Xcode to refresh provisioning for already registered devices. It does not
register devices or upload to App Store Connect.

Install that IPA on the registered iPhone and iPad with Xcode's device tools or
Apple Configurator and verify launch and a real stream. If the registered-device
set changes, refresh the provisioning and re-export. A simulator `.app`, an
unsigned archive, or a successful export command alone is not a physical-device
installation result. Apple's [registered-device distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
describes device registration, profile selection and installation.

## Mobile bundle privacy and resources

`App/PrivacyInfo.xcprivacy` records `CA92.1` for the mobile app's own saved
preferences and `35F9.1` for elapsed-time measurements and timers. These match
`MobileClientModel`'s `UserDefaults` calls and the shared diagnostic timeline's
`systemUptime` use. The app does not automatically upload diagnostic reports or
send data to an analytics service. Review the manifest when adding a dependency
or a new required-reason API; do not declare file-timestamp access merely to
silence a validation message. Inspect the final linked device binary as well
as app source, because static native dependencies can contribute API imports.
Apple documents the [allowed API categories and reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

The mobile OpenSSL build disables stdio, POSIX file helpers, console prompts,
configuration autoloading and external module builds, and obtains secure random
bytes through Apple's system RNG. A documented [mobile-only source patch](../../patches/openssl/README.md)
omits the unused file-store registration from its default and base providers,
allowing static linking to remove the file-store object's `stat` import.
Swiftlight's pairing bridge uses memory BIOs and does not use this store.
The simulator crypto gate verifies identity/PKCS12, signatures, tamper rejection,
AES ECB/CBC/GCM vectors and unavailable file-store lookup. The relinked device
app was also checked for absent `stat`, `fstat` and `lstat` imports. Repeat these
checks after dependency changes and relinking; they do not replace signing,
privacy review or App Store Connect processing. Do not add a file-timestamp
reason merely to hide an unexpected dependency import.

The icon lives in `App/MobileAssets.xcassets`. Reproduce its opaque 1024-pixel
PNG with `CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift
scripts/generate-mobile-icon.swift`. The platform applies its own icon mask.

## Preserve the macOS release channel

The secondary `scripts/build-app.sh` packager remains in the GitHub macOS
release workflow until the Cloud distribution migration is validated. GitHub
continues to host source and release downloads; Apple-managed signing keys
remain in Apple's service when using Cloud-managed signing.

For Homebrew-compatible direct distribution, use the Cloud Developer ID signed
export at `CI_DEVELOPER_ID_SIGNED_APP_PATH`, package and notarize the DMG, then
upload only the verified artifact and checksum to the matching GitHub Release.
Use a repository-scoped publishing credential, without exporting Apple's
cloud-managed private keys to GitHub.

Do not replace the existing GitHub `Release macOS` workflow until one Cloud
archive has packaged all required licenses, produced a signed and notarized DMG,
and passed launch on a clean Gatekeeper-enabled Mac. The mobile license-copy
phase does not by itself complete this macOS migration. Preserve the existing
signing secrets until the replacement path has passed those checks.

See [cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates)
and [Mac distribution packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
for the Apple-managed path.
