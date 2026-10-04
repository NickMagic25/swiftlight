import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release-version.py"
spec = importlib.util.spec_from_file_location("release_version", SCRIPT)
release_version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_version)


class ReleaseVersionTests(unittest.TestCase):
    def test_stable_semver(self):
        for tag in ("v0.0.1", "v0.1.0", "v1.0.0", "v12.34.56"):
            with self.subTest(tag=tag):
                self.assertEqual(release_version.version_from_tag(tag), tag[1:])

    def test_rejects_ambiguous_and_nonrelease_tags(self):
        for tag in ("0.0.1", "v1.2", "v01.2.3", "v1.02.3", "v1.2.03", "v1.2.3-rc.1",
                    "v1.2.3+build", "v1.2.3\n", "v1.2.3/other", "v1.2.3;echo bad", ""):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version.version_from_tag(tag)

    def test_updates_only_bundle_versions(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / "Info.plist"
            info = {"CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
                    "CFBundleIdentifier": "net.edrisil.swiftlight", "NSHighResolutionCapable": True}
            plist.write_bytes(plistlib.dumps(info))
            result = subprocess.run([sys.executable, str(SCRIPT), "v1.2.3", "--build-number", "42", "--plist", str(plist)],
                                    check=True, text=True, capture_output=True)
            self.assertEqual(result.stdout.strip(), "1.2.3")
            info.update(CFBundleShortVersionString="1.2.3", CFBundleVersion="42")
            self.assertEqual(plistlib.loads(plist.read_bytes()), info)

    def test_rejects_invalid_build_number(self):
        for value in ("0", "-1", "01", "1.2", ""):
            with self.subTest(value=value):
                result = subprocess.run([sys.executable, str(SCRIPT), "v0.0.1", "--build-number", value],
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_branch_build_retains_marketing_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / "Info.plist"
            info = {"CFBundleShortVersionString": "0.4.2", "CFBundleVersion": "1", "UIDeviceFamily": [1, 2]}
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run([sys.executable, str(SCRIPT), "--build-number", "103", "--plist", str(plist)],
                           check=True, capture_output=True)
            info["CFBundleVersion"] = "103"
            self.assertEqual(plistlib.loads(plist.read_bytes()), info)

    def test_tagged_and_branch_builds_store_full_commit_sha(self):
        for tag in ("v1.2.3", None):
            for commit_sha in ("A1" * 20, "B2" * 32):
                with self.subTest(tag=tag, commit_sha=commit_sha), tempfile.TemporaryDirectory() as temporary:
                    plist = Path(temporary) / "Info.plist"
                    info = {"CFBundleShortVersionString": "0.4.2", "CFBundleVersion": "1",
                            "CFBundleIdentifier": "net.edrisil.swiftlight"}
                    plist.write_bytes(plistlib.dumps(info))
                    command = [sys.executable, str(SCRIPT)]
                    if tag is not None:
                        command.append(tag)
                    command.extend(["--build-number", "103", "--commit-sha", commit_sha, "--plist", str(plist)])
                    subprocess.run(command, check=True, capture_output=True)
                    info.update(CFBundleShortVersionString="1.2.3" if tag else "0.4.2",
                                CFBundleVersion="103", GitCommitSHA=commit_sha.lower())
                    self.assertEqual(plistlib.loads(plist.read_bytes()), info)

    def test_omitted_commit_sha_removes_stale_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / "Info.plist"
            info = {"CFBundleShortVersionString": "0.4.2", "CFBundleVersion": "1",
                    "GitCommitSHA": "a1" * 20}
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run([sys.executable, str(SCRIPT), "--build-number", "103", "--plist", str(plist)],
                           check=True, capture_output=True)
            self.assertEqual(plistlib.loads(plist.read_bytes()),
                             {"CFBundleShortVersionString": "0.4.2", "CFBundleVersion": "103"})

    def test_commit_sha_requires_a_destination_plist(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "v1.2.3", "--commit-sha", "a1" * 20],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A plist is required", result.stderr)

    def test_invalid_commit_sha_does_not_mutate_plist(self):
        for tag in ("v1.2.3", None):
            for commit_sha in ("", "a1b2c3d", "a" * 39, "a" * 41, "a" * 63, "a" * 65,
                               "g" * 40, "a" * 40 + "\n", " " + "a" * 40):
                with self.subTest(tag=tag, commit_sha=commit_sha), tempfile.TemporaryDirectory() as temporary:
                    plist = Path(temporary) / "Info.plist"
                    original = plistlib.dumps({"CFBundleShortVersionString": "0.4.2", "CFBundleVersion": "1",
                                               "GitCommitSHA": "b2" * 20})
                    plist.write_bytes(original)
                    command = [sys.executable, str(SCRIPT)]
                    if tag is not None:
                        command.append(tag)
                    command.extend(["--build-number", "103", "--commit-sha", commit_sha, "--plist", str(plist)])
                    result = subprocess.run(command, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(plist.read_bytes(), original)

    def test_invalid_marketing_version_does_not_mutate_plist(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / "Info.plist"
            for version in (None, "", "1.0", "1.2.3-beta", 123):
                with self.subTest(version=version):
                    info = {"CFBundleVersion": "1"}
                    if version is not None:
                        info["CFBundleShortVersionString"] = version
                    original = plistlib.dumps(info)
                    plist.write_bytes(original)
                    result = subprocess.run([sys.executable, str(SCRIPT), "--build-number", "103", "--plist", str(plist)],
                                            capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(plist.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
