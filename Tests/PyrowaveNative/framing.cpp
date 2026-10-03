#include "SPyrowaveInput.hpp"
#include <algorithm>
#include <cassert>
#include <iostream>

using Bytes = std::vector<uint8_t>;

void word(Bytes &bytes, uint32_t value) {
    for (int i = 0; i < 4; ++i) bytes.push_back(uint8_t(value >> (8 * i)));
}
void set(Bytes &bytes, size_t offset, uint32_t value) {
    for (int i = 0; i < 4; ++i) bytes[offset + i] = uint8_t(value >> (8 * i));
}
Bytes sequence(uint32_t count, uint32_t width = 128, uint32_t height = 128, bool chroma444 = false) {
    Bytes bytes;
    word(bytes, 0x80000000u | (width - 1) | ((height - 1) << 14));
    word(bytes, count | (chroma444 ? (1u << 26) : 0));
    return bytes;
}
void block(Bytes &bytes, uint32_t index) {
    word(bytes, 2u << 16);
    word(bytes, index << 8);
}
bool prepare(const Bytes &bytes, std::vector<sp_fragment> fragments = {}, uint32_t critical = 0,
             Bytes *output = nullptr) {
    swiftlight::PyrowaveInput input;
    sp_access_unit unit{bytes.data(), bytes.size(), fragments.data(), fragments.size(), critical, 0, nullptr};
    const bool valid = input.prepare(unit) == SP_OK;
    if (valid && output) {
        output->clear();
        for (const auto &range : input.ranges) {
            assert(range.offset <= bytes.size() && range.size <= bytes.size() - range.offset);
            output->insert(output->end(), bytes.begin() + range.offset, bytes.begin() + range.offset + range.size);
        }
    }
    return valid;
}

int main() {
    Bytes frame = sequence(2);
    block(frame, 0);
    block(frame, 20);
    Bytes output;
    assert(prepare(frame, {}, 0, &output) && output == frame);
    assert(prepare(frame, {{0, 8, 2}, {8, 8, 2}, {16, 8, 2}}, 1, &output) && output == frame);
    assert(prepare(frame, {{0, 24, 0}}, 0, &output) && output == frame);
    // RTP boundaries may split an intact codec record. They do not alter its bytes.
    assert(prepare(frame, {{0, 12, 2}, {12, 12, 0}}, 1, &output) && output == frame);

    // Vibepollo padding is an outer container record, never native codec input.
    // Its body is skipped without requiring zero bytes or interpreting coefficients.
    Bytes padded = sequence(2);
    word(padded, UINT32_MAX);
    word(padded, 1);
    word(padded, 0xaabbccdd);
    block(padded, 0);
    block(padded, 20);
    assert(prepare(padded, {}, 0, &output) && output == frame);

    // Legacy framing supplies a count and bounded byte lengths around codec input.
    Bytes legacy;
    word(legacy, 2);
    word(legacy, 16);
    legacy.insert(legacy.end(), frame.begin(), frame.begin() + 16);
    word(legacy, 8);
    legacy.insert(legacy.end(), frame.begin() + 16, frame.end());
    assert(prepare(legacy, {}, 0, &output) && output == frame);

    // Geometry, chroma, sequence, block identity and coefficient grammar belong
    // exclusively to the pinned native decoder. The handoff preserves them.
    for (const auto &altered : {
            [] { auto b = sequence(2, 128, 126); block(b, 0); block(b, 20); return b; }(),
            [] { auto b = sequence(2, 128, 128, true); block(b, 0); block(b, 20); return b; }(),
            [] { auto b = sequence(2); block(b, 0); block(b, 0); return b; }(),
            [] { auto b = sequence(2); block(b, 0); block(b, 0xffffff); return b; }(),
            [] { auto b = sequence(2); block(b, 0); block(b, 20); set(b, 16, (2u << 16) | (1u << 28)); return b; }(),
            [] { auto b = sequence(1); word(b, (3u << 16) | 1); word(b, 255); word(b, 0x00ffffff); return b; }()}) {
        assert(prepare(altered, {}, 0, &output) && output == altered);
    }
    auto repeatedSequence = frame;
    repeatedSequence.insert(repeatedSequence.end(), frame.begin(), frame.begin() + 8);
    assert(prepare(repeatedSequence, {}, 0, &output) && output == repeatedSequence);

    // Missing payload spans are not presented as zero-filled codec records.
    // Readiness and acceptable decoded-block ratios are native decoder decisions.
    Bytes partial = sequence(3);
    block(partial, 0);
    block(partial, 1);
    block(partial, 2);
    Bytes intact = sequence(3);
    block(intact, 0);
    block(intact, 2);
    assert(prepare(partial, {{0, 8, 2}, {8, 8, 2}, {16, 8, 1}, {24, 8, 2}}, 1, &output) && output == intact);
    assert(!prepare(partial, {{0, 8, 2}, {8, 8, 2}, {16, 8, 1}, {24, 8, 2}}, 3));
    assert(!prepare(frame, {{0, 8, 1}, {8, 16, 2}}, 1));
    assert(!prepare(legacy, {{0, uint32_t(legacy.size()), 1}}));

    // Only bounded forward traversal and transport metadata invariants reject
    // input here; coefficient and sequence semantics are not duplicated.
    auto malformed = frame;
    set(malformed, 8, 1u << 16);
    assert(!prepare(malformed));
    malformed = frame;
    set(malformed, 8, 0);
    assert(!prepare(malformed));
    malformed = frame;
    set(malformed, 8, 4095u << 16);
    assert(!prepare(malformed));
    malformed = frame;
    malformed.pop_back();
    assert(!prepare(malformed));
    malformed = padded;
    set(malformed, 12, UINT32_MAX);
    assert(!prepare(malformed));
    malformed = legacy;
    word(malformed, 0);
    assert(!prepare(malformed));
    malformed = legacy;
    set(malformed, 4, UINT32_MAX);
    assert(!prepare(malformed));
    assert(!prepare(frame, {{0, 8, 0}, {9, 16, 0}}));
    assert(!prepare(frame, {{0, 24, 0}}, 2));
    assert(!prepare(frame, {{0, 24, 3}}));

    // A recovery marker cannot manufacture an odd-offset native typed header.
    Bytes odd = sequence(2);
    block(odd, 0);
    odd.push_back(0);
    block(odd, 1);
    odd.resize(28, 0);
    assert(!prepare(odd, {{0, 16, 2}, {16, 1, 1}, {17, 8, 2}, {25, 3, 1}}, 1));

    Bytes unaligned(frame.size() + 1);
    std::copy(frame.begin(), frame.end(), unaligned.begin() + 1);
    swiftlight::PyrowaveInput input;
    sp_access_unit unit{unaligned.data() + 1, frame.size(), nullptr, 0, 0, 0, nullptr};
    assert(input.prepare(unit) == SP_OK);
    std::cout << "PyroWave outer framing, native pass-through, padding, bounded loss handoff and alignment checks passed\n";
}
