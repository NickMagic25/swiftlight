#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio callback requires lock-free 64-bit atomics");
struct SFAudioRing {
    _Atomic uint64_t read_frame;
    _Atomic uint64_t write_frame;
    _Atomic uint64_t underruns;
    _Atomic uint64_t overruns;
    uint32_t capacity, channels;
    float *samples;
};
SFAudioRing *sf_audio_ring_create(uint32_t capacity, uint32_t channels) {
    if (capacity == 0 || capacity > 65536 || channels == 0 || channels > 8) return NULL;
    SFAudioRing *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->samples = calloc((size_t)capacity * channels, sizeof(float));
    if (!r->samples) { free(r); return NULL; }
    r->capacity = capacity; r->channels = channels;
    return r;
}
void sf_audio_ring_destroy(SFAudioRing *r) { if (r) { free(r->samples); free(r); } }
bool sf_audio_ring_write(SFAudioRing *r, const float *data, uint32_t frames) {
    if (!r || !data || !frames) return false;
    uint64_t w = atomic_load_explicit(&r->write_frame, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->read_frame, memory_order_acquire);
    if (frames > r->capacity || w - rd > r->capacity - frames) {
        atomic_fetch_add_explicit(&r->overruns, frames, memory_order_relaxed); return false;
    }
    uint32_t offset = (uint32_t)(w % r->capacity);
    uint32_t first = frames < r->capacity - offset ? frames : r->capacity - offset;
    memcpy(r->samples + (size_t)offset * r->channels, data, (size_t)first * r->channels * sizeof(float));
    memcpy(r->samples, data + (size_t)first * r->channels, (size_t)(frames - first) * r->channels * sizeof(float));
    atomic_store_explicit(&r->write_frame, w + frames, memory_order_release);
    return true;
}
uint32_t sf_audio_ring_read(SFAudioRing *r, float *data, uint32_t frames) {
    if (!r || !data) return 0;
    uint64_t rd = atomic_load_explicit(&r->read_frame, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->write_frame, memory_order_acquire);
    uint32_t count = w - rd < frames ? (uint32_t)(w - rd) : frames;
    uint32_t offset = (uint32_t)(rd % r->capacity);
    uint32_t first = count < r->capacity - offset ? count : r->capacity - offset;
    memcpy(data, r->samples + (size_t)offset * r->channels, (size_t)first * r->channels * sizeof(float));
    memcpy(data + (size_t)first * r->channels, r->samples, (size_t)(count - first) * r->channels * sizeof(float));
    memset(data + (size_t)count * r->channels, 0, (size_t)(frames - count) * r->channels * sizeof(float));
    atomic_store_explicit(&r->read_frame, rd + count, memory_order_release);
    if (count < frames) atomic_fetch_add_explicit(&r->underruns, frames - count, memory_order_relaxed);
    return count;
}
uint32_t sf_audio_ring_queued(const SFAudioRing *r) {
    if (!r) return 0;
    uint64_t rd = atomic_load_explicit(&r->read_frame, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&r->write_frame, memory_order_acquire);
    return (uint32_t)(w - rd);
}
uint64_t sf_audio_ring_underruns(const SFAudioRing *r) { return r ? atomic_load(&r->underruns) : 0; }
uint64_t sf_audio_ring_overruns(const SFAudioRing *r) { return r ? atomic_load(&r->overruns) : 0; }

void sf_audio_ring_discard_queued(SFAudioRing *r) {
    if (!r) return;
    uint64_t write = atomic_load_explicit(&r->write_frame, memory_order_acquire);
    atomic_store_explicit(&r->read_frame, write, memory_order_release);
}
