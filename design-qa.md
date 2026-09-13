# Liquid Glass and cover library QA

final result: blocked

## Visual target and scope

The source is the user's Moonlight Qt cover-grid screenshot at
`/var/folders/pr/j864tssj37x7r_fdy1hs0dhr0000gn/T/codex-clipboard-f62a3c79-3d5c-4ced-bfcf-ab3ab1387485.png`
(1700 × 912 pixels). The requested target is its portrait artwork hierarchy and
subtle active state, adapted to native Apple controls, typography and Liquid Glass;
it is not a pixel-for-pixel Qt clone. Native window chrome, rounded cover corners,
adaptive column counts, actual host library membership and semantic system colors
are intentional differences.

## Live application evidence

`artifacts/liquid-glass/pending-keychain.jpg` (1396 × 768, tool-scaled native window
capture) records the live application waiting for its existing saved pairing.
This capture and the reference were opened together in one comparison input. They
are different states: a loaded Qt library versus Swiftlight awaiting Keychain
authorization, so artwork density and fidelity cannot be scored from that pair.
CSS viewport and browser device scale do not apply to this native app.

`artifacts/liquid-glass-pending.sample` shows the main thread servicing AppKit's
event loop, with the host task blocked inside `SecItemCopyMatching` on a cooperative
worker. A protected macOS authorization dialog requires user interaction. Settings
opened and closed while the host request was pending. No stream-quality values
were changed. Live cover downloads, launch/resume, hover and keyboard activation
have not yet been verified on this build.

## Findings and comparison history

- Live library comparison is blocked by Keychain authorization. Build and protocol
  tests do not establish that the real host's covers are visible.
- Source review found canceled cover requests could remain unloaded after an early
  launch failure or disconnect. The grid now re-admits its instantiated covers
  when streaming becomes inactive; this complements its initial appearance load.
- No complete rendered-cover comparison has been accepted yet. A separate native
  `.build/AppearancePreview.app` was built from the production grid and glass views,
  with ten cached covers and a fixture store, to check layout independently of host
  access. When computer control attempted to open it, the tool reported that the
  Mac was locked and could not be unlocked automatically. The preview was not
  visually inspected; its build is not evidence of a passing visual comparison.

## Required fidelity surfaces

- **Typography:** native settings labels and values remain aligned and readable;
  cover title/fallback wrapping still needs rendered inspection.
- **Spacing and layout:** settings groups and footer actions remain in bounds;
  portrait grid, cover crop, gaps and narrow-window behavior remain to be checked.
- **Colors and tokens:** native semantic colors and real SwiftUI glass are used.
  Hover contrast and reduced-transparency rendering remain to be checked visually.
- **Image quality:** bounded PNG/JPEG and malformed-image tests pass. Real artwork
  subject, crop and sharpness require a rendered library comparison.
- **Copy and content:** existing settings wording and saved selections remain
  intact. The library uses explicit Play/Resume actions and full accessibility
  names; their rendered states remain to be checked.

## Implementation checklist

- [x] Integrated Swift build and 69 tests pass on arm64 macOS 26.6.2.
- [x] Existing signing identity used; strict signature verification passes.
- [x] Native settings open and close while the host is waiting.
- [x] Thirteen deterministic artwork-store checks pass, including cancellation
  concurrency, stale-host rejection, cache accounting, retry limits and ImageIO.
- [ ] Compare loaded artwork against the supplied reference.
- [ ] Verify hover, keyboard focus/activation, Resume and fallback title states.
- [ ] Verify adaptive width and accessibility appearance fallbacks.
- [ ] Unlock the Mac and complete live paired-host cover and stream-control checks
  after the protected Keychain authorization.

OS 27, older macOS runtimes, iOS, iPadOS and tvOS devices have not been tested.
