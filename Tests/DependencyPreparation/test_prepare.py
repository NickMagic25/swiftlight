"""Exercise real Git archives/patches in isolated repositories; no network access."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/prepare-common-c.py"


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], stderr=subprocess.PIPE).decode().strip()


def repository(path, content):
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "--quiet")
    (path / "value.txt").write_text(content)
    git(path, "add", "value.txt")
    git(path, "-c", "user.name=Dependency Test", "-c", "user.email=test@example.invalid",
        "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", "Fixture")
    return git(path, "rev-parse", "HEAD")


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="swiftlight-dependency-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        repository(self.root, "parent must remain unchanged\n")
        self.upstream = self.root / "Dependencies/moonlight-common-c"
        revision = repository(self.upstream, "before\n")
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/prepare-common-c.py")
        self.lock = self.root / "Dependencies/versions.json"
        self.lock.write_text(json.dumps({"moonlight-common-c": {
            "path": "Dependencies/moonlight-common-c", "revision": revision, "submodules": {}
        }}))
        self.patches = self.root / "patches/moonlight-common-c"
        self.patches.mkdir(parents=True)
        (self.patches / "series").write_text("fix.patch\n")
        (self.patches / "fix.patch").write_text(
            "diff --git a/value.txt b/value.txt\n--- a/value.txt\n+++ b/value.txt\n"
            "@@ -1 +1 @@\n-before\n+after\n")
        self.output = self.root / "Sources/shared/CStreamBridge/vendor/common-c"

    def prepare(self, success=True):
        result = subprocess.run([sys.executable, str(self.root / "scripts/prepare-common-c.py")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        return result

    def test_patch_isolation_and_idempotent_verified_output(self):
        self.prepare()
        self.assertEqual((self.output / "value.txt").read_text(), "after\n")
        self.assertEqual((self.upstream / "value.txt").read_text(), "before\n")
        self.assertEqual((self.root / "value.txt").read_text(), "parent must remain unchanged\n")
        self.assertEqual({path.name for path in (self.root / "Sources").iterdir()}, {"shared"},
                         "Preparation must not recreate a legacy top-level module directory")
        self.assertEqual(git(self.upstream, "status", "--porcelain"), "")
        mtime = (self.output / "value.txt").stat().st_mtime_ns
        self.prepare()
        self.assertEqual((self.output / "value.txt").stat().st_mtime_ns, mtime)
        # A tampered generated file is regenerated from committed input, never trusted by a stale stamp.
        (self.output / "value.txt").write_text("tampered\n")
        self.prepare()
        self.assertEqual((self.output / "value.txt").read_text(), "after\n")

    def test_wrong_pin_and_dirty_source_fail_without_resetting_checkout(self):
        lock = json.loads(self.lock.read_text())
        lock["moonlight-common-c"]["revision"] = "0" * 40
        self.lock.write_text(json.dumps(lock))
        self.assertIn("expected", self.prepare(success=False).stderr)
        lock["moonlight-common-c"]["revision"] = git(self.upstream, "rev-parse", "HEAD")
        self.lock.write_text(json.dumps(lock))
        (self.upstream / "value.txt").write_text("local work\n")
        self.assertIn("modified tracked content", self.prepare(success=False).stderr)
        self.assertEqual((self.upstream / "value.txt").read_text(), "local work\n")
        self.assertFalse(self.output.exists())

    def test_failed_or_unlisted_patch_preserves_previous_output(self):
        self.prepare()
        before = (self.output / ".swiftlight-source.json").read_bytes()
        patch = self.patches / "fix.patch"
        patch.write_text(patch.read_text().replace("-before", "-wrong-context"))
        self.prepare(success=False)
        self.assertEqual((self.output / "value.txt").read_text(), "after\n")
        self.assertEqual((self.output / ".swiftlight-source.json").read_bytes(), before)
        (self.patches / "unlisted.patch").write_text("unreviewed")
        self.assertIn("exactly once", self.prepare(success=False).stderr)


if __name__ == "__main__":
    unittest.main()
