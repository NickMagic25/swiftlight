#!/usr/bin/env python3
"""Reject alternate video implementations in client-owned application sources."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
patterns = re.compile(r'VTDecompressionSession|AVSampleBufferDisplayLayer|AVPlayer\s*\(|avcodec_(?:send_packet|receive_frame|alloc_context|open)|import\s+(?:FFmpeg|libavcodec)')
failures = []
for source in (root / 'Sources').rglob('*'):
    if source.suffix not in {'.swift', '.m', '.mm', '.c', '.cpp', '.h'} or 'vendor' in source.parts:
        continue
    for line, text in enumerate(source.read_text().splitlines(), 1):
        if patterns.search(text): failures.append(f'{source.relative_to(root)}:{line}: {text.strip()}')
manifest = (root / 'Package.swift').read_text()
if 'MoonlightAppleVideo' not in manifest: failures.append('Required package product missing')
if failures:
    raise SystemExit('FAIL alternate decoder audit\n' + '\n'.join(failures))
print('PASS: no alternate video decoder call sites in client-owned source; MoonlightAppleVideo dependency present.')
