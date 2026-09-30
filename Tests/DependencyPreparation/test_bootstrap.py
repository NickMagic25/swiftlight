"""Exercise SDK selection and cache isolation with stand-in native build tools.

Actual compiler/linker acceptance is provided by the Xcode mobile build gates.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/bootstrap-dependencies.sh"

# Keep filesystem publication real while replacing downloads and expensive compilers.
TOOL = r'''
import hashlib, json, os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["SWIFTLIGHT_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, args]) + "\n")
def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)
if name == "shasum" and "-c" not in args:
    path = Path(args[-1])
    print(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path))
elif name == "xcrun":
    if "--show-sdk-path" in args: print("/mock-sdk/" + args[1])
    elif "--show-sdk-version" in args: print(os.environ.get("SWIFTLIGHT_TEST_SDK", "26.5"))
    elif "--find" in args: print("/mock-clang")
    elif args[0] == "lipo":
        end = args.index("-output")
        write(Path(args[end + 1]), "".join(Path(p).read_text() for p in args[2:end]))
elif name == "tar":
    if args[0] == "-xOf": print("Mock license")
    else:
        destination = Path(args[args.index("-C") + 1])
        version = Path(args[1]).name.removesuffix(".tar.gz")
        path = destination / version
        path.mkdir(parents=True, exist_ok=True)
        if version.startswith("openssl"):
            (path / "Configure").symlink_to(root / "bin/Configure")
            write(path / "providers/stores.inc", (root / "stores.inc").read_text())
elif name == "Configure":
    prefix = next(a.removeprefix("--prefix=") for a in args if a.startswith("--prefix="))
    write(Path.cwd() / "prefix", prefix)
    write(Path.cwd() / "target", args[0])
elif name == "make" and args == ["install_sw"]:
    prefix = Path((Path.cwd() / "prefix").read_text())
    target = (Path.cwd() / "target").read_text()
    for library in ["crypto", "ssl"]: write(prefix / f"lib/lib{library}.a", target + "\n")
    write(prefix / "include/openssl/configuration.h", target)
    write(prefix / "include/openssl/opensslconf.h", "#include <openssl/configuration.h>\n")
elif name == "cmake":
    if "-S" in args:
        build = Path(args[args.index("-B") + 1])
        prefix = next(a.removeprefix("-DCMAKE_INSTALL_PREFIX=") for a in args if a.startswith("-DCMAKE_INSTALL_PREFIX="))
        write(build / "prefix", prefix)
    elif args[0] == "--install":
        prefix = Path((Path(args[1]) / "prefix").read_text())
        write(prefix / "lib/libopus.a", str(prefix) + "\n")
        write(prefix / "include/opus/opus.h", "Mock Opus header")
elif name == "curl":
    raise SystemExit("The bootstrap unexpectedly attempted a download")
'''


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="swiftlight-bootstrap-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/bootstrap-dependencies.sh")
        patches = self.root / "patches/openssl"
        patches.mkdir(parents=True)
        shutil.copyfile(SCRIPT.parents[1] / "patches/openssl/mobile-no-file-store.patch", patches / "mobile-no-file-store.patch")
        (self.root / "stores.inc").write_text(
            "#ifndef STORE\n# error Macro STORE undefined\n#endif\n\n"
            'STORE("file", "yes", ossl_file_store_functions)\n'
            '#ifndef OPENSSL_NO_WINSTORE\nSTORE("org.openssl.winstore", "yes", ossl_winstore_store_functions)\n#endif\n')
        (self.root / "bin").mkdir()
        for name in ["python3", "shasum", "xcrun", "tar", "Configure", "make", "cmake", "curl"]:
            path = self.root / "bin" / name
            path.write_text(f"#!{sys.executable}\n" + TOOL)
            path.chmod(0o755)
        sources = self.root / ".build/dependency-sources"
        sources.mkdir(parents=True)
        for name in ["opus-1.5.2.tar.gz", "openssl-3.6.4.tar.gz"]:
            (sources / name).touch()
        self.environment = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                                SWIFTLIGHT_TEST_ROOT=str(self.root))

    def bootstrap(self, *args, success=True):
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/bootstrap-dependencies.sh"), *args],
                                env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 2, result.stdout + result.stderr)
        return result

    def calls(self, name):
        return [args for tool, args in map(json.loads, (self.root / "calls.jsonl").read_text().splitlines())
                if tool == name]

    def test_invalid_selection_stops_before_dependency_preparation(self):
        self.assertIn("Unsupported", self.bootstrap("--platform", "watchos", success=False).stderr)
        self.assertFalse((self.root / "calls.jsonl").exists())
        self.assertIn("Usage", self.bootstrap("--platform", success=False).stderr)

    def test_clean_mobile_bootstrap_publishes_shared_licenses_without_macos_build(self):
        self.bootstrap("--platform", "ios")
        output = self.root / ".build/dependencies"
        self.assertFalse((output / "lib/libcrypto.a").exists())
        for name in ["OpenSSL.txt", "Opus.txt"]:
            shared = output / "licenses" / name
            self.assertEqual(shared.read_text(), "Mock license\n")
            self.assertEqual(shared.read_text(), (output / "ios/licenses" / name).read_text())
        # Notices are packaging inputs and must be restored even on a cache hit.
        shutil.rmtree(output / "licenses")
        self.bootstrap("--platform", "ios")
        self.assertEqual(len(self.calls("Configure")), 1)
        for name in ["OpenSSL.txt", "Opus.txt"]:
            self.assertEqual((output / "licenses" / name).read_text(), "Mock license\n")

    def test_device_and_simulator_archives_and_headers_stay_separate(self):
        self.bootstrap("--platform", "ios")
        self.bootstrap("--platform", "ios-simulator")
        output = self.root / ".build/dependencies"
        device = (output / "ios/lib/libcrypto.a").read_text()
        simulator = (output / "ios-simulator/lib/libcrypto.a").read_text()
        self.assertEqual(device, "ios64-xcrun\n")
        self.assertEqual(simulator, "iossimulator-arm64-xcrun\niossimulator-x86_64-xcrun\n")
        self.assertFalse((output / "lib/libcrypto.a").exists())
        for family in ["ios-arm64", "ios-simulator-arm64", "ios-simulator-x86_64"]:
            self.assertTrue((output / f"mobile/include/openssl/configuration-{family}.h").is_file())
        self.assertIn("TARGET_OS_SIMULATOR", (output / "mobile/include/openssl/configuration.h").read_text())
        self.assertEqual(len(self.calls("Configure")), 3)
        for args in self.calls("Configure"):
            for option in ["no-shared", "no-stdio", "no-posix-io", "no-ui-console", "no-autoload-config", "no-module", "--with-rand-seed=getrandom"]:
                self.assertIn(option, args)

    def test_mobile_patch_changes_cache_without_patching_macos_source(self):
        self.bootstrap()
        sources = self.root / ".build/dependency-sources"
        original = (self.root / "stores.inc").read_text()
        self.assertEqual((sources / "openssl-3.6.4/providers/stores.inc").read_text(), original)
        self.bootstrap("--platform", "ios")
        mobile = sources / "ios-arm64/openssl-3.6.4/providers/stores.inc"
        self.assertNotIn('STORE("file",', mobile.read_text())
        self.assertEqual((sources / "openssl-3.6.4/providers/stores.inc").read_text(), original)
        self.assertEqual(len(self.calls("Configure")), 2)
        patch = self.root / "patches/openssl/mobile-no-file-store.patch"
        patch.write_text(patch.read_text() + "\n")
        self.bootstrap("--platform", "ios")
        self.assertEqual(len(self.calls("Configure")), 3)
        self.assertNotIn('STORE("file",', mobile.read_text())
        self.assertEqual((sources / "openssl-3.6.4/providers/stores.inc").read_text(), original)

    def test_mobile_patch_mismatch_stops_before_publishing_a_completed_slice(self):
        patch = self.root / "patches/openssl/mobile-no-file-store.patch"
        patch.write_text(patch.read_text().replace('STORE("file",', 'STORE("unexpected",'))
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/bootstrap-dependencies.sh"),
                                 "--platform", "ios"], env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch does not apply", result.stderr)
        self.assertEqual(self.calls("Configure"), [])
        self.assertFalse((self.root / ".build/dependencies/ios-arm64/.swiftlight-native-version").exists())
        self.assertFalse((self.root / ".build/dependencies/ios/lib/libcrypto.a").exists())

    def test_sdk_change_or_missing_crypto_invalidates_only_selected_slice(self):
        self.bootstrap("--platform", "ios")
        self.bootstrap("--platform", "ios")
        self.assertEqual(len(self.calls("Configure")), 1)
        self.environment["SWIFTLIGHT_TEST_SDK"] = "27.0"
        self.bootstrap("--platform", "ios")
        self.assertEqual(len(self.calls("Configure")), 2)
        (self.root / ".build/dependencies/ios-arm64/lib/libcrypto.a").unlink()
        self.bootstrap("--platform", "ios")
        self.assertEqual(len(self.calls("Configure")), 3)


if __name__ == "__main__":
    unittest.main()
