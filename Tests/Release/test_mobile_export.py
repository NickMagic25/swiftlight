import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MobileExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="swiftlight export ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "SwiftlightMobile.xcarchive"
        self.app = self.archive / "Products/Applications/SwiftlightMobile.app"
        self.app.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = self.bin / "xcodebuild"
        stub.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                        'open(os.environ["SWIFTLIGHT_TEST_ARGUMENTS"], "w").write(json.dumps(sys.argv[1:]))\n')
        stub.chmod(0o755)
        self.arguments = self.root / "arguments.json"
        self.env = os.environ | {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                                 "SWIFTLIGHT_TEST_ARGUMENTS": str(self.arguments)}

    def export(self, platform="iPhoneOS", family=(1, 2), identifier="net.edrisil.swiftlight.ios"):
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleSupportedPlatforms": [platform], "UIDeviceFamily": list(family),
            "CFBundleIdentifier": identifier}))
        return subprocess.run([str(ROOT / "scripts/export-mobile-adhoc.sh"), str(self.archive),
                               str(self.root / "export output")], env=self.env, text=True, capture_output=True)

    def test_exports_universal_device_archive_without_upload_or_device_registration(self):
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(self.arguments.read_text())
        self.assertEqual(arguments, ["-exportArchive", "-archivePath", str(self.archive),
                                    "-exportPath", str(self.root / "export output"), "-exportOptionsPlist",
                                    str(ROOT / "App/Mobile-AdHoc-ExportOptions.plist"), "-allowProvisioningUpdates"])
        options = plistlib.loads((ROOT / "App/Mobile-AdHoc-ExportOptions.plist").read_bytes())
        self.assertEqual(options["method"], "release-testing")
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["thinning"], "<none>")
        self.assertFalse(options["manageAppVersionAndBuildNumber"])

    def test_rejects_simulator_and_wrong_product_before_signing(self):
        for options in ({"platform": "iPhoneSimulator"}, {"family": (1,)},
                        {"identifier": "net.edrisil.swiftlight"}):
            with self.subTest(options=options):
                result = self.export(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.arguments.exists())


if __name__ == "__main__":
    unittest.main()
