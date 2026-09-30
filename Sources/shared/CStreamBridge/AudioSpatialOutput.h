#pragma once
#include "AudioRing.h"
#include <dispatch/dispatch.h>

typedef struct SFAudioSpatialOutput SFAudioSpatialOutput;
// All lifecycle calls run on control_queue; notify is safe on the Opus producer.
SFAudioSpatialOutput *sf_audio_spatial_create(SFAudioRing *ring, uint32_t channels, uint32_t packet_frames,
    dispatch_queue_t control_queue, int *error, void (*failure)(void *, int), void *context);
int sf_audio_spatial_start(SFAudioSpatialOutput *output);
void sf_audio_spatial_stop(SFAudioSpatialOutput *output);
void sf_audio_spatial_flush(SFAudioSpatialOutput *output);
void sf_audio_spatial_destroy(SFAudioSpatialOutput *output);
void sf_audio_spatial_notify(SFAudioSpatialOutput *output);
void sf_audio_spatial_stats(SFAudioSpatialOutput *output, uint64_t *queued, uint64_t *underrun, uint64_t *overrun);
bool sf_audio_spatial_playback_running(SFAudioSpatialOutput *output);
