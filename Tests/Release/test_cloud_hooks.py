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
                        CI_XCODE_SCHEME="Swiftlight", CI_PRODUCT_PLATFORM="macOS",
                        PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])

    def run_hook(self, hook, **environment):
        return subprocess.run(["/bin/sh", str(self.root / "ci_scripts" / hook)],
                              env=self.env | environment, text=True, capture_output=True)

    def plist(self, mobile=False):
        return plistlib.loads((self.root / "App" / ("Mobile-Info.plist" if mobile else "Info.plist")).read_bytes())

    def test_versions_only_the_action_platform(self):
        for platform, tag, mobile in (("macOS", "macos-v1.2.3", False),
                                      ("iOS", "ios-v2.3.4", True)):
            with self.subTest(platform=platform):
                unchanged = self.plist(not mobile)
                result = self.run_hook("ci_pre_xcodebuild.sh", CI_PRODUCT_PLATFORM=platform, CI_TAG=tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.plist(mobile)["CFBundleShortVersionString"], tag.split("v")[1])
                self.assertEqual(self.plist(mobile)["CFBundleVersion"], "42")
                self.assertEqual(self.plist(not mobile), unchanged)

    def test_branch_build_number_is_updated_for_each_platform(self):
        for platform, mobile in (("macOS", False), ("iOS", True)):
            unchanged = self.plist(not mobile)
            result = self.run_hook("ci_pre_xcodebuild.sh", CI_PRODUCT_PLATFORM=platform)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.plist(mobile), {"CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "42"})
            self.assertEqual(self.plist(not mobile), unchanged)

    def test_wrong_channel_or_malformed_tag_never_changes_either_product(self):
        for platform, tag in (("iOS", "macos-v1.2.3"), ("macOS", "ios-v1.2.3"),
                              ("iOS", "v1.2.3"), ("iOS", "ios-v01.2.3")):
            with self.subTest(platform=platform, tag=tag):
                result = self.run_hook("ci_pre_xcodebuild.sh", CI_PRODUCT_PLATFORM=platform, CI_TAG=tag)
                self.assertNotEqual(result.returncode, 0)
                for mobile in (False, True):
                    self.assertEqual(self.plist(mobile), {"CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "1"})

    def test_mobile_archive_prepares_only_device_dependencies(self):
        result = self.run_hook("ci_post_clone.sh", CI_PRODUCT_PLATFORM="iOS", CI_XCODEBUILD_ACTION="archive")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text().splitlines()
        self.assertEqual(calls[0], "bootstrap --platform ios")
        self.assertEqual(len(calls), 2)
        self.assertIn("--force-resolved-versions resolve", calls[1])

    def test_mobile_build_prepares_both_sdk_variants(self):
        for action in ("analyze", "build", "build-for-testing", "test-without-building"):
            with self.subTest(action=action):
                (self.root / "calls").unlink(missing_ok=True)
                result = self.run_hook("ci_post_clone.sh", CI_PRODUCT_PLATFORM="iOS", CI_XCODEBUILD_ACTION=action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.root / "calls").read_text().splitlines()[:2],
                                 ["bootstrap --platform ios", "bootstrap --platform ios-simulator"])

    def test_macos_and_shared_validation_are_retained(self):
        result = self.run_hook("ci_post_clone.sh", CI_PRODUCT_PLATFORM="macOS", CI_XCODEBUILD_ACTION="build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls").read_text().splitlines()[0], "bootstrap --platform macos")
        result = self.run_hook("ci_pre_xcodebuild.sh", CI_PRODUCT_PLATFORM="iOS", SWIFTLIGHT_RUN_VALIDATION="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validation", (self.root / "calls").read_text())

    def test_unknown_or_missing_platform_stops_before_work_or_version_changes(self):
        for platform in ("", "tvOS", "iPadOS", "watchOS"):
            for hook in ("ci_post_clone.sh", "ci_pre_xcodebuild.sh"):
                with self.subTest(platform=platform, hook=hook):
                    result = self.run_hook(hook, CI_PRODUCT_PLATFORM=platform)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Cloud action platform", result.stderr)
                    self.assertFalse((self.root / "calls").exists())
                    for mobile in (False, True):
                        self.assertEqual(self.plist(mobile)["CFBundleVersion"], "1")

    def test_removed_or_missing_scheme_stops_before_work_or_version_changes(self):
        for scheme in ("", "SwiftlightMobile"):
            for hook in ("ci_post_clone.sh", "ci_pre_xcodebuild.sh"):
                with self.subTest(scheme=scheme, hook=hook):
                    result = self.run_hook(hook, CI_XCODE_SCHEME=scheme)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Expected the Swiftlight Cloud scheme", result.stderr)
                    self.assertFalse((self.root / "calls").exists())
                    for mobile in (False, True):
                        self.assertEqual(self.plist(mobile)["CFBundleVersion"], "1")


if __name__ == "__main__":
    unittest.main()
