#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SFAudioRing SFAudioRing;
// Single producer / single consumer. Creation/destruction require both users joined.
SFAudioRing *sf_audio_ring_create(uint32_t capacity_frames, uint32_t channels);
void sf_audio_ring_destroy(SFAudioRing *ring);
bool sf_audio_ring_write(SFAudioRing *ring, const float *interleaved, uint32_t frames);
// Copies available frames then fills the remainder with silence; never locks or allocates.
uint32_t sf_audio_ring_read(SFAudioRing *ring, float *interleaved, uint32_t frames);
// Called only by the consumer, or after the Audio Unit consumer has stopped.
void sf_audio_ring_discard_queued(SFAudioRing *ring);
uint32_t sf_audio_ring_queued(const SFAudioRing *ring);
uint64_t sf_audio_ring_underruns(const SFAudioRing *ring);
uint64_t sf_audio_ring_overruns(const SFAudioRing *ring);
#ifdef __cplusplus
}
#endif
