"""Fixture provenance identifies local source content without regenerating media."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/fixture_source.py"
SPEC = importlib.util.spec_from_file_location("fixture_source", SCRIPT)
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], stderr=subprocess.PIPE).decode().strip()


def commit(path):
    git(path, "add", ".")
    git(path, "-c", "user.name=Fixture Test", "-c", "user.email=test@example.invalid",
        "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", "Fixture")
    return git(path, "rev-parse", "HEAD")


class FixtureSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftlight-fixture-source-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        git(self.root, "init", "--quiet")
        (self.root / "LICENSE").write_text("Client source\n")
        self.revision = commit(self.root)
        self.decoder = self.root / "Packages/moonlight-apple-decoder"
        self.decoder.mkdir(parents=True)
        (self.decoder / ".gitignore").write_text("/build/\n__pycache__/\n")
        (self.decoder / "Package.swift").write_text("Decoder manifest\n")
        (self.decoder / "src").mkdir()
        self.source = self.decoder / "src/bitstream.cpp"
        self.source.write_text("Decoder source\n")

    def provenance(self):
        return SOURCE.decoder_provenance(self.decoder, self.decoder, "0" * 40)

    def test_monorepo_records_actual_untracked_sources_and_ignores_build_outputs(self):
        before = self.provenance()
        self.assertEqual(before["decoder_revision"], self.revision)
        self.assertEqual(before["decoder_source_path"], "Packages/moonlight-apple-decoder")
        build = self.decoder / "build"
        build.mkdir()
        (build / "mav-fixture").write_text("Generated binary\n")
        self.assertEqual(self.provenance(), before)
        self.source.write_text("Changed decoder source\n")
        after = self.provenance()
        self.assertNotEqual(after["decoder_source_sha256"], before["decoder_source_sha256"])
        self.assertEqual(after["decoder_revision"], before["decoder_revision"])
        commit(self.root)
        self.assertEqual(self.provenance()["decoder_source_sha256"], after["decoder_source_sha256"])

    def test_explicit_standalone_checkout_keeps_its_historical_revision_gate(self):
        with self.assertRaisesRegex(ValueError, "must be pinned"):
            SOURCE.decoder_provenance(self.root, self.decoder, "0" * 40)
        record = SOURCE.decoder_provenance(self.root, self.decoder, self.revision)
        self.assertEqual(record["decoder_revision"], self.revision)
        self.assertEqual(record["decoder_source_path"], ".")

    def test_submodule_contents_are_part_of_the_source_identity(self):
        upstream = self.root / "upstream"
        upstream.mkdir()
        git(upstream, "init", "--quiet")
        (upstream / "LICENSE").write_text("PyroWave source\n")
        commit(upstream)
        path = "Packages/moonlight-apple-decoder/Dependencies/pyrowave"
        git(self.root, "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", str(upstream), path)
        before = self.provenance()
        (self.root / path / "LICENSE").write_text("Changed PyroWave source\n")
        self.assertNotEqual(self.provenance()["decoder_source_sha256"], before["decoder_source_sha256"])
        git(self.root, "submodule", "deinit", "--force", "--", path)
        with self.assertRaisesRegex(ValueError, "Initialize decoder source submodule"):
            self.provenance()


if __name__ == "__main__":
    unittest.main()
