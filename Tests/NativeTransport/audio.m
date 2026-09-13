#import <Foundation/Foundation.h>
#include "AudioOutput.h"
#include "AudioFormat.h"
#include "AudioRing.h"
#include "AudioQueuePolicy.h"
#include <opus/opus_multistream.h>
#include <math.h>
#include <stdatomic.h>
#include <unistd.h>
#include <mach/mach_time.h>

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "audio check failed: %s:%d: %s\n", __FILE__, __LINE__, #value); exit(1); } } while (0)

static void format_tests(void) {
    SFAudioQueueProgress progress = {0};
    // A renderer that is unready on every 4ms pump must not keep stale PCM
    // indefinitely merely because its presentation timestamp keeps advancing.
    CHECK(!sf_audio_queue_stalled(&progress, 0, 240));
    for (uint64_t now = 4000000; now <= 40000000; now += 4000000)
        CHECK(!sf_audio_queue_stalled(&progress, now, 2048));
    CHECK(sf_audio_queue_stalled(&progress, 44000000, 2048));
    CHECK(!sf_audio_queue_stalled(&progress, 44000000, 0));
    CHECK(!sf_audio_queue_stalled(&progress, 90000000, 240));
    sf_audio_queue_did_consume(&progress, 120000000);
    CHECK(!sf_audio_queue_stalled(&progress, 150000000, 240));
    CHECK(sf_audio_queue_stalled(&progress, 164000000, 240));
    CHECK(sf_audio_spatial_chunk_frames(0, 240, false, 3840) == 0);
    CHECK(sf_audio_spatial_chunk_frames(0, 960, false, 3840) == 960);
    CHECK(sf_audio_spatial_chunk_frames(3839, 2048, false, 3840) == 960);
    CHECK(sf_audio_spatial_chunk_frames(3840, 2048, true, 3840) == 0);
    CHECK(sf_audio_spatial_chunk_frames(3000, 240, true, 3840) == 0);
    CHECK(sf_audio_spatial_chunk_frames(2880, 240, true, 3840) == 960);
    CHECK(sf_audio_spatial_route_floor(0) == 3840);
    CHECK(sf_audio_spatial_route_floor(7680 + 512) == 8640); // Public AirPods route:180ms rounded floor.
    CHECK(sf_audio_spatial_route_floor(24001) == 0); // Unsupported route cannot silently exceed the bound.
    CHECK(!sf_audio_spatial_preroll_ready(7680, 8640));
    CHECK(sf_audio_spatial_preroll_ready(8640, 8640));
    CHECK(sf_audio_spatial_running_target(8640) == 9600);
    CHECK(sf_audio_spatial_running_target(23040) == 23040);
    // Pausing and resuming acknowledgments are asynchronous and independent.
    CHECK(sf_audio_spatial_acknowledge(SF_AUDIO_PAUSING, 1, 1) == SF_AUDIO_PAUSING);
    CHECK(sf_audio_spatial_acknowledge(SF_AUDIO_PAUSING, 0, 1) == SF_AUDIO_PAUSING);
    CHECK(sf_audio_spatial_acknowledge(SF_AUDIO_PAUSING, 0, 0) == SF_AUDIO_PRIMING);
    CHECK(sf_audio_spatial_acknowledge(SF_AUDIO_RESUMING, 0, 0) == SF_AUDIO_RESUMING);
    CHECK(sf_audio_spatial_acknowledge(SF_AUDIO_RESUMING, 1, 0) == SF_AUDIO_RESUMING);
    CHECK(sf_audio_spatial_acknowledge(SF_AUDIO_RESUMING, 1, 1) == SF_AUDIO_RUNNING);
    SFAudioRecoveryWindow recovery = {0};
    sf_audio_spatial_request_recovery(&recovery, 1000000);
    CHECK(!sf_audio_spatial_recovery_due(&recovery, 20000000));
    sf_audio_spatial_request_recovery(&recovery, 19000000);
    CHECK(recovery.generation == 2 && recovery.incident_ns == 1000000);
    CHECK(!sf_audio_spatial_recovery_due(&recovery, 21000000));
    CHECK(sf_audio_spatial_recovery_due(&recovery, 39000000));
    for (uint64_t t = 40000000; t <= 2100000000; t += 10000000) sf_audio_spatial_request_recovery(&recovery, t);
    CHECK(recovery.incident_ns == 1000000); // A notification storm cannot restart the incident timeout.
    SFAudioClockProgress clock_progress = {48000, 1000000};
    CHECK(!sf_audio_spatial_clock_stalled(&clock_progress, 48000, 1000000000, 9600));
    CHECK(sf_audio_spatial_clock_stalled(&clock_progress, 48000, 2100000000, 9600));
    CHECK(!sf_audio_spatial_clock_stalled(&clock_progress, 48001, 2100000000, 9600));
    CHECK(!sf_audio_spatial_clock_stalled(&clock_progress, 48001, 5000000000, 0));
    SFAudioSubmittedQueue submitted = {0};
    int64_t playhead = 48000;
    // A paused clock admits enough real20ms batches even when AV's advisory
    // readyForMoreMediaData flag is false. No synthetic future gap is counted.
    for (uint32_t frames = 0; frames < SF_AUDIO_SPATIAL_SCHEDULE_FRAMES; frames += 960) {
        CHECK(sf_audio_submitted_add(&submitted, playhead + frames, 960, playhead));
        CHECK(sf_audio_submitted_frames(&submitted, playhead) == frames + 960);
    }
    CHECK(submitted.count == 25);
    CHECK(sf_audio_submitted_frames(&submitted, playhead + 480) == SF_AUDIO_SPATIAL_SCHEDULE_FRAMES - 480);
    CHECK(sf_audio_submitted_frames(&submitted, playhead + SF_AUDIO_SPATIAL_SCHEDULE_FRAMES) == 0);
    CHECK(sf_audio_submitted_add(&submitted, playhead + 50000, 960, playhead));
    CHECK(sf_audio_submitted_frames(&submitted, playhead) == 960);
    int create_error = 0;
    CHECK(sf_audio_create(NULL, false, &create_error, NULL, NULL) == NULL && create_error != 0);
    OPUS_MULTISTREAM_CONFIGURATION invalid_config = { .sampleRate = 48000, .channelCount = 4, .samplesPerFrame = 240 };
    CHECK(sf_audio_create(&invalid_config, true, &create_error, NULL, NULL) == NULL && create_error != 0);
    invalid_config.channelCount = 6; invalid_config.sampleRate = 44100;
    CHECK(sf_audio_create(&invalid_config, true, &create_error, NULL, NULL) == NULL && create_error != 0);
    const uint32_t counts[] = {2, 6, 8};
    const AudioChannelLabel labels[] = { kAudioChannelLabel_Left, kAudioChannelLabel_Right,
        kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
        kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround };
    for (unsigned c = 0; c < 3; ++c) {
        uint32_t channels = counts[c];
        SFAudioRing *ring = sf_audio_ring_create(4, channels);
        CHECK(ring);
        float ring_input[8 * 3], ring_output[8 * 5];
        for (uint32_t i = 0; i < channels * 3; ++i) ring_input[i] = (float)i + 1;
        CHECK(sf_audio_ring_write(ring, ring_input, 3));
        CHECK(sf_audio_ring_read(ring, ring_output, 2) == 2);
        CHECK(memcmp(ring_output, ring_input, 2 * channels * sizeof(float)) == 0);
        CHECK(sf_audio_ring_write(ring, ring_input, 3));
        CHECK(!sf_audio_ring_write(ring, ring_input, 3));
        CHECK(sf_audio_ring_overruns(ring) == 3);
        CHECK(sf_audio_ring_read(ring, ring_output, 5) == 4);
        CHECK(memcmp(ring_output, ring_input + 2 * channels, channels * sizeof(float)) == 0);
        CHECK(memcmp(ring_output + channels, ring_input, 3 * channels * sizeof(float)) == 0);
        for (uint32_t i = 4 * channels; i < 5 * channels; ++i) CHECK(ring_output[i] == 0);
        CHECK(sf_audio_ring_underruns(ring) == 1);
        CHECK(sf_audio_ring_write(ring, ring_input, 3)); sf_audio_ring_discard_queued(ring);
        CHECK(sf_audio_ring_queued(ring) == 0); sf_audio_ring_destroy(ring);
        AudioChannelLayout layout;
        CHECK(sf_audio_channel_layout(channels, &layout));
        UInt32 size = 0;
        CHECK(AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, sizeof(layout.mChannelLayoutTag),
                                        &layout.mChannelLayoutTag, &size) == noErr);
        AudioChannelLayout *expanded = calloc(1, size);
        CHECK(AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, sizeof(layout.mChannelLayoutTag),
                                     &layout.mChannelLayoutTag, &size, expanded) == noErr);
        CHECK(expanded->mNumberChannelDescriptions == channels);
        for (uint32_t channel = 0; channel < channels; ++channel) {
            AudioChannelLabel expected = channels == 6 && channel >= 4 ? labels[channel + 2] : labels[channel];
            CHECK(expanded->mChannelDescriptions[channel].mChannelLabel == expected);
        }
        free(expanded);
        CMAudioFormatDescriptionRef description = NULL;
        CHECK(sf_audio_format_description(channels, &description) == noErr);
        size_t layout_size = 0;
        const AudioChannelLayout *stored = CMAudioFormatDescriptionGetChannelLayout(description, &layout_size);
        CHECK(stored && layout_size >= sizeof(AudioChannelLayout));
        CHECK(stored->mChannelLayoutTag == layout.mChannelLayoutTag);
        float pcm[8 * 240], copied[8 * 240];
        for (uint32_t i = 0; i < channels * 240; ++i) pcm[i] = (float)i / 2048;
        CMSampleBufferRef sample = NULL;
        CHECK(sf_audio_sample_buffer(description, pcm, 240, 48000, &sample) == noErr);
        CHECK(CMSampleBufferGetNumSamples(sample) == 240);
        CHECK(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(1, 1)) == 0);
        CHECK(CMTimeCompare(CMSampleBufferGetDuration(sample), CMTimeMake(240, 48000)) == 0);
        memset(pcm, 0, sizeof(pcm));
        CHECK(CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(sample), 0, channels * 240 * sizeof(float), copied) == noErr);
        for (uint32_t i = 0; i < channels * 240; ++i) CHECK(copied[i] == (float)i / 2048);
        CFRelease(sample); CFRelease(description);
    }
    AudioChannelLayout invalid;
    CHECK(!sf_audio_channel_layout(4, &invalid));
    for (uint32_t channels = 6; channels <= 8; channels += 2) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
            float input[8] = {0}, stereo[2], mono[1], surround[6]; input[channel] = 1;
            sf_audio_downmix(input, stereo, 1, channels, 2);
            sf_audio_downmix(input, mono, 1, channels, 1);
            CHECK(fabsf(mono[0] - (stereo[0] + stereo[1]) * .5f) < 0.000001f);
            if (channel == 3) CHECK(stereo[0] == 0 && stereo[1] == 0);
            else if (channel == 2) CHECK(stereo[0] > 0 && stereo[0] == stereo[1]);
            else if (channel == 0 || channel == 4 || channel == 6) CHECK(stereo[0] > 0 && stereo[1] == 0);
            else CHECK(stereo[1] > 0 && stereo[0] == 0);
            if (channels == 8) {
                sf_audio_downmix(input, surround, 1, 8, 6);
                for (unsigned i = 0; i < 6; ++i) {
                    float expected = channel < 4 ? (i == channel ? 1 : 0) : (i == 4 + channel % 2 ? .5f : 0);
                    CHECK(surround[i] == expected);
                }
            }
        }
        float full[8] = {1,1,1,1,1,1,1,1}, stereo[2];
        sf_audio_downmix(full, stereo, 1, channels, 2);
        CHECK(stereo[0] <= 1.000001f && stereo[1] <= 1.000001f);
    }
}
static _Atomic int playback_error;
static void failed(void *context, int error) { (void)context; atomic_store(&playback_error, error); }
static void playback_smoke(bool spatial, int channels) {
    OPUS_MULTISTREAM_CONFIGURATION config = { .sampleRate = 48000, .channelCount = channels,
        .streams = channels, .coupledStreams = 0, .samplesPerFrame = 240 };
    for (int i = 0; i < channels; ++i) config.mapping[i] = (unsigned char)i;
    int error = 0;
    OpusMSEncoder *encoder = opus_multistream_encoder_create(48000, channels, channels, 0,
        config.mapping, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error);
    CHECK(encoder && error == OPUS_OK);
    SFAudioOutput *output = sf_audio_create(&config, spatial, &error, failed, NULL);
    if (!output) fprintf(stderr, "audio smoke setup failed: %s %d channels, error %d\n", spatial ? "system" : "direct", channels, error);
    CHECK(output && error == 0); CHECK(sf_audio_start(output) == 0);
    float pcm[240 * 8]; unsigned char packet[16384];
    uint64_t maximum_queued = 0;
    bool observed_running = false;
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    uint64_t start = mach_absolute_time();
    for (int frame = 0; frame < 600; ++frame) {
        for (int sample = 0; sample < 240; ++sample)
            for (int channel = 0; channel < channels; ++channel)
                pcm[sample * channels + channel] = channel == (frame / 20) % channels
                    ? 0.015f * sinf((float)(frame * 240 + sample) * 2 * (float)M_PI * (220 + 55 * channel) / 48000) : 0;
        int bytes = opus_multistream_encode_float(encoder, pcm, 240, packet, sizeof(packet));
        CHECK(bytes > 0);
        sf_audio_decode(output, packet, bytes);
        uint64_t queued, underrun, overrun;
        sf_audio_stats(output, &queued, &underrun, &overrun);
        observed_running |= sf_audio_playback_running(output);
        maximum_queued = MAX(maximum_queued, queued);
        CHECK(queued <= SF_AUDIO_CAPACITY_FRAMES + SF_AUDIO_SPATIAL_SCHEDULE_FRAMES);
        CHECK(atomic_load(&playback_error) == 0);
        uint64_t deadline = start + (uint64_t)(frame + 1) * 5000000 * timebase.denom / timebase.numer;
        mach_wait_until(deadline);
    }
    CHECK(observed_running);
    // The statistics should show the bounded queue emptied after stop.
    sf_audio_stop(output);
    uint64_t queued, underrun, overrun;
    sf_audio_stats(output, &queued, &underrun, &overrun);
    CHECK(queued == 0);
    CHECK(!sf_audio_playback_running(output));
    sf_audio_destroy(output); opus_multistream_encoder_destroy(encoder);
    fprintf(stderr, "audio smoke: %s %d channels, max queued %llu, underrun %llu, overrun %llu\n",
        spatial ? "system" : "direct", channels, maximum_queued, underrun, overrun);
}
int main(void) {
    @autoreleasepool {
        format_tests();
        bool smoke = getenv("SWIFTLIGHT_AUDIO_SMOKE") && strcmp(getenv("SWIFTLIGHT_AUDIO_SMOKE"), "1") == 0;
        if (smoke) for (int spatial = 0; spatial < 2; ++spatial)
            for (int i = 0; i < 3; ++i) playback_smoke(spatial, (int[]){2,6,8}[i]);
        printf("{\"status\":\"PASS\",\"audio_layouts\":[2,6,8],\"multichannel_ring_wrap\":true,\"bounded_backpressure\":true,\"downmix_channel_impulses\":true,\"pcm_ownership_timestamps\":true,\"local_playback_smoke\":%s}\n", smoke ? "true" : "false");
    }
}
