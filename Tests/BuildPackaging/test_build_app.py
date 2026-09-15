#!/usr/bin/env python3
"""Exercise packaging with fake tools and real temporary-directory replacement."""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parents[2] / "scripts/build-app.sh"
VERSION_SCRIPT = SOURCE.with_name("release-version.py")
A, B = "A" * 40, "B" * 40
ONE = f'  1) {A} "Apple Development: Fixture (TEAM)"\n     1 valid identities found\n'
TWO = ONE + f'  2) {B} "Developer ID Application: Fixture (TEAM)"\n'
STUB = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
root = Path(os.environ['STUB_ROOT'])
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps([name, args]) + '\\n')
if name == 'security':
    print(os.environ.get('STUB_IDENTITIES', '     0 valid identities found'))
    sys.exit(int(os.environ.get('STUB_SECURITY_EXIT', '0')))
if name == 'swift':
    if '--show-bin-path' in args: print(root / 'bin')
    sys.exit(0)
phase = ('verify' if '--verify' in args else 'sign') if name == 'codesign' else name
if os.environ.get('STUB_FAIL_AT') == phase: sys.exit(23)
if name == 'otool':
    print('/opt/homebrew/lib/bad.dylib' if os.environ.get('STUB_HOMEBREW') else '/usr/lib/libSystem.B.dylib')
'''
CASES = [
    ("none", {}, True, "-"),
    ("one", {"STUB_IDENTITIES": ONE}, True, A),
    ("developer_id", {"STUB_IDENTITIES": f'  1) {B} "Developer ID Application: Fixture (TEAM)"'}, True, B),
    ("duplicate", {"STUB_IDENTITIES": ONE + ONE}, True, A),
    ("multiple", {"STUB_IDENTITIES": TWO}, False, None),
    ("explicit_dash", {"STUB_IDENTITIES": TWO, "SIGNING_IDENTITY": "-"}, True, "-"),
    ("explicit_name", {"STUB_SECURITY_EXIT": "7", "SIGNING_IDENTITY": "Apple Development: Chosen (TEAM)"}, True, "Apple Development: Chosen (TEAM)"),
    ("empty", {"SIGNING_IDENTITY": ""}, False, None),
    ("release_unset", {"CONFIGURATION": "release", "STUB_IDENTITIES": ONE}, False, None),
    ("release_dash", {"CONFIGURATION": "release", "SIGNING_IDENTITY": "-"}, False, None),
    ("release_real", {"CONFIGURATION": "release", "SIGNING_IDENTITY": A}, True, A),
    ("release_version", {"CONFIGURATION": "release", "SIGNING_IDENTITY": A, "RELEASE_TAG": "v0.0.1", "BUILD_NUMBER": "42"}, True, A),
    ("release_invalid_version", {"CONFIGURATION": "release", "SIGNING_IDENTITY": A, "RELEASE_TAG": "v01.0.0"}, False, None),
    ("lookup_failure", {"STUB_SECURITY_EXIT": "7"}, False, None),
    ("sign_failure", {"STUB_FAIL_AT": "sign", "SIGNING_IDENTITY": "-"}, False, None),
    ("verify_failure", {"STUB_FAIL_AT": "verify", "SIGNING_IDENTITY": "-"}, False, None),
    ("plist_failure", {"STUB_FAIL_AT": "plutil", "SIGNING_IDENTITY": "-"}, False, None),
    ("homebrew", {"STUB_HOMEBREW": "1", "SIGNING_IDENTITY": "-"}, False, None),
    ("invalid_configuration", {"CONFIGURATION": "invalid"}, False, None),
    ("first_install", {"SIGNING_IDENTITY": "-"}, True, "-"),
    ("symlink_destination", {"SIGNING_IDENTITY": "-"}, False, None),
]


def require(condition, message):
    # Checks remain active when Python runs with -O.
    if not condition:
        raise AssertionError(message)


def run_case(root, source, case):
    name, extra, success, identity = case
    (root / "scripts").mkdir(parents=True)
    (root / "scripts/build-app.sh").write_bytes(source)
    (root / "scripts/release-version.py").write_bytes(VERSION_SCRIPT.read_bytes())
    bootstrap = root / "scripts/bootstrap-dependencies.sh"
    bootstrap.write_text("#!/bin/bash\nexit 0\n")
    bootstrap.chmod(0o755)
    for relative in ["App/Info.plist", "LICENSE", ".build/dependencies/licenses/native.txt",
                     "Sources/shared/CStreamBridge/vendor/common-c/LICENSE.txt",
                     ".build/checkouts/moonlight-apple-decoder/LICENSE", "bin/swiftlight-desktop"]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("new-fake-binary" if relative == "bin/swiftlight-desktop" else "fixture")
    # A cached product from the old name must never enter the packaged app.
    (root / "bin/Swiftlight").write_text("stale-legacy-binary")
    with (root / "App/Info.plist").open("wb") as destination:
        plistlib.dump({"CFBundleIdentifier": "net.edrisil.swiftlight", "CFBundleExecutable": "Swiftlight",
                       "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1"}, destination)
    tools = root / "stub-bin"
    tools.mkdir()
    (tools / "tool").write_text(STUB)
    (tools / "tool").chmod(0o755)
    for command in ["security", "swift", "codesign", "plutil", "otool"]:
        (tools / command).symlink_to("tool")
    app = root / ".build/Swiftlight.app"
    with ExitStack() as cleanup:
        old, original_inode = None, None
        if name != "first_install":
            actual = root / "old-target" if name == "symlink_destination" else app
            binary = actual / "Contents/MacOS/Swiftlight"
            binary.parent.mkdir(parents=True)
            binary.write_text("old-fake-binary")
            if name == "symlink_destination":
                app.symlink_to(actual, target_is_directory=True)
            old = cleanup.enter_context(binary.open("rb"))
            original_inode = os.fstat(old.fileno()).st_ino
        env = {key: value for key, value in os.environ.items()
               if key not in {"SIGNING_IDENTITY", "CONFIGURATION", "SWIFTLIGHT_DECODER_PATH", "RELEASE_TAG", "BUILD_NUMBER"}
               and not key.startswith("STUB_")}
        env.update(extra)
        env.update(STUB_ROOT=str(root), PATH=str(tools) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        result = subprocess.run(["/bin/bash", str(root / "scripts/build-app.sh")], env=env,
                                capture_output=True, text=True, timeout=30)
        require((result.returncode == 0) == success, f"Unexpected exit {result.returncode}: {result.stderr}")
        calls_file = root / "calls.jsonl"
        calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
        binary = app / "Contents/MacOS/Swiftlight"
        if success:
            require(binary.read_text() == "new-fake-binary", "New bundle was not installed")
            builds = [args for command, args in calls if command == "swift" and "--product" in args]
            require(len(builds) == 1 and builds[0][builds[0].index("--product") + 1] == "swiftlight-desktop",
                    "The packager must build the distinct SwiftPM executable product")
            with (app / "Contents/Info.plist").open("rb") as source_plist:
                info = plistlib.load(source_plist)
            require(info["CFBundleExecutable"] == "Swiftlight", "Packaged executable identity changed")
            sign = [args for command, args in calls if command == "codesign" and "--sign" in args][0]
            require(sign[sign.index("--sign") + 1] == identity, "Wrong signing identity")
            require("/.Swiftlight-stage." in sign[-1], "Signing did not target the staged bundle")
            if extra.get("CONFIGURATION") == "release":
                require("--timestamp" in sign and "--options" in sign and sign[sign.index("--options") + 1] == "runtime",
                        "Release signature lacks hardened runtime or secure timestamp")
            else:
                require("--timestamp" not in sign and "--options" not in sign, "Debug signing changed")
            if "RELEASE_TAG" in extra:
                with (app / "Contents/Info.plist").open("rb") as source_plist:
                    info = plistlib.load(source_plist)
                require(info["CFBundleShortVersionString"] == "0.0.1" and info["CFBundleVersion"] == "42",
                        "Release version was not embedded before signing")
            if original_inode:
                require(binary.stat().st_ino != original_inode, "Installed executable inode was overwritten")
        else:
            require(binary.read_text() == "old-fake-binary", "Failure changed the old bundle")
        if old:
            require(old.read() == b"old-fake-binary", "Open old executable contents changed")
        require(not list((root / ".build").glob(".Swiftlight-stage.*")), "Staging was not cleaned")
        if "SIGNING_IDENTITY" in extra:
            require(not any(command == "security" for command, _ in calls), "Explicit identity performed automatic lookup")
        if success and identity == "-":
            require("Keychain" in result.stderr, "Ad-hoc build did not explain Keychain rebuild prompts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Also write the JSON report to this path")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("These packaging fixtures require the macOS atomic directory-exchange API")
    source, results = SOURCE.read_bytes(), []
    with tempfile.TemporaryDirectory(prefix="swiftlight-signing-stub-") as temporary:
        root = Path(temporary)
        for case in CASES:
            try:
                run_case(root / case[0], source, case)
                results.append({"case": case[0], "status": "PASS"})
            except Exception as error:
                results.append({"case": case[0], "status": "FAIL", "error": str(error)})
    passed = all(case["status"] == "PASS" for case in results)
    report = {
        "status": "PASS" if passed else "FAIL",
        "scope": "Temporary fixture trees; stubbed bootstrap/compiler/security/codesign/plutil/otool. Real filesystem atomic swap only; no real build, identity enumeration, signing, or private-key access.",
        "source": "scripts/build-app.sh",
        "sourceSHA256": hashlib.sha256(source).hexdigest(),
        "temporaryDirectoriesCleaned": True,
        "cases": results,
        "count": len(results),
    }
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
