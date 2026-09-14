#!/bin/sh
# Export a signed iOS archive for the team's registered iPhone/iPad devices.
set -eu
if [ "$#" -ne 2 ]; then
  echo 'usage: scripts/export-mobile-adhoc.sh <SwiftlightMobile.xcarchive> <export-directory>' >&2
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d "$1/Products/Applications/SwiftlightMobile.app" ]; then
  echo 'error: Expected a SwiftlightMobile device archive' >&2
  exit 1
fi
python3 - "$1/Products/Applications/SwiftlightMobile.app/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
    raise SystemExit("error: Export requires an iOS device archive, not a Simulator build")
if info.get("CFBundleIdentifier") != "net.edrisil.swiftlight.ios" or set(info.get("UIDeviceFamily", [])) != {1, 2}:
    raise SystemExit("error: Export requires the universal Swiftlight iPhone/iPad app")
PY

# The archive supplies its signing team. Xcode uses the locally configured Apple
# account and can update provisioning for already-registered devices. This does
# not register new devices or upload the app to App Store Connect.
xcodebuild -exportArchive -archivePath "$1" -exportPath "$2" \
  -exportOptionsPlist "$repo_root/App/Mobile-AdHoc-ExportOptions.plist" \
  -allowProvisioningUpdates
