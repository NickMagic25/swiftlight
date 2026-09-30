#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <stdbool.h>
#include <stdint.h>

// common-c's decoded PCM is Windows speaker order, after its negotiated Opus map.
// 7.1 is L R C LFE rear-L rear-R side-L side-R; MPEG_7_1_A is NOT this layout.
bool sf_audio_channel_layout(uint32_t channels, AudioChannelLayout *layout);
AudioStreamBasicDescription sf_audio_pcm_format(uint32_t channels);
OSStatus sf_audio_format_description(uint32_t channels, CMAudioFormatDescriptionRef *description);
// Copies PCM into owned CoreMedia storage; packet memory may immediately be reused.
OSStatus sf_audio_sample_buffer(CMAudioFormatDescriptionRef description, const float *pcm,
                               uint32_t frames, int64_t presentation_frame, CMSampleBufferRef *sample);
// Direct playback fallback when the physical output has fewer speaker channels.
// LFE is omitted from stereo/mono, center and surrounds are mixed with headroom.
void sf_audio_downmix(const float *input, float *output, uint32_t frames,
                      uint32_t input_channels, uint32_t output_channels);
