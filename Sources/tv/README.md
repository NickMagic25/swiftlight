# Future tvOS adapter

Reserve this directory for tvOS-specific scenes, focus, remote input and native
integration. Common features belong in `Sources/shared`.

There is no tvOS app destination yet. When the port begins, add tvOS support to
the existing multiplatform `Swiftlight` target and use `#if os(tvOS)` for native
adapters. This folder is visible in Xcode but is not part of the current app's
source or resource membership.
