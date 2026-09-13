#!/usr/bin/env python3
"""Derive macOS bundle versions from a stable SemVer release tag."""
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
    parser.add_argument("tag")
    parser.add_argument("--plist", type=Path)
    parser.add_argument("--build-number", default="1", help="Positive macOS bundle build number")
    args = parser.parse_args()
    try:
        version = version_from_tag(args.tag)
    except ValueError as error:
        parser.error(str(error))
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        parser.error("Build number must be a positive integer without leading zeros")
    if args.plist:
        with args.plist.open("rb") as source:
            info = plistlib.load(source)
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = args.build_number
        with args.plist.open("wb") as destination:
            plistlib.dump(info, destination, sort_keys=False)
    print(version)


if __name__ == "__main__":
    main()
