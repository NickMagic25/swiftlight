#!/usr/bin/env python3
"""Verify both Metal decoder source pins without resetting local work."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(directory, *arguments):
    return subprocess.check_output(["git", "-C", str(directory), *arguments], stderr=subprocess.PIPE).decode().strip()


def initialized(directory):
    try:
        return Path(git(directory, "rev-parse", "--show-toplevel")).resolve() == directory.resolve()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def verify(pin, label):
    path, revision = pin["path"], pin["revision"]
    checkout = ROOT / path
    if not checkout.resolve().is_relative_to(ROOT) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError("PyroWave requires an in-repository path and full immutable revision")
    entry = git(ROOT, "ls-files", "--stage", "--", path).split()
    if len(entry) != 4 or entry[:3] != ["160000", revision, "0"]:
        raise RuntimeError("PyroWave gitlink and Dependencies/versions.json must reference the same revision")
    module = pin.get("submodule", path)
    if git(ROOT, "config", "--file", ".gitmodules", "--get", f"submodule.{module}.path") != path:
        raise RuntimeError("PyroWave .gitmodules path and Dependencies/versions.json must match")
    url = git(ROOT, "config", "--file", ".gitmodules", "--get", f"submodule.{module}.url")
    if url != pin["url"]:
        raise RuntimeError("PyroWave .gitmodules URL and Dependencies/versions.json must match")
    if not initialized(checkout):
        subprocess.run(["git", "-C", str(ROOT), "submodule", "update", "--init", "--recursive", "--", path], check=True)
    actual = git(checkout, "rev-parse", "HEAD")
    if actual != revision:
        raise RuntimeError(f"PyroWave expected {revision}, found {actual}; inspect local work before updating the submodule")
    if git(checkout, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("PyroWave has modified or untracked content; keep the pinned build checkout pristine")
    for required in ["LICENSE", "metal/pyrowave_metal.h", "metal/shaders/pyrowave_msl.h"]:
        if not (checkout / required).is_file():
            raise RuntimeError(f"PyroWave is missing required source: {required}")
    print(f"{label} {revision[:12]}: pristine pinned Metal sources verified (bitstream {pin['bitstream']})")


def main():
    pins = json.loads((ROOT / "Dependencies/versions.json").read_text())
    for name in ("pyrowave", "decoder-pyrowave"):
        try:
            verify(pins[name], name)
        except (KeyError, RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
            raise RuntimeError(f"{name}: {error}") from error


if __name__ == "__main__":
    try:
        main()
    except (KeyError, RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"PyroWave verification failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)
