#include "SPyrowave.h"
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <condition_variable>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <vector>

struct Outputs {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<sp_gpu_frame> frames;
    std::map<uint64_t, unsigned> terminals;
    bool hold = false, entered = false;
    uint32_t failed = 0;
    uint32_t expected_copy_count = UINT32_MAX;
    uint64_t expected_copy_bytes = UINT64_MAX;
    static void callback(void *context, const sp_completion *c) {
        auto &self = *static_cast<Outputs *>(context);
        std::unique_lock<std::mutex> lock(self.mutex);
        assert(++self.terminals[c->frame_id] == 1);
        assert(c->context == reinterpret_cast<void *>(uintptr_t(c->frame_id + 1)));
        if (self.expected_copy_count != UINT32_MAX) assert(c->compressed_copy_count == self.expected_copy_count);
        if (self.expected_copy_bytes != UINT64_MAX) assert(c->compressed_copy_bytes == self.expected_copy_bytes);
        assert(c->admission_ns <= c->preparation_start_ns && c->preparation_start_ns <= c->preparation_end_ns);
        assert(c->preparation_end_ns <= c->backend_start_ns && c->backend_start_ns <= c->backend_submit_ns);
        assert(c->backend_submit_ns <= c->backend_return_ns && c->backend_return_ns <= c->gpu_commit_ns && c->gpu_commit_ns <= c->callback_ns);
        if (c->gpu_start_ns) {
            assert(c->gpu_commit_ns <= c->gpu_start_ns && c->gpu_start_ns <= c->gpu_end_ns && c->gpu_end_ns <= c->callback_ns);
            assert(c->gpu_clock_uncertainty_ns <= 1000000);
        }
        if (c->status == SP_OUTPUT) {
            assert(c->result == SP_OK && c->gpu_frame);
            sp_gpu_frame_retain(c->gpu_frame); self.frames.push_back(c->gpu_frame);
        } else if (c->status != SP_CANCELLED) ++self.failed;
        self.entered = true; self.changed.notify_all();
        self.changed.wait(lock, [&] { return !self.hold; });
    }
    void wait(size_t count) {
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, std::chrono::seconds(10), [&] { return frames.size() >= count || failed; }));
        assert(!failed);
    }
    void release_all() { for (auto frame : frames) sp_gpu_frame_release(frame); frames.clear(); }
    ~Outputs() { release_all(); }
};
std::vector<uint8_t> readback(id<MTLTexture> texture) {
    assert(texture.storageMode == MTLStorageModePrivate && texture.textureType == MTLTextureType2D);
    const size_t bytes = texture.pixelFormat == MTLPixelFormatR16Unorm ? 2 : 1;
    const size_t row = (texture.width * bytes + 255) & ~size_t(255);
    id<MTLBuffer> buffer = [texture.device newBufferWithLength:row * texture.height options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [texture.device newCommandQueue]; id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [cmd blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                   toBuffer:buffer destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * texture.height];
    [encoder endEncoding]; [cmd commit]; [cmd waitUntilCompleted]; assert(cmd.status == MTLCommandBufferStatusCompleted);
    std::vector<uint8_t> result(texture.width * texture.height * bytes);
    for (size_t y = 0; y < texture.height; ++y) memcpy(result.data() + y * texture.width * bytes, static_cast<uint8_t *>(buffer.contents) + y * row, texture.width * bytes);
    return result;
}
sp_access_unit unit(const void *bytes, size_t size, uint64_t id) {
    return {bytes, size, nullptr, 0, 0, id, reinterpret_cast<void *>(uintptr_t(id + 1))};
}
void admission_and_partial() {
    std::vector<uint32_t> words{0x80000000u | 127u | (127u << 14), 20};
    for (uint32_t i = 0; i < 20; ++i) { words.push_back(2u << 16); words.push_back(i << 8); }
    std::vector<sp_fragment> fragments{{0, 8, SP_FRAGMENT_RECORD_START}};
    for (uint32_t i = 0; i < 20; ++i) fragments.push_back({8 + i * 8, 8, i == 17 ? SP_FRAGMENT_LOST : SP_FRAGMENT_RECORD_START});
    Outputs outputs; outputs.expected_copy_count = 2; outputs.expected_copy_bytes = 19 * 8 * 2;
    sp_config config{128, 128, 8, 1, 2}; sp_decoder decoder = nullptr;
    assert(sp_decoder_create(&config, Outputs::callback, &outputs, &decoder) == SP_OK);
    auto input = unit(words.data(), words.size() * 4, 0);
    input.fragments = fragments.data(); input.fragment_count = fragments.size(); input.critical_packets = 13;
    fragments[3].kind = SP_FRAGMENT_LOST; assert(sp_decoder_submit(decoder, &input) == SP_MALFORMED);
    fragments[3].kind = SP_FRAGMENT_RECORD_START;
    // Hold the callback after GPU completion so pending admission is deterministic.
    { std::lock_guard<std::mutex> lock(outputs.mutex); outputs.hold = true; }
    assert(sp_decoder_submit(decoder, &input) == SP_OK);
    {
        std::unique_lock<std::mutex> lock(outputs.mutex);
        assert(outputs.changed.wait_for(lock, std::chrono::seconds(10), [&] { return outputs.entered; }));
    }
    input.frame_id = 1; input.context = reinterpret_cast<void *>(2); assert(sp_decoder_submit(decoder, &input) == SP_OK);
    input.frame_id = 2; input.context = reinterpret_cast<void *>(3); assert(sp_decoder_submit(decoder, &input) == SP_WOULD_BLOCK);
    assert(sp_decoder_wait_for_capacity(decoder, 0) == SP_TIMEOUT);
    { std::lock_guard<std::mutex> lock(outputs.mutex); outputs.hold = false; outputs.changed.notify_all(); }
    assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(2);
    assert(!outputs.terminals.count(2)); // Rejected context remains caller-owned.
    assert(sp_decoder_submit(decoder, &input) == SP_OK); assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(3);
    // Many complete cycles prove the four-slot upload ring is safe behind the
    // two-command ordered admission boundary. Release output leases each cycle.
    outputs.release_all();
    for (uint64_t frame_id = 3; frame_id < 43; ++frame_id) {
        input.frame_id = frame_id; input.context = reinterpret_cast<void *>(uintptr_t(frame_id + 1));
        assert(sp_decoder_submit(decoder, &input) == SP_OK); assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(1);
        for (auto frame : outputs.frames) for (uint32_t p = 0; p < 3; ++p) {
            const auto pixels = readback((__bridge id<MTLTexture>)sp_gpu_frame_plane(frame, p));
            for (auto pixel : pixels) assert(pixel == 128);
        }
        outputs.release_all();
    }
    // The exceptional unaligned copy keeps tiny Swift Data valid and bounded.
    std::vector<uint8_t> unaligned(9); memcpy(unaligned.data() + 1, words.data(), 8); memset(unaligned.data() + 5, 0, 4);
    assert(uintptr_t(unaligned.data() + 1) & 3);
    outputs.expected_copy_count = 1; outputs.expected_copy_bytes = 8;
    auto small = unit(unaligned.data() + 1, 8, 43); assert(sp_decoder_submit(decoder, &small) == SP_OK);
    assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(1);
    assert(sp_decoder_reset(decoder) == SP_OK); assert(sp_decoder_destroy(decoder) == SP_OK);
    assert(outputs.terminals.size() == 44);
    for (auto frame : outputs.frames) for (uint32_t p = 0; p < 3; ++p) for (auto pixel : readback((__bridge id<MTLTexture>)sp_gpu_frame_plane(frame, p))) assert(pixel == 128);
    std::cout << "Two-command admission, partial recovery, 40 upload ring cycles, unaligned input and retained reset/destroy passed\n";
}
void fixture(const char *path, uint32_t width, uint32_t height, uint32_t chroma, uint32_t depth) {
    std::ifstream file(path, std::ios::binary); assert(file);
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {}); assert(!bytes.empty());
    Outputs outputs; outputs.expected_copy_count = 2; outputs.expected_copy_bytes = 2 * (bytes.size() - 8);
    sp_config config{width, height, depth, chroma, 2}; sp_decoder decoder = nullptr;
    assert(sp_decoder_create(&config, Outputs::callback, &outputs, &decoder) == SP_OK);
    auto input = unit(bytes.data(), bytes.size(), 0);
    auto malformed = bytes; memset(malformed.data(), 0, 4); auto bad = unit(malformed.data(), malformed.size(), 1000);
    assert(sp_decoder_submit(decoder, &bad) == SP_MALFORMED);
    // The adapter passes these records unchanged. Native PyroWave rejects
    // their codec contents without admitting work or consuming caller context.
    const auto reject_word = [&](size_t offset, uint32_t word) {
        auto invalid = bytes;
        for (size_t i = 0; i < 4; ++i) invalid[offset + i] = uint8_t(word >> (8 * i));
        auto input = unit(invalid.data(), invalid.size(), 1000);
        assert(sp_decoder_submit(decoder, &input) == SP_MALFORMED);
        assert(outputs.terminals.empty());
    };
    uint32_t first = 0, second = 0;
    memcpy(&first, bytes.data(), 4); memcpy(&second, bytes.data() + 4, 4);
    reject_word(0, (first & ~0x3fffu) | (width - 2));
    reject_word(4, second ^ (1u << 26));
    reject_word(4, second | (1u << 24));
    reject_word(12, 0xffffff00u);
    for (uint64_t id = 0; id < 6; ++id) {
        input.frame_id = id; input.context = reinterpret_cast<void *>(uintptr_t(id + 1));
        assert(sp_decoder_submit(decoder, &input) == SP_OK); assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(id + 1);
    }
    assert(sp_decoder_submit(decoder, &input) == SP_WOULD_BLOCK && sp_decoder_wait_for_capacity(decoder, 0) == SP_TIMEOUT);
    sp_gpu_frame_release(outputs.frames.front()); outputs.frames.erase(outputs.frames.begin());
    assert(sp_decoder_wait_for_capacity(decoder, 100000000) == SP_OK);
    input.frame_id = 6; input.context = reinterpret_cast<void *>(7); assert(sp_decoder_submit(decoder, &input) == SP_OK);
    assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(6);
    assert(sp_decoder_reset(decoder) == SP_OK); assert(sp_decoder_destroy(decoder) == SP_OK);
    auto frame = outputs.frames.back(); assert(sp_gpu_frame_chroma(frame) == chroma);
    for (uint32_t p = 0; p < 3; ++p) {
        const uint32_t w = p && chroma == 1 ? width / 2 : width, h = p && chroma == 1 ? height / 2 : height;
        id<MTLTexture> texture = (__bridge id<MTLTexture>)sp_gpu_frame_plane(frame, p); assert(texture.width == w && texture.height == h);
        const auto result = readback(texture); double max_error = 0, square = 0;
        for (uint32_t y = 0; y < h; ++y) for (uint32_t x = 0; x < w; ++x) {
            const uint32_t dx = std::max(1u, w - 1), dy = std::max(1u, h - 1);
            const uint8_t sample = p == 0 ? uint8_t(32 + 96 * x / dx + 96 * y / dy) : p == 1 ? uint8_t(64 + 64 * x / dx + 32 * y / dy) : uint8_t(160 - 48 * x / dx + 32 * y / dy);
            const size_t i = size_t(y) * w + x;
            const double actual = depth == 10 ? double(uint16_t(result[2 * i]) | uint16_t(result[2 * i + 1]) << 8) / 65535.0 : double(result[i]) / 255.0;
            const double error = std::abs(actual - double(sample) / 255.0); max_error = std::max(error, max_error); square += error * error;
        }
        assert(max_error < 0.015 && std::sqrt(square / (size_t(w) * h)) < 0.004);
        std::cout << width << 'x' << height << " chroma=" << chroma << " depth=" << depth << " plane=" << p << " max_error=" << max_error << '\n';
    }
}
void native_duplicate_record() {
    Outputs outputs; sp_config config{128, 128, 8, 1, 2}; sp_decoder decoder = nullptr;
    assert(sp_decoder_create(&config, Outputs::callback, &outputs, &decoder) == SP_OK);
    // Native PyroWave ignores an already received block. The client does not
    // override its duplicate or completeness rules.
    uint32_t words[]{0x80000000u | 127u | (127u << 14), 1, 2u << 16, 0, 2u << 16, 0};
    auto input = unit(words, sizeof(words), 0);
    assert(sp_decoder_submit(decoder, &input) == SP_OK);
    assert(sp_decoder_drain(decoder) == SP_OK); outputs.wait(1);
    assert(sp_decoder_destroy(decoder) == SP_OK);
    assert(outputs.terminals.size() == 1);
}
void pending_destroy() {
    Outputs outputs; sp_config config{128, 128, 8, 1, 2}; sp_decoder decoder = nullptr;
    assert(sp_decoder_create(&config, Outputs::callback, &outputs, &decoder) == SP_OK);
    uint32_t words[2]{0x80000000u | 127u | (127u << 14), 0}; auto input = unit(words, sizeof(words), 0);
    assert(sp_decoder_submit(decoder, &input) == SP_OK); assert(sp_decoder_destroy(decoder) == SP_OK);
    assert(outputs.terminals.size() == 1 && !outputs.failed);
}
int main(int argc, char **argv) { @autoreleasepool {
    if (!sp_device_is_supported()) { std::cout << "SKIP: Apple7 GPU unavailable\n"; return 77; }
    assert(argc == 3);
    admission_and_partial();
    native_duplicate_record();
    for (uint32_t depth : {8u, 10u}) { fixture(argv[1], 128, 128, 1, depth); fixture(argv[2], 127, 97, 3, depth); }
    pending_destroy();
    std::cout << "Direct PyroWave native Metal admission, exact-host fixtures, lifetime and teardown passed\n";
} }
