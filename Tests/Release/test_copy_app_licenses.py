import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LICENSE_INPUTS = {
    "Swiftlight.txt": "LICENSE",
    "OpenSSL.txt": ".build/dependencies/licenses/OpenSSL.txt",
    "Opus.txt": ".build/dependencies/licenses/Opus.txt",
    "MoonlightAppleVideo.txt": "Packages/moonlight-apple-decoder/LICENSE",
    "PyroWave.txt": "Dependencies/pyrowave/LICENSE",
    "moonlight-common-c.txt": "Sources/shared/CStreamBridge/vendor/common-c/LICENSE.txt",
    "enet.txt": "Sources/shared/CStreamBridge/vendor/common-c/enet/LICENSE",
    "nanors.txt": "Sources/shared/CStreamBridge/vendor/common-c/nanors/LICENSE",
}


class CopyAppLicensesTests(unittest.TestCase):
    def test_local_decoder_notice_is_used_despite_legacy_paths(self):
        for route in ("override", "xcode"):
            with self.subTest(route=route), tempfile.TemporaryDirectory(prefix="swiftlight licenses ") as temporary:
                root = Path(temporary)
                script = root / "scripts/copy-app-licenses.sh"
                script.parent.mkdir()
                shutil.copy2(ROOT / "scripts/copy-app-licenses.sh", script)
                for name, relative in LICENSE_INPUTS.items():
                    source = root / relative
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_text(f"Original {name}\n")
                environment = {key: value for key, value in os.environ.items()
                               if key not in ("SWIFTLIGHT_DECODER_PATH", "BUILD_DIR")}
                if route == "override":
                    decoder = root / "local decoder"
                    environment["SWIFTLIGHT_DECODER_PATH"] = str(decoder)
                else:
                    build_directory = root / "Derived Data/Build/Products"
                    build_directory.mkdir(parents=True)
                    decoder = root / "Derived Data/SourcePackages/checkouts/moonlight-apple-decoder"
                    environment["BUILD_DIR"] = str(build_directory)
                decoder.mkdir(parents=True)
                (decoder / "LICENSE").write_text("Stale decoder notice\n")
                notice = root / "Dependencies/pyrowave/LICENSE"
                notice.write_text("Submodule notice\n")
                output = root / "App Licenses"
                result = subprocess.run([str(script), str(output)], env=environment,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((output / "PyroWave.txt").read_bytes(), notice.read_bytes())
                self.assertEqual((output / "MoonlightAppleVideo.txt").read_text(), "Original MoonlightAppleVideo.txt\n")
                local_decoder = root / LICENSE_INPUTS["MoonlightAppleVideo.txt"]
                local_decoder.unlink()
                result = subprocess.run([str(script), str(output)], env=environment,
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                local_decoder.write_text("Restored decoder notice\n")
                notice.unlink()
                result = subprocess.run([str(script), str(output)], env=environment,
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_repeated_copy_replaces_readonly_outputs_without_changing_sources(self):
        with tempfile.TemporaryDirectory(prefix="swiftlight licenses ") as temporary:
            root = Path(temporary)
            script = root / "scripts/copy-app-licenses.sh"
            script.parent.mkdir()
            shutil.copy2(ROOT / "scripts/copy-app-licenses.sh", script)
            sources = {name: root / path for name, path in LICENSE_INPUTS.items()}
            for name, source in sources.items():
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(f"Original {name}\n")
                source.chmod(0o444)
            output = root / "Build Products/Swiftlight.app/Licenses"
            environment = {key: value for key, value in os.environ.items()
                           if key not in ("SWIFTLIGHT_DECODER_PATH", "BUILD_DIR")}

            def copy_and_check():
                result = subprocess.run([str(script), str(output)], env=environment,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual({path.name for path in output.iterdir()}, set(sources))
                for name, source in sources.items():
                    self.assertEqual((output / name).read_bytes(), source.read_bytes())
                    self.assertEqual(stat.S_IMODE((output / name).stat().st_mode), 0o644)
                    self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o444)

            copy_and_check()
            for name, source in sources.items():
                # Reproduce an existing bundle created by the former cp phase.
                (output / name).chmod(0o444)
                source.chmod(0o644)
                source.write_text(f"Updated {name}\n")
                source.chmod(0o444)
            copy_and_check()
            copy_and_check()


if __name__ == "__main__":
    unittest.main()
