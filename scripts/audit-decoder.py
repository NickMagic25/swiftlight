#!/usr/bin/env python3
"""Keep VideoToolbox in its package and direct PyroWave calls in the native bridge."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
forbidden = re.compile(r'VTDecompressionSession|AVSampleBufferDisplayLayer|AVPlayer\s*\(|avcodec_(?:send_packet|receive_frame|alloc_context|open)|import\s+(?:FFmpeg|libavcodec)')
pyrowave_native = re.compile(r'\b(?:swiftlight_)?pyrowave_\w+\s*\(|\b(?:Swiftlight)?PyroWave::|#\s*include\s*[<"]pyrowave_(?:metal|bitstream|common)\.')
failures = []
bridge = root / 'Sources/shared/CPyrowaveBridge'
for source in (root / 'Sources').rglob('*'):
    if source.suffix not in {'.swift', '.m', '.mm', '.c', '.cpp', '.h', '.hpp'} or 'vendor' in source.parts:
        continue
    for line, text in enumerate(source.read_text().splitlines(), 1):
        if forbidden.search(text):
            failures.append(f'{source.relative_to(root)}:{line}: forbidden decoder call: {text.strip()}')
        if pyrowave_native.search(text) and not source.is_relative_to(bridge):
            failures.append(f'{source.relative_to(root)}:{line}: native PyroWave access must remain in CPyrowaveBridge')
manifest = (root / 'Package.swift').read_text()
if 'MoonlightAppleVideo' not in manifest:
    failures.append('Required VideoToolbox package product missing')
if 'CPyrowaveBridge' not in manifest:
    failures.append('Required native PyroWave bridge target missing')
production = re.search(r'\.target\(name:\s*"CMetalPyrowave".*?sources:\s*\[([^]]*)\]', manifest, re.S)
if not production or set(re.findall(r'"([^"]+)"', production.group(1))) != {
        'pyrowave_common.mm', 'pyrowave_decoder.mm', 'pyrowave_bitstream.cpp'}:
    failures.append('CMetalPyrowave must compile only the three production decoder sources')
if 'PYROWAVE_METAL_BENCH_HOOKS' in manifest:
    failures.append('CLI-private PyroWave experiments must not be enabled in the app')
if failures:
    raise SystemExit('FAIL decoder ownership audit\n' + '\n'.join(failures))
print('PASS: VideoToolbox stays in MoonlightAppleVideo; direct production PyroWave access stays in CPyrowaveBridge.')
