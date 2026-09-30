#include "AudioFormat.h"
#include <string.h>

bool sf_audio_channel_layout(uint32_t channels, AudioChannelLayout *layout) {
    if (!layout) return false;
    memset(layout, 0, sizeof(*layout));
    switch (channels) {
        case 1: layout->mChannelLayoutTag = kAudioChannelLayoutTag_Mono; break;
        case 2: layout->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo; break;
        case 6: layout->mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A; break;
        case 8: layout->mChannelLayoutTag = kAudioChannelLayoutTag_WAVE_7_1; break;
        default: return false;
    }
    return true;
}
AudioStreamBasicDescription sf_audio_pcm_format(uint32_t channels) {
    return (AudioStreamBasicDescription){ .mSampleRate = 48000,
        .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = channels * sizeof(float), .mFramesPerPacket = 1,
        .mBytesPerFrame = channels * sizeof(float), .mChannelsPerFrame = channels, .mBitsPerChannel = 32 };
}
OSStatus sf_audio_format_description(uint32_t channels, CMAudioFormatDescriptionRef *description) {
    AudioChannelLayout layout;
    if (!description || !sf_audio_channel_layout(channels, &layout)) return kAudio_ParamError;
    AudioStreamBasicDescription format = sf_audio_pcm_format(channels);
    return CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, sizeof(layout), &layout,
                                         0, NULL, NULL, description);
}
OSStatus sf_audio_sample_buffer(CMAudioFormatDescriptionRef description, const float *pcm,
                               uint32_t frames, int64_t presentation_frame, CMSampleBufferRef *sample) {
    if (!description || !pcm || !sample || !frames || frames > 5760 || presentation_frame < 0) return kAudio_ParamError;
    *sample = NULL;
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (!format || format->mSampleRate != 48000 || format->mChannelsPerFrame > 8) return kAudio_ParamError;
    size_t bytes = (size_t)frames * format->mBytesPerFrame;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, bytes,
        kCFAllocatorDefault, NULL, 0, bytes, 0, &block);
    if (status == noErr) status = CMBlockBufferReplaceDataBytes(pcm, block, 0, bytes);
    if (status == noErr) status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault,
        block, description, frames, CMTimeMake(presentation_frame, 48000), NULL, sample);
    if (block) CFRelease(block);
    return status;
}
void sf_audio_downmix(const float *input, float *output, uint32_t frames,
                      uint32_t input_channels, uint32_t output_channels) {
    if (input_channels == output_channels) {
        memcpy(output, input, (size_t)frames * input_channels * sizeof(float));
        return;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const float *in = input + (size_t)frame * input_channels;
        float *out = output + (size_t)frame * output_channels;
        if (input_channels == 8 && output_channels == 6) {
            memcpy(out, in, 4 * sizeof(float));
            out[4] = (in[4] + in[6]) * 0.5f;
            out[5] = (in[5] + in[7]) * 0.5f;
        } else if ((input_channels == 2 || input_channels == 6 || input_channels == 8) && output_channels <= 2) {
            float left = in[0], right = in[1];
            if (input_channels >= 6) {
                const float surround = 0.70710678f;
                float normalization = 1.0f / (1.0f + surround * (input_channels == 8 ? 3.0f : 2.0f));
                left += surround * (in[2] + in[4]); right += surround * (in[2] + in[5]);
                if (input_channels == 8) { left += surround * in[6]; right += surround * in[7]; }
                left *= normalization; right *= normalization;
            }
            out[0] = output_channels == 1 ? (left + right) * 0.5f : left;
            if (output_channels == 2) out[1] = right;
        } else {
            memset(out, 0, output_channels * sizeof(float));
        }
    }
}
