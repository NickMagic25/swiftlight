#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "AudioRing.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SFStream SFStream;
typedef struct {
    const char *address, *app_version, *gfe_version, *rtsp_url;
    uint32_t server_codec_support, video_formats;
    int width, height, fps, bitrate_kbps;
    uint8_t input_key[16];
    uint32_t input_key_id;
    bool hdr;
    bool has_permissions;
    uint32_t permissions;
    int display_refresh_rate_x100;
} SFStreamConfiguration;
typedef struct { uint32_t format; int width, height, fps; } SFVideoDescription;
typedef struct {
    const uint8_t *bytes;
    size_t length;
    uint64_t frame_id, receive_time_us, enqueue_time_us, presentation_time_us;
    uint32_t rtp_timestamp;
    uint64_t receive_uptime_ns, enqueue_uptime_ns;
    bool is_idr;
} SFVideoFrame;
enum { SF_STAGE = 1, SF_STARTED, SF_TERMINATED, SF_FAILED, SF_QUALITY, SF_HDR, SF_AUDIO_ERROR, SF_RUMBLE };
typedef struct {
    int (*setup)(void *context, const SFVideoDescription *description);
    // Called on the serialized pull worker. Bytes are borrowed until return.
    // Return 0 only once the required decoder owns compressed input; -1 requests IDR.
    int (*video)(void *context, const SFVideoFrame *frame);
    // Event callbacks may arrive on common-c worker threads. Never call stop/destroy inline.
    void (*event)(void *context, int kind, int a, int b, int c, const char *message);
} SFStreamCallbacks;
SFStream *sf_stream_create(const SFStreamConfiguration *configuration, SFStreamCallbacks callbacks, void *context);
// Start and stop must be serialized by the owner; common-c supports one global session.
int sf_stream_start(SFStream *stream);
void sf_stream_cancel_start(SFStream *stream);
void sf_stream_stop(SFStream *stream);
void sf_stream_destroy(SFStream *stream);
void sf_stream_request_idr(SFStream *stream);
void sf_stream_release_inputs(SFStream *stream);
int sf_stream_mouse_move(SFStream *, int16_t dx, int16_t dy);
int sf_stream_mouse_position(SFStream *, int16_t x, int16_t y, int16_t width, int16_t height);
int sf_stream_mouse_button(SFStream *, int button, bool pressed);
int sf_stream_key(SFStream *, uint16_t key, bool pressed, uint8_t modifiers);
int sf_stream_scroll(SFStream *, int16_t vertical, int16_t horizontal);
int sf_stream_controller(SFStream *, uint8_t index, uint16_t active_mask, uint32_t buttons,
                         uint8_t left_trigger, uint8_t right_trigger,
                         int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y);
typedef struct {
    bool rtt_available;
    uint32_t rtt_ms, rtt_variance_ms;
    int pending_video_frames, pending_audio_ms;
    uint64_t audio_queued_frames, audio_underrun_frames, audio_overrun_frames;
    char local_address[128], interface_name[64];
} SFTransportDiagnostics;
bool sf_stream_diagnostics(SFStream *stream, SFTransportDiagnostics *diagnostics);
const char *sf_stream_launch_query(void);
// Server-free seam runs the exact frame flattener, callback, and exactly-once completion owner.
// A valid acquired frame is completed once even if malformed, cancelled, or rejected.
bool sf_stream_validate_keyboard_wire_codes(void);
bool sf_stream_validate_cancel_state_race(void);
bool sf_stream_validate_clock_mapping(void);
bool sf_stream_validate_event_retirement(void);
int sf_stream_validate_frame_ownership(unsigned scenario, unsigned *completions, unsigned *submissions);
#ifdef __cplusplus
}
#endif
