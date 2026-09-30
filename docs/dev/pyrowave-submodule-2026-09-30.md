# PyroWave fork submodule conversion, September 30, 2026

The local `moonlight-apple-decoder` now compiles PyroWave directly from its
`Dependencies/pyrowave` Git submodule, whose URL is
`https://github.com/NickMagic25/pyrowave.git`. It was cloned from the existing
sibling checkout to avoid downloading the repository. The committed baseline
revision is `89f7e47d4abbf650c91fae766728af866c5e32a0`; protocol identity remains
`186f0393`. The standalone sibling clone remains unchanged.

At the end of conversion validation, the submodule branch
`codex/apple-decoder-integration` retained three uncommitted
file changes: nonblocking upload capacity and its `BUSY` result, initialized
upload padding, texture/device validation and bounded sideband validation.
Those changes required a fork commit and publication before the decoder could
pin a remotely reproducible integration revision. No repository was
committed or pushed during this conversion, and Swiftlight's remote decoder
revision and lockfiles were not changed.

The copied production directory and test encoder were removed after their
originals were preserved under the decoder's ignored
`.build-pyrowave/submodule-migration-baseline/`. All active dependency files and
the test encoder match those preserved inputs byte for byte. CMake and SwiftPM
compile only the parser, common device and Metal decoder in the production
static library. The fork's encoder is a test/benchmark input. Raw `.metal`
files are excluded from SwiftPM resources; runtime compilation still uses the
fork's generated shader-string header.

Decoder CI now checks out recursive submodules. Swiftlight's two packaging
paths copy `Dependencies/pyrowave/LICENSE`, and the Xcode license phase declares
its `PyroWave.txt` output. See [dependency maintenance](dependencies.md#pyrowave-in-the-decoder-package)
for local initialization and publication order.

## Local commit checkpoint

After conversion validation, the three integration files were committed on
`codex/apple-decoder-integration` as
`488564aa2b5ffca0377938c27a1b67fce817c5b9`. The decoder's local commit
`dd295065417344a0a5d3d240bce9060d2646851c` pins that revision, and the Swiftlight
work is saved separately on `codex/pyrowave`.
These commits were not pushed. Swiftlight's immutable remote decoder pin remains
unchanged until the fork and decoder commits are published; local development
continues to use `SWIFTLIGHT_DECODER_PATH`. The verification below records the
conversion run, not a new test or live streaming run after committing.

## Conversion verification

- Decoder Debug CMake build: passed, including the test encoder from the fork.
- Nine portable native tests and the separate actual Metal test: passed.
- Decoder SwiftPM build and Swift C ABI/ownership smoke: passed.
- Swiftlight Xcode `Swiftlight` scheme, Debug, My Mac, local decoder override:
  passed. Normal macOS signature verification passed and the bundled PyroWave
  notice matches the submodule's license.
- Two focused license tests and 22 packaging fixtures: passed.
- Swiftlight `scripts/validate-ci.sh` with the local decoder override: passed.
  Its hardware tests remain intentionally disabled; the focused decoder Metal
  test above provides separate GPU evidence.
- Project plist lint, native/client/submodule whitespace checks and source
  review: passed.

Evidence is under ignored `artifacts/pyrowave-stage-2026-09-30/`, including
`submodule-migration.json`, `packaging-pyrowave-submodule.json`,
`xcode-submodule-build.log` and `ci-submodule-system.log`.

This is a dependency-layout conversion with preserved behavior, not a measured
GPU optimization. No new live streaming, mobile device or physical display
acceptance was claimed. A fresh remote build cannot reproduce the local fork
edits until the fork revision and parent gitlink are published.
