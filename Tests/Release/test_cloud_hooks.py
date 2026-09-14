import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CloudHookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("ci_scripts", "scripts", "App", "bin"):
            (self.root / directory).mkdir()
        for name in ("ci_post_clone.sh", "ci_pre_xcodebuild.sh"):
            shutil.copy2(ROOT / "ci_scripts" / name, self.root / "ci_scripts" / name)
        shutil.copy2(ROOT / "scripts/release-version.py", self.root / "scripts/release-version.py")
        for name in ("Info.plist", "Mobile-Info.plist"):
            (self.root / "App" / name).write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "1"}))
        for path, label in (("scripts/bootstrap-dependencies.sh", "bootstrap"),
                            ("scripts/validate-ci.sh", "validation"),
                            ("bin/swift", "swift"), ("bin/cmake", "cmake")):
            stub = self.root / path
            stub.write_text(f'#!/bin/sh\nprintf "%s\\n" "{label} $*" >> "$CI_PRIMARY_REPOSITORY_PATH/calls"\n')
            stub.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("CI_", "SWIFTLIGHT_"))}
        self.env.update(CI_PRIMARY_REPOSITORY_PATH=str(self.root), CI_BUILD_NUMBER="42",
                        PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])

    def run_hook(self, hook, **environment):
        return subprocess.run(["/bin/sh", str(self.root / "ci_scripts" / hook)],
                              env=self.env | environment, text=True, capture_output=True)

    def plist(self, mobile=False):
        return plistlib.loads((self.root / "App" / ("Mobile-Info.plist" if mobile else "Info.plist")).read_bytes())

    def test_versions_only_the_action_product(self):
        for scheme, tag, mobile in (("Swiftlight", "macos-v1.2.3", False),
                                    ("SwiftlightMobile", "ios-v2.3.4", True)):
            with self.subTest(scheme=scheme):
                result = self.run_hook("ci_pre_xcodebuild.sh", CI_XCODE_SCHEME=scheme, CI_TAG=tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.plist(mobile)["CFBundleShortVersionString"], tag.split("v")[1])
                self.assertEqual(self.plist(mobile)["CFBundleVersion"], "42")

    def test_branch_build_number_is_updated_for_each_product(self):
        for scheme, mobile in (("Swiftlight", False), ("SwiftlightMobile", True)):
            result = self.run_hook("ci_pre_xcodebuild.sh", CI_XCODE_SCHEME=scheme)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.plist(mobile), {"CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "42"})

    def test_wrong_channel_or_malformed_tag_never_changes_either_product(self):
        for scheme, tag in (("SwiftlightMobile", "macos-v1.2.3"), ("Swiftlight", "ios-v1.2.3"),
                            ("SwiftlightMobile", "v1.2.3"), ("SwiftlightMobile", "ios-v01.2.3")):
            with self.subTest(scheme=scheme, tag=tag):
                result = self.run_hook("ci_pre_xcodebuild.sh", CI_XCODE_SCHEME=scheme, CI_TAG=tag)
                self.assertNotEqual(result.returncode, 0)
                for mobile in (False, True):
                    self.assertEqual(self.plist(mobile), {"CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "1"})

    def test_mobile_archive_prepares_only_device_dependencies(self):
        result = self.run_hook("ci_post_clone.sh", CI_XCODE_SCHEME="SwiftlightMobile", CI_XCODEBUILD_ACTION="archive")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text().splitlines()
        self.assertEqual(calls[0], "bootstrap --platform ios")
        self.assertEqual(len(calls), 2)
        self.assertIn("--force-resolved-versions resolve", calls[1])

    def test_mobile_build_prepares_both_sdk_variants(self):
        result = self.run_hook("ci_post_clone.sh", CI_XCODE_SCHEME="SwiftlightMobile", CI_XCODEBUILD_ACTION="build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls").read_text().splitlines()[:2],
                         ["bootstrap --platform ios", "bootstrap --platform ios-simulator"])

    def test_macos_and_shared_validation_are_retained(self):
        result = self.run_hook("ci_post_clone.sh", CI_XCODE_SCHEME="Swiftlight", CI_XCODEBUILD_ACTION="build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls").read_text().splitlines()[0], "bootstrap --platform macos")
        result = self.run_hook("ci_pre_xcodebuild.sh", CI_XCODE_SCHEME="SwiftlightMobile", SWIFTLIGHT_RUN_VALIDATION="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validation", (self.root / "calls").read_text())


if __name__ == "__main__":
    unittest.main()
