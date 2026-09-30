#!/usr/bin/env python3
"""Set bundle versions from a stable SemVer tag or an existing marketing version."""
import argparse
import plistlib
import re
from pathlib import Path


def version_from_tag(tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Use a stable SemVer tag such as v0.0.1 (no leading zeros or suffixes)")
    return tag[1:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", nargs="?", help="Stable SemVer tag; omit to retain the plist marketing version")
    parser.add_argument("--plist", type=Path)
    parser.add_argument("--build-number", default="1", help="Positive bundle build number")
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        parser.error("Build number must be a positive integer without leading zeros")
    if not args.tag and not args.plist:
        parser.error("A plist is required when retaining the marketing version")
    info = None
    if args.plist:
        with args.plist.open("rb") as source:
            info = plistlib.load(source)
    try:
        tag = args.tag if args.tag is not None else "v" + info.get("CFBundleShortVersionString", "")
        version = version_from_tag(tag)
    except (TypeError, ValueError) as error:
        parser.error(str(error))
    if args.plist:
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = args.build_number
        with args.plist.open("wb") as destination:
            plistlib.dump(info, destination, sort_keys=False)
    print(version)


if __name__ == "__main__":
    main()
