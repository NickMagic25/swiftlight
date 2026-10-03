#include "include/SPyrowave.h"
#include "SPyrowaveInput.hpp"
#include "pyrowave_metal.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMediaTiming.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <time.h>
#if __has_feature(thread_sanitizer)
#include <sanitizer/tsan_interface.h>
#endif

namespace { struct SharedState; }
struct sp_gpu_frame_opaque {
    std::atomic<uint32_t> references{0};
    std::shared_ptr<SharedState> owner;
    id<MTLTexture> planes[3];
    uint32_t chroma = 0;
};
namespace {
struct SharedState : std::enable_shared_from_this<SharedState> {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<std::unique_ptr<sp_gpu_frame_opaque>> slots;
    uint32_t pending = 0, limit = 2;
    uint64_t generation = 1;
    bool closed = false, failed = false;
    bool available_locked() const {
        if (pending >= limit) return false;
        for (const auto &slot : slots) if (!slot->references.load()) return true;
        return slots.size() < size_t(limit) + 4;
    }
    sp_gpu_frame acquire(id<MTLDevice> device, const sp_config &config) {
        std::lock_guard<std::mutex> lock(mutex);
        sp_gpu_frame frame = nullptr;
        for (const auto &slot : slots) if (!slot->references.load()) { frame = slot.get(); break; }
        if (!frame) {
            if (slots.size() >= size_t(limit) + 4) return nullptr;
            auto slot = std::make_unique<sp_gpu_frame_opaque>();
            for (uint32_t i = 0; i < 3; ++i) {
                const NSUInteger divisor = i && config.chroma == 1 ? 2 : 1;
                MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:config.bit_depth == 10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm
                    width:config.width / divisor height:config.height / divisor mipmapped:NO];
                descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                descriptor.storageMode = MTLStorageModePrivate;
                slot->planes[i] = [device newTextureWithDescriptor:descriptor];
                if (!slot->planes[i]) return nullptr;
                slot->planes[i].label = i == 0 ? @"Swiftlight PyroWave Y" : i == 1 ? @"Swiftlight PyroWave Cb" : @"Swiftlight PyroWave Cr";
            }
            slot->chroma = config.chroma;
            frame = slot.get(); slots.push_back(std::move(slot));
        }
        frame->owner = shared_from_this(); frame->references.store(1);
        return frame;
    }
};
// GPUStartTime/GPUEndTime use the Core Animation host clock. A bounded
// paired reading maps them into CLOCK_UPTIME_RAW without assuming equal epochs.
struct GPUClockCalibration {
    uint64_t monotonic_ns = 0, uncertainty_ns = 0;
    double host_seconds = 0;
    bool valid = false;
    static GPUClockCalibration sample() {
        const auto before = sp_monotonic_time_ns(); const auto host = CACurrentMediaTime(); const auto after = sp_monotonic_time_ns();
        GPUClockCalibration result;
        if (!before || after < before || !std::isfinite(host) || host <= 0) return result;
        const auto width = after - before;
        result.uncertainty_ns = width / 2 + width % 2;
        if (result.uncertainty_ns > 1000000) return result;
        result.monotonic_ns = before + width / 2; result.host_seconds = host; result.valid = true;
        return result;
    }
    bool map(double host, uint64_t &result) const {
        if (!valid || !std::isfinite(host) || host <= 0) return false;
        const double delta = (host - host_seconds) * 1000000000.0;
        const double magnitude = std::round(std::abs(delta));
        if (!std::isfinite(magnitude) || magnitude >= double(std::numeric_limits<uint64_t>::max())) return false;
        const auto offset = uint64_t(magnitude);
        if (delta >= 0) { if (offset > UINT64_MAX - monotonic_ns) return false; result = monotonic_ns + offset; }
        else { if (offset >= monotonic_ns) return false; result = monotonic_ns - offset; }
        return true;
    }
};
struct Work { sp_completion completion{}; };
}

struct sp_decoder_opaque {
    sp_config config{};
    sp_completion_callback callback = nullptr;
    void *userdata = nullptr;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    pyrowave_device pyro_device = nullptr;
    pyrowave_decoder pyro_decoder = nullptr;
    swiftlight::PyrowaveInput input;
    std::vector<uint32_t> aligned_input;
    std::shared_ptr<SharedState> state = std::make_shared<SharedState>();
    ~sp_decoder_opaque() {
        if (pyro_decoder) pyrowave_decoder_destroy(pyro_decoder);
        if (pyro_device) pyrowave_device_destroy(pyro_device);
    }
    sp_result create_backend() {
        const pyrowave_decoder_create_info info{pyro_device, int(config.width), int(config.height), config.chroma == 3 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420};
        return pyrowave_decoder_create(&info, &pyro_decoder) == PYROWAVE_SUCCESS ? SP_OK : SP_BACKEND;
    }
};

extern "C" {
uint64_t sp_monotonic_time_ns(void) {
    timespec time{}; clock_gettime(CLOCK_UPTIME_RAW, &time);
    return uint64_t(time.tv_sec) * 1000000000ull + uint64_t(time.tv_nsec);
}
int sp_device_is_supported(void) {
    @autoreleasepool { return pyrowave_device_is_supported((__bridge void *)MTLCreateSystemDefaultDevice()) ? 1 : 0; }
}
sp_result sp_decoder_create(const sp_config *config, sp_completion_callback callback, void *userdata, sp_decoder *output) {
    if (!output) return SP_INVALID;
    *output = nullptr;
    if (!config || !callback || !config->width || config->width > 16384 || !config->height || config->height > 16384 ||
        (config->bit_depth != 8 && config->bit_depth != 10) || (config->chroma != 1 && config->chroma != 3) ||
        (config->chroma == 1 && ((config->width | config->height) & 1)) || !config->max_frames_in_flight || config->max_frames_in_flight > 2) return SP_INVALID;
    @autoreleasepool {
        try {
            auto decoder = std::make_unique<sp_decoder_opaque>();
            decoder->config = *config; decoder->callback = callback; decoder->userdata = userdata;
            decoder->state->limit = config->max_frames_in_flight;
            decoder->device = MTLCreateSystemDefaultDevice();
            if (!decoder->device || !pyrowave_device_is_supported((__bridge void *)decoder->device)) return SP_BACKEND;
            decoder->queue = [decoder->device newCommandQueue];
            if (!decoder->queue) return SP_BACKEND;
            pyrowave_device_create_info info{}; info.mtl_device = (__bridge void *)decoder->device;
            if (pyrowave_device_create(&info, &decoder->pyro_device) != PYROWAVE_SUCCESS || decoder->create_backend() != SP_OK) return SP_BACKEND;
            *output = decoder.release(); return SP_OK;
        } catch (const std::bad_alloc &) { return SP_BACKEND; }
    }
}
sp_result sp_decoder_submit(sp_decoder decoder, const sp_access_unit *input) {
    if (!decoder || !input) return SP_INVALID;
    const auto admission = sp_monotonic_time_ns();
    {
        std::lock_guard<std::mutex> lock(decoder->state->mutex);
        if (decoder->state->closed) return SP_CLOSED;
        if (decoder->state->failed) return SP_BACKEND;
        if (!decoder->state->available_locked()) return SP_WOULD_BLOCK;
    }
    @autoreleasepool {
        try {
            const auto prep_start = sp_monotonic_time_ns();
            const auto prepared = decoder->input.prepare(*input);
            if (prepared != SP_OK) return prepared;
            const void *source = input->bytes;
            const bool alignment_copy = (uintptr_t(source) & 3) != 0;
            if (alignment_copy) {
                // Swift's small inline Data and slices need not be word aligned.
                // Upstream uses typed word loads; copy only this exceptional
                // input into reusable aligned storage after envelope extraction.
                decoder->aligned_input.resize(input->size / 4);
                std::memcpy(decoder->aligned_input.data(), source, input->size);
                source = decoder->aligned_input.data();
            }
            const auto prep_end = sp_monotonic_time_ns();
            auto work = std::make_shared<Work>();
            auto &completion = work->completion;
            completion.frame_id = input->frame_id; completion.context = input->context;
            completion.admission_ns = admission; completion.preparation_start_ns = prep_start; completion.preparation_end_ns = prep_end;
            completion.width = decoder->config.width; completion.height = decoder->config.height;
            completion.bit_depth = decoder->config.bit_depth; completion.chroma = decoder->config.chroma;
            completion.compressed_copy_count = (decoder->input.coded_bytes ? 2 : 0) + (alignment_copy ? 1 : 0);
            completion.compressed_copy_bytes = 2 * decoder->input.coded_bytes + (alignment_copy ? input->size : 0);
            completion.backend_start_ns = sp_monotonic_time_ns();
            pyrowave_decoder_clear(decoder->pyro_decoder);
            for (const auto &range : decoder->input.ranges) {
                const auto result = pyrowave_decoder_push_packet(decoder->pyro_decoder, static_cast<const uint8_t *>(source) + range.offset, range.size);
                if (result != PYROWAVE_SUCCESS) return result == PYROWAVE_ERROR_CORRUPT_BITSTREAM ? SP_MALFORMED : SP_BACKEND;
            }
            // PyroWave decides whether the submitted records are ready. The
            // host's critical-packet sideband supplies its coarse-band guarantee;
            // without that sideband, use the decoder's pristine-band check.
            if (!pyrowave_decoder_decode_is_ready_with_sideband(decoder->pyro_decoder, decoder->input.partial,
                    input->critical_packets ? 0 : 2, 0.9f, nullptr, 0)) return SP_MALFORMED;
            auto frame = decoder->state->acquire(decoder->device, decoder->config);
            if (!frame) return SP_BACKEND;
            id<MTLCommandBuffer> command = [decoder->queue commandBuffer];
            if (!command) { sp_gpu_frame_release(frame); return SP_BACKEND; }
            pyrowave_gpu_buffers buffers{};
            for (uint32_t i = 0; i < 3; ++i) buffers.planes[i] = sp_gpu_frame_plane(frame, i);
            completion.backend_submit_ns = sp_monotonic_time_ns();
            const auto result = pyrowave_decoder_decode_gpu_buffer(decoder->pyro_decoder, (__bridge void *)command, &buffers);
            completion.backend_return_ns = sp_monotonic_time_ns();
            if (result != PYROWAVE_SUCCESS) {
                // An encode failure may have advanced the fork's four-slot
                // upload cursor. Stop admission until reset rebuilds its state.
                { std::lock_guard<std::mutex> lock(decoder->state->mutex); decoder->state->failed = true; }
                sp_gpu_frame_release(frame); return result == PYROWAVE_ERROR_CORRUPT_BITSTREAM ? SP_MALFORMED : SP_BACKEND;
            }
            command.label = @"Swiftlight direct PyroWave decode";
            auto state = decoder->state;
            const auto callback = decoder->callback; const auto userdata = decoder->userdata;
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                completion.generation = state->generation; ++state->pending;
            }
            [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
#if __has_feature(thread_sanitizer)
                __tsan_acquire((__bridge void *)done);
#endif
                auto output = work->completion; output.callback_ns = sp_monotonic_time_ns();
                bool cancelled;
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    cancelled = state->closed || state->generation != output.generation;
                    if (done.status != MTLCommandBufferStatusCompleted) state->failed = true;
                }
                if (cancelled) { output.status = SP_CANCELLED; output.result = SP_CLOSED; }
                else if (done.status == MTLCommandBufferStatusCompleted) {
                    output.status = SP_OUTPUT; output.result = SP_OK; output.gpu_frame = frame;
                    const auto calibration = GPUClockCalibration::sample();
                    uint64_t start_ns = 0, end_ns = 0;
                    if (done.GPUEndTime >= done.GPUStartTime && calibration.map(done.GPUStartTime, start_ns) && calibration.map(done.GPUEndTime, end_ns) &&
                        start_ns >= output.gpu_commit_ns && end_ns >= start_ns && end_ns <= output.callback_ns) {
                        output.gpu_start_ns = start_ns; output.gpu_end_ns = end_ns; output.gpu_clock_uncertainty_ns = calibration.uncertainty_ns;
                    }
                } else { output.status = SP_FAILED; output.result = SP_BACKEND; output.backend_status = int32_t(done.error.code); }
                callback(userdata, &output);
                sp_gpu_frame_release(frame);
                // The shared state outlives decoder destruction. Drain returns
                // only after callbacks consumed every accepted AU context.
                { std::lock_guard<std::mutex> lock(state->mutex); --state->pending; state->changed.notify_all(); }
            }];
            completion.gpu_commit_ns = sp_monotonic_time_ns();
#if __has_feature(thread_sanitizer)
            // Metal publishes copied C++ block captures through its driver.
            __tsan_release((__bridge void *)command);
#endif
            [command commit];
            return SP_OK;
        } catch (const std::bad_alloc &) { return SP_BACKEND; }
    }
}
sp_result sp_decoder_wait_for_capacity(sp_decoder decoder, uint64_t timeout_ns) {
    if (!decoder) return SP_INVALID;
    auto state = decoder->state;
    std::unique_lock<std::mutex> lock(state->mutex);
    const auto ready = [&] { return state->closed || state->failed || state->available_locked(); };
    if (timeout_ns == UINT64_MAX) state->changed.wait(lock, ready);
    else if (!state->changed.wait_for(lock, std::chrono::nanoseconds(std::min<uint64_t>(timeout_ns, INT64_MAX)), ready)) return SP_TIMEOUT;
    return state->closed ? SP_CLOSED : state->failed ? SP_BACKEND : SP_OK;
}
sp_result sp_decoder_drain(sp_decoder decoder) {
    if (!decoder) return SP_INVALID;
    std::unique_lock<std::mutex> lock(decoder->state->mutex);
    decoder->state->changed.wait(lock, [&] { return !decoder->state->pending; }); return SP_OK;
}
sp_result sp_decoder_reset(sp_decoder decoder) {
    if (!decoder) return SP_INVALID;
    { std::lock_guard<std::mutex> lock(decoder->state->mutex); if (decoder->state->closed) return SP_CLOSED; ++decoder->state->generation; }
    sp_decoder_drain(decoder);
    @autoreleasepool {
        pyrowave_decoder_destroy(decoder->pyro_decoder); decoder->pyro_decoder = nullptr;
        sp_result result = SP_BACKEND;
        try { result = decoder->create_backend(); } catch (const std::bad_alloc &) {}
        { std::lock_guard<std::mutex> lock(decoder->state->mutex); decoder->state->failed = result != SP_OK; decoder->state->changed.notify_all(); }
        return result;
    }
}
sp_result sp_decoder_destroy(sp_decoder decoder) {
    if (!decoder) return SP_INVALID;
    { std::lock_guard<std::mutex> lock(decoder->state->mutex); decoder->state->closed = true; ++decoder->state->generation; decoder->state->changed.notify_all(); }
    sp_decoder_drain(decoder);
    @autoreleasepool { delete decoder; }
    return SP_OK;
}
void sp_gpu_frame_retain(sp_gpu_frame frame) { if (frame) frame->references.fetch_add(1); }
void sp_gpu_frame_release(sp_gpu_frame frame) {
    if (!frame) return;
    auto state = frame->owner;
    std::lock_guard<std::mutex> lock(state->mutex);
    if (frame->references.fetch_sub(1) == 1) { frame->owner.reset(); state->changed.notify_all(); }
}
void *sp_gpu_frame_plane(sp_gpu_frame frame, uint32_t plane) { return frame && plane < 3 ? (__bridge void *)frame->planes[plane] : nullptr; }
uint32_t sp_gpu_frame_chroma(sp_gpu_frame frame) { return frame ? frame->chroma : 0; }
}
