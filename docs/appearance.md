# Appearance and application library

Swiftlight uses native navigation, forms, menus, buttons, accessibility labels, and Liquid Glass where available on Mac, iPhone and iPad. The library presents host applications as a 3:4 cover grid. On Mac, hover or focus a cover to see its title and Play/Resume action. On iPhone and iPad, titles remain visible beneath each cover; larger accessibility text uses one column with wrapping titles. An unavailable cover uses a titled fallback.

Reduce Transparency, Increased Contrast, and Reduce Motion are respected. Controls remain usable without artwork, and video remains the primary content during a stream.

Artwork is loaded from the paired host into a bounded, memory-only cache. Cover data is not persisted to disk. A host change, unpair, or trust change clears older artwork so results from a previous computer cannot appear in the selected library.

Visual quality and accessibility behavior can vary with the OS version, display, and host artwork. See [development appearance notes](dev/appearance-implementation.md) for resource limits and validation evidence.
