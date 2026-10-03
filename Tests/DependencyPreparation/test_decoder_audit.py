"""Ensure direct PyroWave authorization keeps the decoder ownership boundary narrow."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/audit-decoder.py"
MANIFEST = '''MoonlightAppleVideo CPyrowaveBridge
.target(name: "CMetalPyrowave", sources: ["pyrowave_common.mm", "pyrowave_decoder.mm", "pyrowave_bitstream.cpp"])
'''


class DecoderAuditTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftlight-decoder-audit-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/audit-decoder.py")
        (self.root / "Package.swift").write_text(MANIFEST)
        self.bridge = self.root / "Sources/shared/CPyrowaveBridge/SPyrowave.mm"
        self.bridge.parent.mkdir(parents=True)
        self.bridge.write_text('#include "pyrowave_metal.h"\npyrowave_decoder_create(info, output);\n')

    def audit(self, success=True):
        result = subprocess.run([sys.executable, str(self.root / "scripts/audit-decoder.py")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        return result

    def test_authorized_native_bridge_and_rejected_external_calls(self):
        self.audit()
        external = self.root / "Sources/shared/Other.mm"
        for value in ['pyrowave_decoder_create(info, out);', 'swiftlight_pyrowave_decoder_create(info, out);', 'PyroWave::BlockLayout layout;']:
            external.write_text(value)
            self.assertIn("must remain in CPyrowaveBridge", self.audit(success=False).stderr)

    def test_bridge_does_not_allow_another_videotoolbox_session(self):
        self.bridge.write_text('VTDecompressionSessionCreate();')
        self.assertIn("forbidden decoder call", self.audit(success=False).stderr)

    def test_encoder_and_experiments_cannot_enter_production_target(self):
        manifest = self.root / "Package.swift"
        manifest.write_text(MANIFEST.replace('pyrowave_decoder.mm', 'pyrowave_encoder.mm'))
        self.assertIn("three production", self.audit(success=False).stderr)
        manifest.write_text(MANIFEST + 'PYROWAVE_METAL_BENCH_HOOKS')
        self.assertIn("CLI-private", self.audit(success=False).stderr)


if __name__ == "__main__":
    unittest.main()
