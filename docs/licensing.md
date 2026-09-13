# Dependency licensing and distribution

Swiftlight's existing repository LICENSE is GPL-3.0. This is a GPL source distribution, not an App Store distribution/signing approval. Consult the incorporated license text for obligations; distribution must preserve corresponding-source availability, licenses and notices.

| Component | Pin | License / notice |
|---|---|---|
| Swiftlight | this source tree | repository LICENSE, GPL-3.0 |
| MoonlightAppleVideo | 8d92ee039dc19fe50dc0158d5098d4c5646c6a56 | decoder repository LICENSE (GPL v3); separate SwiftPM source dependency |
| moonlight-common-c | 62e066388f1a1b133e0bee947b9a374311a3354b | Git submodule LICENSE.txt; GPL v3; explicit targeted patch series |
| ENet | aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1 | recursive submodule LICENSE; MIT |
| nanors | b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a | recursive submodule licenses, Reed-Solomon implementation and dependencies |
| Opus | 1.5.2 | BSD-style COPYING in downloaded source; statically built, audio only |
| OpenSSL | 3.6.4 | Apache-2.0 LICENSE.txt in downloaded source; statically built crypto |

Bootstrap verifies pinned archive hashes before compilation. Preserve Opus/OpenSSL license copies when distributing the built app. The app bundle build copies notices into Resources. Apple system frameworks are linked through public SDKs. No FFmpeg, Qt, SDL, copied upstream client video decoder, software video decoder or alternative VideoToolbox path is linked into Swiftlight.

Fixture images are deterministically generated patterns created for this repository. Fixture manifests/provenance document encoders and commands. Encoder tooling is used only offline to prepare test media, never shipped as a decoder dependency.
