# Swiftlight development documentation

This directory contains engineering notes, implementation references, validation records, benchmark procedures, dependency maintenance, and release/signing instructions. These documents may describe incomplete experiments or environment-specific validation and are not a substitute for the user guide.

## Build and run the app with Xcode

`Swiftlight.xcodeproj` and its shared **Swiftlight** scheme are the primary app build, run, debug and archive entrypoints. `Package.swift` defines the shared engine modules consumed by that project and the existing test/replay tools. Open the project for app development.

Use Xcode 26.6 / Swift 6.3.3 and the native tools listed in the [root requirements](../../README.md#requirements). The app project targets Apple silicon Macs running macOS 14 or later.

From the repository root:

```sh
scripts/bootstrap-dependencies.sh
open Swiftlight.xcodeproj
```

Select the **Swiftlight** scheme, **My Mac** destination and your development team under the target's **Signing & Capabilities**, retaining automatic signing. Use **Product → Build** or **Product → Run**. The checked-in team is empty; configure your actual team locally. Bootstrap is required before the first local Xcode build and after native dependency inputs change. The local project has no bootstrap build phase; the [Xcode Cloud hooks](xcode-cloud.md) perform that preparation only in Cloud.

For a terminal build of the same project:

```sh
scripts/bootstrap-dependencies.sh
xcodebuild -project Swiftlight.xcodeproj -scheme Swiftlight \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode DEVELOPMENT_TEAM=YOUR_TEAM_ID build
open .build/xcode/Build/Products/Debug/Swiftlight.app
```

Replace `YOUR_TEAM_ID` with your development team ID, or omit that setting if the intended team is already configured in the project. This command fixes the build output location; Xcode's GUI uses its configured Derived Data location. Quit an existing Swiftlight instance before launching the new build so the running process matches the artifact being tested. See [signing](signing.md) for Keychain identity and distribution boundaries.

For an archive, use **Product → Archive** with the shared scheme, whose Archive action selects Release. Distribution still requires license notices, export/signing, notarization and clean-Mac acceptance. Follow [Xcode Cloud and distribution migration](xcode-cloud.md) and the [existing release pipeline](releases.md); a successful local archive alone does not complete those steps.

## Verify shared modules and native integration

The Xcode scheme currently has no test targets. Continue using the repository's SwiftPM and native validation commands; **Product → Test** or `xcodebuild test` does not replace them:

```sh
scripts/validate-ci.sh
scripts/validate-offline.sh
```

`validate-ci.sh` bootstraps and runs the host-independent automated checks with hardware tests disabled. `validate-offline.sh` adds hardware VideoToolbox/Metal tests and fixture replay on a capable Mac, but omits some of CI's packaging and app harness checks. Run the gates appropriate to the change; neither proves live host/display acceptance. See [manual validation](manual-validation.md) and [video validation](video-validation.md).

Direct `swift test`, replay builds and app-source harnesses remain supported tooling. Harnesses that read `.build/debug` require SwiftPM build artifacts; an Xcode build under `.build/xcode` does not provide that layout. `scripts/validate-ci.sh` prepares the artifacts its harnesses need.

`scripts/build-app.sh` is the secondary SwiftPM app-packaging path still used by the current GitHub release workflow. It produces `.build/Swiftlight.app` and has its own signing and atomic-replacement behavior. Use it when working on that packaging workflow; use the Xcode project for ordinary app builds and debugging.

## Engineering references

- [Release CI, signing secrets, and DMG distribution](releases.md)
- [Xcode Cloud and App Store Connect migration](xcode-cloud.md)
- [Architecture](architecture.md)
- [Transport and ownership](transport.md)
- [Video lifetime](video-lifetime.md)
- [Stream statistics implementation](stream-statistics-implementation.md)
- [Audio implementation](audio-implementation.md)
- [Diagnostic export schema](diagnostic-exports-schema.md)
- [Host artwork protocol](host-artwork-protocol.md)
- [Host protocol details](host-protocol-details.md)
- [Verified assumptions](verified-assumptions.md)

## Validation and investigations

- [Acceptance matrix](acceptance-matrix.md)
- [Benchmarking](benchmarking.md)
- [Implementation report](implementation-report.md)
- [Manual validation](manual-validation.md)
- [Video validation](video-validation.md)
- [Pairing follow-up](pairing-fix-validation.md)
- [Presentation latency investigation](latency-optimization-2026-09-13.md)
- [Stream latency debugging](stream-latency-debugging.md)
- [Stream deadlock validation](stream-deadlock-validation.md)
- [Statistics overlay validation](statistics-metal-overlay-2026-09-13.md)
- [Statistics and shortcut validation](stream-statistics-validation.md)
- [Compatibility matrix snapshot](compatibility-matrix.md)

Validation artifacts and generated reports are under [`validation/`](validation/). Scripts used by those checks remain under [`scripts/`](../../scripts/).
