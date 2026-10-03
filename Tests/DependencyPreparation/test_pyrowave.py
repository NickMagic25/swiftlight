"""Verify immutable direct decoder inputs using disposable local Git submodules."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/verify-pyrowave.py"


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], stderr=subprocess.PIPE).decode().strip()


def commit(path):
    git(path, "add", ".")
    git(path, "-c", "user.name=Dependency Test", "-c", "user.email=test@example.invalid",
        "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", "Fixture")
    return git(path, "rev-parse", "HEAD")


class PyrowaveVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftlight-pyrowave-pin-test-")
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        self.upstream = base / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "--quiet")
        for name in ["LICENSE", "metal/pyrowave_metal.h", "metal/shaders/pyrowave_msl.h"]:
            source = self.upstream / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("Fixture source\n")
        self.revision = commit(self.upstream)
        self.root = base / "client"
        self.root.mkdir()
        git(self.root, "init", "--quiet")
        git(self.root, "-c", "protocol.file.allow=always", "submodule", "add", "--quiet",
            str(self.upstream), "Dependencies/pyrowave")
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
        self.lock = self.root / "Dependencies/versions.json"
        self.lock.write_text(json.dumps({"pyrowave": {
            "path": "Dependencies/pyrowave", "revision": self.revision,
            "url": str(self.upstream), "bitstream": "186f0393"
        }}))
        commit(self.root)
        self.checkout = self.root / "Dependencies/pyrowave"

    def verify(self, success=True):
        result = subprocess.run([sys.executable, str(self.root / "scripts" / SCRIPT.name)],
                                env=dict(os.environ, GIT_ALLOW_PROTOCOL="file"), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        return result

    def test_pristine_checkout_and_missing_initialization(self):
        self.assertIn("pristine pinned", self.verify().stdout)
        git(self.root, "submodule", "deinit", "--force", "--", "Dependencies/pyrowave")
        self.assertFalse((self.checkout / "LICENSE").exists())
        self.verify()
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.revision)
        self.assertEqual(git(self.checkout, "status", "--porcelain"), "")

    def test_gitlink_pin_mismatch_and_dirty_source_are_preserved(self):
        pin = json.loads(self.lock.read_text())
        pin["pyrowave"]["revision"] = "0" * 40
        self.lock.write_text(json.dumps(pin))
        self.assertIn("gitlink", self.verify(success=False).stderr)
        pin["pyrowave"]["revision"] = self.revision
        self.lock.write_text(json.dumps(pin))
        local = self.checkout / "LICENSE"
        local.write_text("Local work\n")
        self.assertIn("modified or untracked", self.verify(success=False).stderr)
        self.assertEqual(local.read_text(), "Local work\n")
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.revision)

    def test_wrong_checkout_and_source_url_are_rejected(self):
        (self.checkout / "LICENSE").write_text("New source\n")
        changed = commit(self.checkout)
        self.assertIn(f"found {changed}", self.verify(success=False).stderr)
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), changed)
        git(self.root, "config", "--file", ".gitmodules", "submodule.Dependencies/pyrowave.url", "wrong-source")
        self.assertIn("URL", self.verify(success=False).stderr)

    def test_untracked_source_is_not_accepted_as_pristine(self):
        (self.checkout / "metal/extra.h").write_text("Local header\n")
        self.assertIn("modified or untracked", self.verify(success=False).stderr)
        self.assertTrue((self.checkout / "metal/extra.h").exists())


if __name__ == "__main__":
    unittest.main()
