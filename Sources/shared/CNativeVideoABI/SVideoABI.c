#include "SVideoABI.h"
#include <string.h>
mav_result sva_completion_copy(const mav_completion *source, mav_completion *out) {
    const size_t required = offsetof(mav_completion, trace) + sizeof(mav_trace);
    if (!source || !out || source->version != MAV_ABI_VERSION || source->struct_size < required)
        return MAV_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    memcpy(out, source, source->struct_size < sizeof(*out) ? source->struct_size : sizeof(*out));
    return MAV_OK;
}
mav_result sva_completion_get_decode_trace(const mav_completion *source, sva_decode_trace *out) {
    if (!source || !out || out->struct_size < sizeof(*out) || out->version != SVA_TRACE_VERSION)
        return MAV_INVALID_ARGUMENT;
#if MAV_ABI_VERSION >= 2
    mav_decode_trace native = {0};
    native.struct_size = sizeof(native); native.version = MAV_ABI_VERSION;
    mav_result result = mav_completion_get_decode_trace(source, &native);
    if (result != MAV_OK) return result;
    out->valid = native.valid;
    out->backend_start_ns = native.backend_start_ns; out->backend_submit_ns = native.backend_submit_ns;
    out->backend_return_ns = native.backend_return_ns; out->gpu_commit_ns = native.gpu_commit_ns;
    out->gpu_start_ns = native.gpu_start_ns; out->gpu_end_ns = native.gpu_end_ns;
    out->gpu_clock_uncertainty_ns = native.gpu_clock_uncertainty_ns;
    return MAV_OK;
#else
    return MAV_API_UNAVAILABLE;
#endif
}
