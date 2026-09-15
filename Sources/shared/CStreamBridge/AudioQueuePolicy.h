#pragma once
#include <stdbool.h>
#include <stdint.h>

#define SF_AUDIO_CAPACITY_FRAMES 2048u
#define SF_AUDIO_SPATIAL_BATCH_FRAMES 960u
#define SF_AUDIO_SPATIAL_TARGET_FRAMES 3840u
#define SF_AUDIO_SPATIAL_MAX_TARGET_FRAMES 23040u
#define SF_AUDIO_SPATIAL_SCHEDULE_FRAMES 24000u
#define SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS 2000000000ull
#define SF_AUDIO_STALL_LIMIT_NS ((uint64_t)SF_AUDIO_CAPACITY_FRAMES * 1000000000u / 48000u)
#define SF_AUDIO_SPATIAL_BATCH_NS ((uint64_t)SF_AUDIO_SPATIAL_BATCH_FRAMES * 1000000000u / 48000u)

typedef struct { uint64_t progress_ns; bool waiting; } SFAudioQueueProgress;
// A full queue is not a freshness guarantee: a repeatedly polled but blocked
// renderer could otherwise retain the same old PCM while dropping new packets.
// Uses host monotonic time, so it also covers a stopped renderer timebase.
static inline bool sf_audio_queue_stalled(SFAudioQueueProgress *progress, uint64_t now_ns, uint32_t queued) {
    if (!queued) { progress->waiting = false; return false; }
    if (!progress->waiting) { progress->waiting = true; progress->progress_ns = now_ns; return false; }
    return now_ns >= progress->progress_ns && now_ns - progress->progress_ns > SF_AUDIO_STALL_LIMIT_NS;
}
static inline void sf_audio_queue_did_consume(SFAudioQueueProgress *progress, uint64_t now_ns) {
    progress->progress_ns = now_ns; progress->waiting = true;
}
// Never fragment an Opus packet just to fill a few samples at the cap. Real PCM
// is grouped into 20ms batches; one full batch may extend the current target.
static inline uint32_t sf_audio_spatial_chunk_frames(int64_t pending, uint32_t available, bool fill_silence, uint32_t target) {
    if (pending >= target) return 0;
    if (available >= SF_AUDIO_SPATIAL_BATCH_FRAMES) return SF_AUDIO_SPATIAL_BATCH_FRAMES;
    // Allow a full packet-collection interval before padding a network/DTX gap.
    if (fill_silence && pending <= target - SF_AUDIO_SPATIAL_BATCH_FRAMES)
        return SF_AUDIO_SPATIAL_BATCH_FRAMES;
    return 0;
}

// Keep admission's future horizon separate from the duration actually queued.
// Future gaps are not submitted PCM and must not inflate queue statistics.
typedef struct { int64_t start_frame, end_frame; } SFAudioSubmittedBatch;
typedef struct { SFAudioSubmittedBatch batches[32]; uint32_t count; } SFAudioSubmittedQueue;
static inline uint64_t sf_audio_submitted_frames(SFAudioSubmittedQueue *queue, int64_t now) {
    uint32_t keep = 0; uint64_t frames = 0;
    for (uint32_t i = 0; i < queue->count; ++i) {
        SFAudioSubmittedBatch batch = queue->batches[i];
        if (batch.end_frame <= now) continue;
        queue->batches[keep++] = batch;
        int64_t beginning = batch.start_frame > now ? batch.start_frame : now;
        frames += (uint64_t)(batch.end_frame - beginning);
    }
    queue->count = keep;
    return frames;
}
static inline bool sf_audio_submitted_add(SFAudioSubmittedQueue *queue, int64_t start, uint32_t frames, int64_t now) {
    sf_audio_submitted_frames(queue, now);
    if (queue->count == 32) return false;
    queue->batches[queue->count++] = (SFAudioSubmittedBatch){ start, start + frames };
    return true;
}
typedef enum { SF_AUDIO_PAUSING, SF_AUDIO_PRIMING, SF_AUDIO_RESUMING, SF_AUDIO_RUNNING } SFAudioSpatialPhase;
static inline SFAudioSpatialPhase sf_audio_spatial_acknowledge(SFAudioSpatialPhase phase, double sync_rate, double renderer_rate) {
    if (phase == SF_AUDIO_PAUSING && sync_rate == 0 && renderer_rate == 0) return SF_AUDIO_PRIMING;
    if (phase == SF_AUDIO_RESUMING && sync_rate > 0 && renderer_rate > 0) return SF_AUDIO_RUNNING;
    return phase;
}
static inline uint32_t sf_audio_spatial_route_floor(uint64_t route_frames) {
    uint64_t rounded = (route_frames + SF_AUDIO_SPATIAL_BATCH_FRAMES - 1) / SF_AUDIO_SPATIAL_BATCH_FRAMES * SF_AUDIO_SPATIAL_BATCH_FRAMES;
    if (rounded > SF_AUDIO_SPATIAL_MAX_TARGET_FRAMES) return 0;
    return rounded > SF_AUDIO_SPATIAL_TARGET_FRAMES ? (uint32_t)rounded : SF_AUDIO_SPATIAL_TARGET_FRAMES;
}
static inline bool sf_audio_spatial_preroll_ready(uint64_t queued, uint32_t floor) {
    // Apple's prerecorded-media preroll flag requires >500ms on tested macOS
    // routes. Real-time playback deliberately uses the bounded route floor.
    return queued >= floor;
}
static inline uint32_t sf_audio_spatial_running_target(uint64_t preroll) {
    uint64_t target = preroll + SF_AUDIO_SPATIAL_BATCH_FRAMES;
    return target > SF_AUDIO_SPATIAL_MAX_TARGET_FRAMES ? SF_AUDIO_SPATIAL_MAX_TARGET_FRAMES : (uint32_t)target;
}
typedef struct { uint64_t generation, deadline_ns, incident_ns; bool pending; } SFAudioRecoveryWindow;
static inline void sf_audio_spatial_request_recovery(SFAudioRecoveryWindow *window, uint64_t now) {
    if (!window->generation) window->incident_ns = now;
    ++window->generation; window->pending = true; window->deadline_ns = now + SF_AUDIO_SPATIAL_BATCH_NS;
}
static inline bool sf_audio_spatial_recovery_due(SFAudioRecoveryWindow *window, uint64_t now) {
    return window->pending && now >= window->deadline_ns;
}
typedef struct { int64_t frame; uint64_t host_ns; } SFAudioClockProgress;
static inline bool sf_audio_spatial_clock_stalled(SFAudioClockProgress *progress, int64_t frame, uint64_t host, uint64_t queued) {
    if (!queued || frame != progress->frame) { progress->frame = frame; progress->host_ns = host; return false; }
    return host >= progress->host_ns && host - progress->host_ns > SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS;
}
