#include "AudioOutput.h"
#include "AudioRing.h"
#include "AudioFormat.h"
#include "AudioSpatialOutput.h"
#include "AudioQueuePolicy.h"
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <CoreAudio/CoreAudio.h>
#endif
#include <opus/opus_multistream.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#define MAX_OPUS_FRAMES 5760
#define MAX_RENDER_FRAMES 4096
struct SFAudioOutput {
    AudioUnit unit;
    SFAudioSpatialOutput *spatial;
    OpusMSDecoder *decoder;
    SFAudioRing *ring;
    float *decode_buffer, *render_buffer;
    uint32_t channels, output_channels, packet_frames;
    // Unit lifecycle and route changes are serialized here; never used by render.
    dispatch_queue_t control_queue;
    bool started, retiring;
    // Serializes producer publication with route flush/stop; render never locks.
    pthread_mutex_t producer_mutex;
    _Atomic bool running;
    void (*failure)(void *, int);
    void *failure_context;
#if TARGET_OS_OSX
    AudioObjectPropertyListenerBlock route_listener;
    AudioDeviceID observed_device;
    bool system_listener;
#endif
};
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                       AudioBufferList *buffers) {
    (void)flags; (void)time; (void)bus;
    SFAudioOutput *o = context;
    if (buffers->mNumberBuffers != 1 || !buffers->mBuffers[0].mData ||
        buffers->mBuffers[0].mDataByteSize < (uint64_t)frames * o->output_channels * sizeof(float) ||
        frames > MAX_RENDER_FRAMES) {
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
            if (buffers->mBuffers[i].mData) memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
        return noErr;
    }
    if (o->output_channels == o->channels) {
        sf_audio_ring_read(o->ring, buffers->mBuffers[0].mData, frames);
    } else {
        sf_audio_ring_read(o->ring, o->render_buffer, frames);
        sf_audio_downmix(o->render_buffer, buffers->mBuffers[0].mData, frames, o->channels, o->output_channels);
    }
    return noErr;
}
static void dispose_unit(SFAudioOutput *o) {
    if (o->unit) {
        AudioOutputUnitStop(o->unit);
        AudioUnitUninitialize(o->unit);
        AudioComponentInstanceDispose(o->unit);
        o->unit = NULL;
    }
}
static OSStatus configure_unit(SFAudioOutput *o) {
    o->output_channels = o->channels;
#if TARGET_OS_OSX
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress device_property = { kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress streams_property = { kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &device_property, 0, NULL, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) return status ? status : kAudioHardwareBadDeviceError;
    status = AudioObjectGetPropertyDataSize(device, &streams_property, 0, NULL, &size);
    if (status != noErr) return status;
    AudioBufferList *streams = calloc(1, size);
    if (!streams) return memFullErr;
    status = AudioObjectGetPropertyData(device, &streams_property, 0, NULL, &size, streams);
    uint32_t physical_channels = 0;
    if (status == noErr) for (UInt32 i = 0; i < streams->mNumberBuffers; ++i)
        physical_channels += streams->mBuffers[i].mNumberChannels;
    free(streams);
    if (status != noErr || !physical_channels) return status ? status : kAudioHardwareBadDeviceError;
    if (physical_channels < o->channels)
        o->output_channels = physical_channels >= 6 ? 6 : physical_channels >= 2 ? 2 : 1;
#endif
    AudioComponentDescription desc = { .componentType = kAudioUnitType_Output,
#if TARGET_OS_OSX
        .componentSubType = kAudioUnitSubType_DefaultOutput,
#else
        .componentSubType = kAudioUnitSubType_RemoteIO,
#endif
        .componentManufacturer = kAudioUnitManufacturer_Apple };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    OSStatus unit_status = component ? AudioComponentInstanceNew(component, &o->unit) : -1;
    if (unit_status != noErr) return unit_status;
    AudioStreamBasicDescription format = sf_audio_pcm_format(o->output_channels);
    unit_status = AudioUnitSetProperty(o->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (unit_status != noErr) return unit_status;
    AudioChannelLayout layout;
    sf_audio_channel_layout(o->output_channels, &layout);
    unit_status = AudioUnitSetProperty(o->unit, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, &layout, sizeof(layout));
    if (unit_status != noErr) return unit_status;
    UInt32 maximum = MAX_RENDER_FRAMES;
    unit_status = AudioUnitSetProperty(o->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                      &maximum, sizeof(maximum));
    if (unit_status != noErr) return unit_status;
    AURenderCallbackStruct callback = { .inputProc = render, .inputProcRefCon = o };
    unit_status = AudioUnitSetProperty(o->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (unit_status != noErr) return unit_status;
    return AudioUnitInitialize(o->unit);
}
#if TARGET_OS_OSX
static const AudioObjectPropertyAddress default_device_property = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
static const AudioObjectPropertyAddress device_properties[] = {
    { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain }
};
static void observe_current_device(SFAudioOutput *o) {
    if (o->observed_device != kAudioObjectUnknown) {
        for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); ++i)
            AudioObjectRemovePropertyListenerBlock(o->observed_device, &device_properties[i], o->control_queue, o->route_listener);
    }
    o->observed_device = kAudioObjectUnknown;
    UInt32 size = sizeof(o->observed_device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &default_device_property, 0, NULL, &size, &o->observed_device) == noErr &&
        o->observed_device != kAudioObjectUnknown) {
        for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); ++i)
            AudioObjectAddPropertyListenerBlock(o->observed_device, &device_properties[i], o->control_queue, o->route_listener);
    }
}
static void route_changed(SFAudioOutput *o) {
    if (o->retiring) return;
    observe_current_device(o);
    pthread_mutex_lock(&o->producer_mutex);
    atomic_store_explicit(&o->running, false, memory_order_release);
    // Stop/dispose joins the old render callback before a new consumer touches the ring.
    // Opus remains on its existing producer worker, preserving codec state across routes.
    if (o->spatial) sf_audio_spatial_flush(o->spatial);
    else dispose_unit(o);
    sf_audio_ring_discard_queued(o->ring);
    OSStatus status = o->spatial ? noErr : configure_unit(o);
    if (status == noErr && o->started && !o->spatial) status = AudioOutputUnitStart(o->unit);
    atomic_store_explicit(&o->running, status == noErr && o->started, memory_order_release);
    pthread_mutex_unlock(&o->producer_mutex);
    if (status != noErr && o->failure) o->failure(o->failure_context, (int)status);
}
#endif
SFAudioOutput *sf_audio_create(const OPUS_MULTISTREAM_CONFIGURATION *c, bool spatial_audio, int *error,
                             void (*failure)(void *, int), void *context) {
    *error = -1;
    if (!c || c->sampleRate != 48000 || (c->channelCount != 2 && c->channelCount != 6 && c->channelCount != 8) ||
        c->samplesPerFrame <= 0 || (uint32_t)c->samplesPerFrame > SF_AUDIO_CAPACITY_FRAMES) return NULL;
    SFAudioOutput *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    pthread_mutex_init(&o->producer_mutex, NULL);
    o->channels = (uint32_t)c->channelCount; o->packet_frames = (uint32_t)c->samplesPerFrame;
    o->failure = failure; o->failure_context = context;
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_autorelease_frequency(
        DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    o->control_queue = dispatch_queue_create("net.swiftlight.audio.control", attributes);
    o->ring = sf_audio_ring_create(SF_AUDIO_CAPACITY_FRAMES, o->channels);
    o->decode_buffer = calloc((size_t)MAX_OPUS_FRAMES * o->channels, sizeof(float));
    o->render_buffer = calloc((size_t)MAX_RENDER_FRAMES * o->channels, sizeof(float));
    o->decoder = opus_multistream_decoder_create(c->sampleRate, c->channelCount, c->streams,
                                                c->coupledStreams, c->mapping, error);
    if (!o->control_queue || !o->ring || !o->decode_buffer || !o->render_buffer || !o->decoder) {
        if (*error == OPUS_OK) *error = OPUS_ALLOC_FAIL;
        sf_audio_destroy(o); return NULL;
    }
    __block OSStatus status = noErr;
    dispatch_sync(o->control_queue, ^{
        if (spatial_audio) {
            int spatial_error = 0;
            o->spatial = sf_audio_spatial_create(o->ring, o->channels, o->packet_frames, o->control_queue,
                                               &spatial_error, failure, context);
            status = o->spatial ? noErr : spatial_error;
        } else status = configure_unit(o);
    });
    if (status != noErr) { *error = (int)status; sf_audio_destroy(o); return NULL; }
#if TARGET_OS_OSX
    // AVSampleBufferAudioRenderer follows the default route and delivers its
    // own flush/configuration notifications. Duplicate Core Audio callbacks
    // would also react to spatial graph setup and repeatedly restart it.
    if (!o->spatial) {
        o->route_listener = Block_copy(^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
            (void)count; (void)addresses; route_changed(o);
        });
        status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &default_device_property, o->control_queue, o->route_listener);
        if (status != noErr) { *error = (int)status; sf_audio_destroy(o); return NULL; }
        o->system_listener = true;
        dispatch_sync(o->control_queue, ^{ observe_current_device(o); });
    }
#endif
    *error = 0; return o;
}
int sf_audio_start(SFAudioOutput *o) {
    if (!o) return -1;
    __block OSStatus status;
    dispatch_sync(o->control_queue, ^{
        o->started = true;
        pthread_mutex_lock(&o->producer_mutex);
        status = o->spatial ? sf_audio_spatial_start(o->spatial) : AudioOutputUnitStart(o->unit);
        atomic_store_explicit(&o->running, status == noErr, memory_order_release);
        pthread_mutex_unlock(&o->producer_mutex);
    });
    return (int)status;
}
void sf_audio_stop(SFAudioOutput *o) {
    if (!o || !o->control_queue) return;
    dispatch_sync(o->control_queue, ^{
        o->started = false;
        pthread_mutex_lock(&o->producer_mutex);
        atomic_store_explicit(&o->running, false, memory_order_release);
        if (o->spatial) sf_audio_spatial_stop(o->spatial);
        else if (o->unit) AudioOutputUnitStop(o->unit);
        sf_audio_ring_discard_queued(o->ring);
        pthread_mutex_unlock(&o->producer_mutex);
    });
}
void sf_audio_destroy(SFAudioOutput *o) {
    if (!o) return;
    if (o->control_queue) {
        dispatch_sync(o->control_queue, ^{
            o->retiring = true; o->started = false;
            atomic_store_explicit(&o->running, false, memory_order_release);
#if TARGET_OS_OSX
            if (o->system_listener)
                AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &default_device_property, o->control_queue, o->route_listener);
            if (o->observed_device != kAudioObjectUnknown && o->route_listener)
                for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); ++i)
                    AudioObjectRemovePropertyListenerBlock(o->observed_device, &device_properties[i], o->control_queue, o->route_listener);
#endif
            dispose_unit(o);
            if (o->spatial) { sf_audio_spatial_destroy(o->spatial); o->spatial = NULL; }
        });
        // Drain already-enqueued notifications after removal; retiring makes them no-ops.
        dispatch_sync(o->control_queue, ^{});
#if TARGET_OS_OSX
        if (o->route_listener) Block_release(o->route_listener);
#endif
        dispatch_release(o->control_queue);
    }
    if (o->decoder) opus_multistream_decoder_destroy(o->decoder);
    pthread_mutex_destroy(&o->producer_mutex);
    sf_audio_ring_destroy(o->ring); free(o->decode_buffer); free(o->render_buffer); free(o);
}
void sf_audio_decode(SFAudioOutput *o, const unsigned char *data, int length) {
    if (!o || length < 0) return;
    // Decode through route transitions so a later packet retains the correct Opus state.
    // NULL/zero is common-c's packet-loss indication; Opus performs PLC.
    int frames = opus_multistream_decode_float(o->decoder, data, length, o->decode_buffer, (int)o->packet_frames, 0);
    if (frames > 0) {
        pthread_mutex_lock(&o->producer_mutex);
        if (atomic_load_explicit(&o->running, memory_order_acquire) &&
            sf_audio_ring_write(o->ring, o->decode_buffer, (uint32_t)frames) && o->spatial)
            sf_audio_spatial_notify(o->spatial);
        pthread_mutex_unlock(&o->producer_mutex);
    }
}
void sf_audio_stats(SFAudioOutput *o, uint64_t *queued, uint64_t *underrun, uint64_t *overrun) {
    *queued = o ? sf_audio_ring_queued(o->ring) : 0;
    *underrun = o ? sf_audio_ring_underruns(o->ring) : 0;
    *overrun = o ? sf_audio_ring_overruns(o->ring) : 0;
    if (o && o->spatial) {
        uint64_t pending, gaps, dropped;
        sf_audio_spatial_stats(o->spatial, &pending, &gaps, &dropped);
        *queued += pending; *underrun += gaps; *overrun += dropped;
    }
}
bool sf_audio_playback_running(SFAudioOutput *o) {
    return o && (o->spatial ? sf_audio_spatial_playback_running(o->spatial) : atomic_load(&o->running));
}
