#!/usr/bin/env python3
"""Reproduce bounded GPLv3 profile probes from committed Moonlight Qt.

Run with the path to a Moonlight Qt checkout. Only the pinned committed source is
read; its working-tree contents do not influence the generated header.
"""
import hashlib
from pathlib import Path
import re
import subprocess
import sys

REVISION = "da0244c5387cab3ccd682d8de24085720d6f6501"
SOURCE = "app/streaming/video/ffmpeg_videosamples.cpp"
SAMPLES = {
    "hevc_main8_420": "HEVCMainTestFrame",
    "hevc_main10_420": "HEVCMain10TestFrame",
    "hevc_rext8_444": "HEVCRExt8_444TestFrame",
    "hevc_rext10_444": "HEVCRExt10_444TestFrame",
    "av1_main8_420": "AV1Main8TestFrame",
    "av1_main10_420": "AV1Main10TestFrame",
    "av1_high8_444": "AV1High8_444TestFrame",
    "av1_high10_444": "AV1High10_444TestFrame",
}


class Bits:
    def __init__(self, data):
        self.bits = "".join(f"{byte:08b}" for byte in data)
        self.position = 0

    def get(self, count):
        chunk = self.bits[self.position:self.position + count]
        assert len(chunk) == count
        self.position += count
        return int(chunk or "0", 2)

    def ue(self):
        zeros = 0
        while self.get(1) == 0:
            zeros += 1
            assert zeros < 32
        return (1 << zeros) - 1 + self.get(zeros)


def unescape(data):
    result = bytearray()
    zeros = 0
    for byte in data:
        if zeros >= 2 and byte == 3:
            zeros = 0
            continue
        result.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(result)


def escape(data):
    result = bytearray()
    zeros = 0
    for byte in data:
        if zeros == 2 and byte <= 3:
            result.append(3)
            zeros = 0
        result.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(result)


def low_delay_single_idr(data):
    """Only lower the RExt SPS max_num_reorder_pics declaration from two to zero.

    The source contains one IDR and no other pictures. Keep every coded-picture
    byte, DPB declaration and SPS tool flag intact. The production parser retains
    its prohibition on sequences requiring display reordering.
    """
    units = list(re.finditer(b"\x00\x00(?:\x00)?\x01", data))
    patches = []
    for index, unit in enumerate(units):
        end = units[index + 1].start() if index + 1 < len(units) else len(data)
        nal = data[unit.end():end]
        if (nal[0] >> 1) & 63 != 33:
            continue
        bits = Bits(unescape(nal[2:]))
        bits.get(4)
        assert bits.get(3) == 0  # no sublayers
        bits.get(1)
        bits.get(96)  # profile/tier/level
        bits.ue()  # SPS id
        chroma = bits.ue()
        if chroma == 3:
            assert bits.get(1) == 0
        bits.ue(); bits.ue()  # width, height
        if bits.get(1):
            for _ in range(4):
                bits.ue()
        bits.ue(); bits.ue(); bits.ue()  # sample depths, POC
        bits.get(1); bits.ue()  # ordering present, DPB
        start = bits.position
        assert bits.ue() == 2
        finish = bits.position
        # Remove old byte alignment zeros and regenerate rbsp trailing padding.
        meaningful = bits.bits.rstrip("0")
        rewritten = meaningful[:start] + "1" + meaningful[finish:]
        rewritten += "0" * (-len(rewritten) % 8)
        raw = bytes(int(rewritten[pos:pos + 8], 2) for pos in range(0, len(rewritten), 8))
        patches.append((unit.end(), end, nal[:2] + escape(raw)))
    assert len(patches) == 1
    start, end, replacement = patches[0]
    return data[:start] + replacement + data[end:]


def trim_av1_padding(data):
    """Walk sized low-overhead OBUs, then omit only terminal FFmpeg zero padding."""
    position = 0
    while position < len(data) and data[position] != 0:
        header = data[position]
        position += 1
        assert header & 2 and not header & 0x81
        if header & 4:
            position += 1
        size = 0
        for shift in range(0, 56, 7):
            byte = data[position]
            position += 1
            size |= (byte & 127) << shift
            if not byte & 128:
                break
        else:
            raise ValueError("invalid OBU length")
        position += size
        assert position <= len(data)
    assert all(byte == 0 for byte in data[position:])
    return data[:position]


def main():
    source = subprocess.check_output(["git", "-C", sys.argv[1], "show", f"{REVISION}:{SOURCE}"])
    lines = ["// SPDX-License-Identifier: GPL-3.0-only",
             "// Encoded probe frames adapted from Moonlight Qt contributors.",
             f"// Source: https://github.com/moonlight-stream/moonlight-qt/blob/{REVISION}/{SOURCE}",
             f"// Source SHA-256: {hashlib.sha256(source).hexdigest()}",
             "// Reproduce: python3 scripts/import-profile-samples.py /path/to/moonlight-qt",
             "// Eight tiny 1280x720 representative AUs, not a quality or throughput fixture.",
             "// HEVC RExt: only SPS max_num_reorder_pics 2 -> 0 for the single IDR;",
             "// all coded-picture bytes stay intact. AV1: only sized-OBU trailing zero",
             "// FFmpeg padding is removed. The original fixtures are never overwritten.",
             "#pragma once", "#include <cstdint>", "namespace mav::profile_samples {"]
    for name, original_name in SAMPLES.items():
        match = re.search(r"k_" + original_name + r"\[\]\s*=\s*\{(.*?)\}", source.decode(), re.S)
        original = bytes(int(value, 16) for value in re.findall(r"0[xX]([0-9a-fA-F]+)", match[1]))
        data = low_delay_single_idr(original) if name.startswith("hevc_rext") else trim_av1_padding(original) if name.startswith("av1") else original
        lines += [f"// {original_name}: original {len(original)} bytes, SHA-256 {hashlib.sha256(original).hexdigest()}",
                  f"// Adapted {len(data)} bytes, SHA-256 {hashlib.sha256(data).hexdigest()}",
                  f"inline constexpr uint8_t {name}[] = {{"]
        for at in range(0, len(data), 12):
            lines.append("    " + ", ".join(f"0x{byte:02x}" for byte in data[at:at + 12]) + ",")
        lines += ["};", ""]
    lines += ["}", ""]
    target = Path(__file__).resolve().parents[1] / "src/profile_samples.hpp"
    target.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
