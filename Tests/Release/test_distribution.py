"""Failure-path tests with stub Apple tools; these do not claim real notarization."""
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['TEST_CALLS'], 'a') as out:
    out.write(json.dumps([name, args]) + '\n')
if name == 'lipo':
    print('arm64')
elif name == 'codesign':
    if os.environ.get('TEST_BAD_SIGNATURE'): sys.exit(23)
elif name == 'hdiutil' and args[0] == 'create':
    stage = Path(args[args.index('-srcfolder') + 1])
    assert (stage / 'Applications').is_symlink()
    assert os.readlink(stage / 'Applications') == '/Applications'
    assert (stage / 'Swiftlight.app/Contents/MacOS/Swiftlight').read_text() == 'fixture'
    assert (stage / 'Install.txt').is_file()
    Path(args[-1]).write_text('fixture dmg')
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        print(json.dumps({'id': 'fixture-id', 'status': os.environ.get('TEST_NOTARY_STATUS', 'Accepted')}))
        sys.exit(int(os.environ.get('TEST_NOTARY_EXIT', '0')))
    elif args[:2] == ['notarytool', 'log']:
        Path(args[-1]).write_text('{}')
'''


@unittest.skipUnless(sys.platform == "darwin", "Uses macOS ditto and PlistBuddy")
class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="swiftlight-distribution-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        for script in ("package-dmg.sh", "release-version.py", "notarize.sh"):
            shutil.copy2(ROOT / "scripts" / script, self.root / "scripts" / script)
        self.app = self.root / "Swiftlight.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/Swiftlight").write_text("fixture")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.0.1"}))
        self.bin = self.root / "tools"
        self.bin.mkdir()
        # Apple's /usr/bin/python3 launcher can consult xcrun, which this
        # harness replaces. Use the running interpreter for stubs and scripts
        # so tool discovery never recurses through the fake xcrun.
        (self.bin / "python3").symlink_to(sys.executable)
        (self.bin / "stub").write_text(STUB)
        (self.bin / "stub").chmod(0o755)
        for name in ("lipo", "codesign", "hdiutil", "xcrun"):
            (self.bin / name).symlink_to("stub")
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                        APP_PATH=str(self.app), OUTPUT_DIR=str(self.root / "output"),
                        SIGNING_IDENTITY="fixture-identity", RELEASE_TAG="v0.0.1",
                        SIGNING_KEYCHAIN_PATH=str(self.root / "keychain"),
                        TEST_CALLS=str(self.root / "calls.jsonl"), TMPDIR=str(self.root))

    def run_script(self, script, *args):
        command = ["/bin/bash", str(self.root / "scripts" / script), *map(str, args)]
        with subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                # Kill the whole fixture tool tree. A late notarytool stub must
                # never overwrite the next subtest's report after a timeout.
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise
            return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_dmg_contains_app_applications_link_and_instructions(self):
        result = self.run_script("package-dmg.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "output/Swiftlight-0.0.1-macos-arm64.dmg").is_file())
        self.assertFalse(list(self.root.glob("swiftlight-dmg.*")), "Temporary staging directory leaked")
        calls = self.calls()
        self.assertTrue(any(name == "codesign" and "--timestamp" in args for name, args in calls))
        self.assertEqual(calls[-1][0], "hdiutil")
        self.assertEqual(calls[-1][1][0], "verify")

    def test_wrong_app_version_never_creates_dmg(self):
        self.env["RELEASE_TAG"] = "v0.0.2"
        result = self.run_script("package-dmg.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertFalse(any(name == "hdiutil" for name, _ in self.calls()))

    def test_adhoc_identity_never_creates_dmg(self):
        self.env["SIGNING_IDENTITY"] = "-"
        self.assertNotEqual(self.run_script("package-dmg.sh").returncode, 0)
        self.assertFalse(any(name == "hdiutil" for name, _ in self.calls()))

    def test_invalid_signature_never_creates_dmg(self):
        self.env["TEST_BAD_SIGNATURE"] = "1"
        self.assertNotEqual(self.run_script("package-dmg.sh").returncode, 0)
        self.assertFalse(any(name == "hdiutil" for name, _ in self.calls()))

    def test_notarization_requires_accepted_status(self):
        for status, code, success in (("Accepted", "0", True), ("Invalid", "0", False),
                                      ("In Progress", "0", False), ("In Progress", "1", False)):
            with self.subTest(status=status, code=code):
                self.env.update(TEST_NOTARY_STATUS=status, TEST_NOTARY_EXIT=code)
                report = self.root / "notary/report.json"
                result = self.run_script("notarize.sh", self.root / "fixture.zip", report)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                self.assertTrue(report.with_name("report-log.json").is_file())


if __name__ == "__main__":
    unittest.main()
