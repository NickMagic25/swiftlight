#ifndef SWIFTLIGHT_VIDEO_ABI_H
#define SWIFTLIGHT_VIDEO_ABI_H
#include <moonlight_apple_video/decoder.h>
#define SVA_TRACE_VERSION 1u
enum { SVA_BACKEND_START=1, SVA_BACKEND_SUBMIT=2, SVA_BACKEND_RETURN=4,
       SVA_GPU_COMMIT=8, SVA_GPU_EXECUTION=16 };
typedef struct sva_decode_trace {
    uint32_t struct_size, version, valid, reserved;
    uint64_t backend_start_ns, backend_submit_ns, backend_return_ns;
    uint64_t gpu_commit_ns, gpu_start_ns, gpu_end_ns, gpu_clock_uncertainty_ns;
} sva_decode_trace;
// Size-checked metadata only; output references remain borrowed.
mav_result sva_completion_copy(const mav_completion *, mav_completion *);
// The published ABI-1 VT package has no backend trace tail. Leave it unavailable.
mav_result sva_completion_get_decode_trace(const mav_completion *, sva_decode_trace *);
#endif
