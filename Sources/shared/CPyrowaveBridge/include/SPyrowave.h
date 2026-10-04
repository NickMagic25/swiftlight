#ifndef SWIFTLIGHT_PYROWAVE_H
#define SWIFTLIGHT_PYROWAVE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define SP_ABI_VERSION 1
typedef struct sp_decoder_opaque *sp_decoder;
typedef struct sp_gpu_frame_opaque *sp_gpu_frame;
typedef enum sp_result {
    SP_OK = 0, SP_WOULD_BLOCK = 1, SP_MALFORMED = 2, SP_INVALID = 3,
    SP_BACKEND = 4, SP_CLOSED = 5, SP_TIMEOUT = 6
} sp_result;
typedef enum sp_completion_status {
    SP_OUTPUT = 0, SP_CANCELLED = 1, SP_FAILED = 2, SP_DROPPED = 3
} sp_completion_status;
typedef struct sp_fragment { uint32_t offset, size, kind; } sp_fragment;
enum { SP_FRAGMENT_DATA = 0, SP_FRAGMENT_LOST = 1, SP_FRAGMENT_RECORD_START = 2 };
typedef struct sp_config {
    uint32_t width, height, bit_depth, chroma, max_frames_in_flight;
} sp_config;
typedef struct sp_access_unit {
    const void *bytes;
    size_t size;
    const sp_fragment *fragments;
    size_t fragment_count;
    uint32_t critical_packets;
    uint64_t frame_id;
    void *context;
} sp_access_unit;
typedef struct sp_completion {
    uint64_t frame_id, generation;
    void *context;
    sp_completion_status status;
    sp_result result;
    int32_t backend_status;
    uint32_t width, height, bit_depth, chroma;
    // Borrowed through callback return. Retain to render after the callback.
    sp_gpu_frame gpu_frame;
    uint64_t admission_ns, preparation_start_ns, preparation_end_ns;
    uint64_t backend_start_ns, backend_submit_ns, backend_return_ns;
    uint64_t gpu_commit_ns, callback_ns;
    // Zero when unavailable; clock calibrated to sp_monotonic_time_ns().
    uint64_t gpu_start_ns, gpu_end_ns, gpu_clock_uncertainty_ns;
    // Upper bound for submitted record concatenation/upload bytes; native may
    // discard duplicates. Unaligned input adds one exceptional alignment copy.
    // Decoded pixels never cross the CPU.
    uint64_t compressed_copy_bytes;
    uint32_t compressed_copy_count;
} sp_completion;
typedef void (*sp_completion_callback)(void *userdata, const sp_completion *completion);

int sp_device_is_supported(void);
uint64_t sp_monotonic_time_ns(void);
sp_result sp_decoder_create(const sp_config *, sp_completion_callback, void *userdata, sp_decoder *);
// All controls belong on the caller's serial video worker. A rejected submit
// consumes nothing; SP_OK owes exactly one callback, which may race return.
// Input and fragment memory are borrowed only until submit returns. The callback
// consumes AU.context exactly once. Never call controls from the callback.
sp_result sp_decoder_submit(sp_decoder, const sp_access_unit *);
sp_result sp_decoder_wait_for_capacity(sp_decoder, uint64_t timeout_ns);
sp_result sp_decoder_drain(sp_decoder);
// Increments generation before waiting; accepted old work completes CANCELLED.
sp_result sp_decoder_reset(sp_decoder);
sp_result sp_decoder_destroy(sp_decoder);
void sp_gpu_frame_retain(sp_gpu_frame);
void sp_gpu_frame_release(sp_gpu_frame);
// Borrowed id<MTLTexture>, all three planes on the decoder's Metal device.
void *sp_gpu_frame_plane(sp_gpu_frame, uint32_t plane);
uint32_t sp_gpu_frame_chroma(sp_gpu_frame);

#ifdef __cplusplus
}
#endif
#endif
