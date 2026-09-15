# App signing

## Xcode app builds

Build and run the app through `Swiftlight.xcodeproj` and the shared `Swiftlight` scheme, following the [development build guide](README.md#build-and-run-the-app-with-xcode). One app target supports Mac, iPhone and iPad destinations with automatic signing. Choose the intended team under **Signing & Capabilities**, or supply `DEVELOPMENT_TEAM=YOUR_TEAM_ID` to `xcodebuild` using your actual team ID. The Mac and iOS builds retain their established SDK-specific bundle identifiers; selecting a destination does not create a separate target or change existing app identity. See [Cloud and iOS distribution](xcode-cloud.md) for TestFlight and registered-device exports.

Use a stable development identity and the existing `net.edrisil.swiftlight` bundle identifier for repeated pairing/permission checks. Xcode signing is controlled by its project/build settings; `SIGNING_IDENTITY` and the automatic certificate-selection rules below belong to the secondary shell packager. They do not configure Xcode.

The terminal recipe writes `.build/xcode/Build/Products/Debug/Swiftlight.app`; the Xcode GUI uses its configured Derived Data location. Stop the running app before rebuilding/relaunching for validation. Xcode builds do not use the shell packager's staging and atomic-exchange implementation.

A local signed build or archive is not a notarized, distribution-qualified installer. Follow [Xcode Cloud](xcode-cloud.md) and [release validation](releases.md) for archive export, required license notices, notarization and clean-Mac acceptance. Keychain authorization may still require normal user interaction with a correctly signed app.

## Secondary SwiftPM app packager

`scripts/build-app.sh` remains available for the existing GitHub release and packaging workflow. It produces `.build/Swiftlight.app`. The following signing table, environment variables and bundle-replacement guarantees apply to that script.

`scripts/build-app.sh` chooses signing before building dependencies or compiling:

| Configuration | `SIGNING_IDENTITY` | Behavior |
| --- | --- | --- |
| Debug | Explicit certificate name or hash | Uses that identity exactly; skips automatic lookup. |
| Debug | Explicit `-` | Uses ad-hoc signing and prints the Keychain rebuild notice. |
| Debug | Unset; exactly one valid Apple Development or Developer ID Application identity | Selects that certificate by its hash. Repeated listings of the same hash count once. |
| Debug | Unset; no matching identity | Uses ad-hoc signing and prints the Keychain rebuild notice. |
| Debug | Unset; multiple matching identities | Stops and requires an explicit choice. |
| Release | Explicit real certificate name or hash | Uses that identity; signing or validation failures stop installation. |
| Release | Unset, empty, or `-` | Stops. Release builds never silently become ad-hoc builds. |

An empty explicit override is an error in either configuration. Automatic lookup uses `security find-identity -v -p codesigning`; lookup failure stops the build instead of treating an unknown result as an empty certificate list. No personal certificate name or hash is stored in the repository.

Examples:

```sh
# Debug: use the sole matching stable identity, when available.
scripts/build-app.sh

# Explicit debug-only ad-hoc build.
SIGNING_IDENTITY=- scripts/build-app.sh

# Choose a certificate name or SHA-1 shown by security find-identity.
SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' scripts/build-app.sh
CONFIGURATION=release SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
```

## Keychain behavior

An ad-hoc signature can give each rebuilt executable a different code identity, so macOS may ask again before allowing access to existing login-Keychain items. Using a stable signing certificate and bundle identifier keeps the app identity consistent across rebuilds. Switching from an earlier ad-hoc build to the stable certificate can still require an initial authorization; existing item access controls, Keychain lock state, and certificate changes also remain relevant.

Signing does not grant unrestricted Keychain access. The build script does not modify Keychain access controls, export private keys, change the client identity, remove pairing records, or change the app's Keychain backend. macOS may ask to authorize use of the signing private key when `codesign` runs. Release signing here is not notarization, distribution approval, or release qualification.

## Script bundle replacement

The script assembles the complete bundle under a unique `.build/.Swiftlight-stage.*` directory, then signs it, runs strict signature verification, validates its Info.plist, and checks for Homebrew dynamic-library dependencies. It never copies a newly built executable over the installed bundle's executable.

Only after all checks pass does the script publish the staged bundle. For an existing app, the public macOS `renamex_np` API with `RENAME_SWAP` exchanges the two directories atomically on the same volume. The old bundle moves into the staging directory for cleanup; an already-open executable keeps its original inode and contents. First installation uses a directory rename. A failed build, signature, validation, or atomic exchange leaves the old app intact. A filesystem that cannot perform the exchange fails without using an unsafe overwrite fallback. Symlink/non-directory destinations are rejected.

This prevents truncating an app that is running; it does not reload that process into the new build. Quit and reopen Swiftlight to run the replacement.

## Script packaging validation

Run the isolated packaging checks from the repository root:

```sh
python3 Tests/BuildPackaging/test_build_app.py --output artifacts/build-packaging-tests.json
```

The report records the tested `scripts/build-app.sh` SHA-256. Fixture directories are automatically removed, and every check remains active under Python optimization.

`bash -n scripts/build-app.sh` passed. Nineteen isolated fixture cases passed with bootstrap, compiler, identity lookup, signing, plist, and library-inspection commands replaced by stubs. They covered zero/one/multiple/duplicate identities, Developer ID selection, explicit overrides, invalid configuration, release restrictions, lookup/signature/validation failures, first installation, and symlink rejection. The fixtures used the real directory-exchange API and verified that an open old executable retained its contents while the installed path changed to the new inode. Failed cases preserved the old fixture bundle and cleaned staging.

These checks did not run a real app build, enumerate real identities, sign with a private key, or verify actual Keychain authorization behavior. A real signed build and subsequent application launch remain separate validation steps.

The final app build selected the available Apple Development identity and passed strict signature verification, including after copying to `.build/Verified/Swiftlight.app`. Two successive rebuilt executables have the same designated requirement (`artifacts/signing-identity-comparison.json`). The app opened the existing authenticated library after rebuilding. This does not claim an approval-free migration from the earlier ad-hoc identity or distribution/notarization qualification.
