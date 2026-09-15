#pragma once
#include "vendor/common-c/src/Limelight.h"
typedef struct SFAudioOutput SFAudioOutput;
SFAudioOutput *sf_audio_create(const OPUS_MULTISTREAM_CONFIGURATION *configuration, bool spatial_audio,
                             int *error, void (*failure)(void *, int), void *context);
int sf_audio_start(SFAudioOutput *output);
void sf_audio_stop(SFAudioOutput *output);
void sf_audio_destroy(SFAudioOutput *output);
void sf_audio_decode(SFAudioOutput *output, const unsigned char *packet, int length);
void sf_audio_stats(SFAudioOutput *output, uint64_t *queued, uint64_t *underrun, uint64_t *overrun);
bool sf_audio_playback_running(SFAudioOutput *output);
