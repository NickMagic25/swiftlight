#!/usr/bin/env python3
"""Compile only AppArtworkStore plus deterministic in-memory tests; no SwiftPM/UI/host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=root / '.build/debug',
                        help='Existing SwiftPM debug object/module directory')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    source = root / 'Sources/SwiftlightApp/AppArtworkStore.swift'
    objects = sorted((build / 'SwiftlightHost.build').glob('*.swift.o'))
    objects += sorted((build / 'CHostCrypto.build').glob('*.c.o'))
    description = build / 'description.json'
    if not objects or not description.is_file():
        parser.error('Build Swiftlight first, or select its existing debug object directory')
    commands = json.loads(description.read_text())['swiftCommands']
    arguments = next(value['otherArguments'] for key, value in commands.items() if key.startswith('C.SwiftlightHost-'))
    modulemap = Path(next(arg.split('=', 1)[1] for arg in arguments if arg.startswith('-fmodule-map-file=')))
    target = arguments[arguments.index('-target') + 1]
    swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='swiftlight-artwork-store-') as temporary:
        directory = Path(temporary)
        combined = directory / 'ArtworkStoreHarness.swift'
        combined.write_text(source.read_text() + '\n' + (root / 'scripts/artwork-store-harness.swift').read_text())
        executable = directory / 'artwork-store'
        command = [swiftc, '-swift-version', '6', '-parse-as-library', '-target', target, '-sdk', sdk,
                   '-module-cache-path', str(directory / 'module-cache'), '-I', str(build / 'Modules'),
                   '-Xcc', f'-fmodule-map-file={modulemap}', str(combined), *map(str, objects),
                   str(root / '.build/dependencies/lib/libcrypto.a'), '-o', str(executable)]
        for framework in ['AppKit', 'Combine', 'CoreGraphics', 'ImageIO', 'UniformTypeIdentifiers', 'Network', 'Security', 'CryptoKit']:
            command += ['-framework', framework]
        subprocess.run(command, check=True, timeout=120)
        environment = os.environ.copy()
        environment['SWIFTLIGHT_ARTWORK_SOURCE_SHA256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        return subprocess.run([str(executable)], env=environment, timeout=30).returncode


if __name__ == '__main__':
    raise SystemExit(main())
