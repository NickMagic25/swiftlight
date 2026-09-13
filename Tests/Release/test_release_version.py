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


if __name__ == "__main__":
    unittest.main()
