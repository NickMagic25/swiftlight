# macOS releases

For ordinary app builds and debugging, use the [Xcode project](README.md#build-and-run-the-app-with-xcode). This page documents the existing GitHub distribution pipeline, which still invokes the secondary `scripts/build-app.sh` SwiftPM packager. The [Xcode Cloud migration](xcode-cloud.md) has separate archive, license-packaging and distribution acceptance gates before it replaces this workflow.

The [release workflow](../../.github/workflows/release.yml) runs **only when a `v*` tag is pushed**. It accepts stable SemVer tags such as `v0.0.1` and rejects incomplete versions, leading zeros, prerelease suffixes, and build metadata. Ordinary branch pushes and pull requests do not run this workflow. The first release is **0.0.1**.

## One-time GitHub setup

In **Settings → Secrets and variables → Actions → Repository secrets**, add:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 encoding of a password-protected `.p12` export containing exactly one **Developer ID Application** certificate and its private key. Export it from Keychain Access. Apple Development and Mac App Distribution certificates are not substitutes. |
| `DEVELOPER_ID_P12_PASSWORD` | The nonempty password chosen when exporting that `.p12`. |
| `APPLE_ID` | Apple Account email authorized to notarize for the developer team. |
| `APPLE_TEAM_ID` | The certificate's Apple Developer team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | An app-specific password for that Apple Account, created at Apple's account website. Use this instead of the account's login password. |

For example, import the certificate into a GitHub secret without printing its contents:

```sh
base64 < /path/to/DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo NickMagic25/swiftlight
```

Enter the other secrets through GitHub's UI or `gh secret set SECRET_NAME --repo NickMagic25/swiftlight` and its hidden input prompt. Never commit certificates, private keys, or passwords. The workflow generates a temporary keychain password, imports credentials only after tests pass, and deletes the keychain in an `always()` cleanup step. GitHub-hosted runners are ephemeral.

Ensure Actions is enabled, the repository permits the pinned official GitHub Actions, and the account has macOS runner capacity/budget. The build job uses `macos-26` (Apple silicon) and explicitly selects `/Applications/Xcode_26.6.app/Contents/Developer`, matching Swift 6.3 requirements. The app targets macOS 14 or later. This workflow produces an **arm64 DMG**, not an Intel or universal build.

Swiftlight and `moonlight-apple-decoder` are public. GitHub release downloads are therefore publicly accessible; make an explicit distribution decision before directing external users to the release page.

## Create the first release

After merging the reviewed branch containing this workflow, check out the exact commit to release and push an annotated tag:

```sh
git switch main
git pull --ff-only
git tag -a v0.0.1 -m "Release Swiftlight 0.0.1"
git push origin v0.0.1
```

The tag must include the workflow and scripts. Pushing a tag on the current feature branch also works when intentionally releasing that commit. Do not move or reuse a published release tag. Create future releases with `v0.0.2`, `v0.1.0`, or `v1.0.0` as appropriate.

The workflow:

1. Checks out the tagged commit with recursive submodules and resolves the decoder using the committed `Package.resolved` revision.
2. Runs `scripts/validate-ci.sh`: Swift tests, OTP vectors, dependency preparation tests, release version tests, packaging regression tests, native transport/audio tests under AddressSanitizer and UndefinedBehaviorSanitizer, artwork/display/window lifecycle harnesses, and the decoder source audit.
3. Builds `Swiftlight` with release optimization. `CFBundleShortVersionString` derives from the tag (`v0.0.1` → `0.0.1`); `CFBundleVersion` uses the positive GitHub workflow run number (unchanged on a rerun). Local builds default to build number `1`, overridable with `BUILD_NUMBER`. Only the staged app is updated; source files are not rewritten by CI. Signs the app with Developer ID, hardened runtime, and a secure timestamp.
4. Submits the app to Apple, waits for acceptance, staples its ticket, and checks Gatekeeper acceptance.
5. Creates `Swiftlight-0.0.1-macos-arm64.dmg` containing the app, an Applications shortcut, and installation instructions. Signs, notarizes, staples, and verifies the DMG. Calculates `SHA256SUMS.txt` **after** stapling.
6. Transfers only the verified installer and checksum to a separate job with release write permission. Creates a GitHub Release draft with automatically generated notes, attaches both files, then publishes it. This supports GitHub's immutable releases because the files are attached before publication.

Use **Actions → Release macOS** to inspect runs. Test output and Apple notarization logs are retained as `release-diagnostics`; the verified installer is also retained as `signed-installer`, both for 14 days. Release assets persist independently of Actions retention. Apple submissions have a 30-minute wait limit per artifact; if one times out, inspect its submission ID and log before retrying.

If a run fails, fix missing credentials or infrastructure and rerun the failed jobs. If source changes are needed, create a new tag at the fixed commit. A failed asset upload can leave a draft; a rerun completes that draft. A rerun refuses to overwrite an already published release. Do not pre-publish an empty release in the GitHub UI: **push the tag and let the workflow publish the completed release**. There is intentionally no second `release: published` trigger, avoiding duplicate builds and empty published releases.

## Reproduce the GitHub packaging path locally

These commands exercise the existing release packager. Use the Xcode build guide above for app development.

```sh
scripts/validate-ci.sh
CONFIGURATION=release RELEASE_TAG=v0.0.1 \
  SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
```

`scripts/package-dmg.sh` accepts `RELEASE_TAG`, `SIGNING_IDENTITY`, and optional `APP_PATH` and `OUTPUT_DIR` paths. It packages an already signed app. The workflow performs notarization and stapling around that script; running the packaging script alone does not produce a notarized installer.

The hardware decoder/Metal tests are explicitly skipped in CI. Run `scripts/validate-offline.sh` and `python3 scripts/validate-preview-lifecycle.py` on an authorized physical Mac, plus the documented live-host and display acceptance checks. GitHub runner test success does not establish hardware replay, HDR display, real streaming, or installation behavior on another Mac. Before promoting a release to end users, download the final DMG on a Gatekeeper-enabled Mac and verify mounting, dragging into Applications, launching, pairing, and streaming.

## Future Conventional Commits versioning

Tags are the version authority for this initial pipeline. Generated GitHub release notes describe the merged changes; they do not calculate the next version from commit messages.

For a later automatic versioning change, require Conventional Commit **PR titles** in a required PR check, enable squash-only merging with the PR title as the commit title, and protect the release branch against direct pushes. Local commit hooks alone cannot enforce repository history. Adopt titles such as `fix(video): correct frame accounting`, `feat(audio): add a layout option`, and `feat!: change the pairing protocol`, then configure release automation to compute the next version from those squash commits. Choose the breaking-change policy for `0.x` explicitly before enabling automatic bumps. Existing nonconventional history can remain behind the `v0.0.1` baseline.

If future automation creates tags using `GITHUB_TOKEN`, GitHub suppresses the resulting tag-push workflow run. That automation must call a reusable release workflow directly or push with a suitably scoped GitHub App token. The current pipeline expects a human tag push and needs no release-write personal token.

## References

- [GitHub macOS 26 runner software](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
- [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub release creation and generated notes](https://cli.github.com/manual/gh_release_create)
- [GitHub workflow triggering and token restrictions](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow)
