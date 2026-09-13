#include "AudioOutput.h"
#include "AudioRing.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <TargetConditionals.h>
#include <opus/opus_multistream.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define AUDIO_CAPACITY_FRAMES 2048
#define MAX_OPUS_FRAMES 5760
struct SFAudioOutput {
    AudioUnit unit;
    OpusMSDecoder *decoder;
    SFAudioRing *ring;
    float *decode_buffer;
    uint32_t channels, packet_frames;
    // Unit lifecycle and route changes are serialized here; never used by render.
    dispatch_queue_t control_queue;
    bool started, retiring;
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
        buffers->mBuffers[0].mDataByteSize < (uint64_t)frames * o->channels * sizeof(float)) {
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
            if (buffers->mBuffers[i].mData) memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
        return noErr;
    }
    sf_audio_ring_read(o->ring, buffers->mBuffers[0].mData, frames);
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
    AudioComponentDescription desc = { .componentType = kAudioUnitType_Output,
#if TARGET_OS_OSX
        .componentSubType = kAudioUnitSubType_DefaultOutput,
#else
        .componentSubType = kAudioUnitSubType_RemoteIO,
#endif
        .componentManufacturer = kAudioUnitManufacturer_Apple };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    OSStatus status = component ? AudioComponentInstanceNew(component, &o->unit) : -1;
    if (status != noErr) return status;
    AudioStreamBasicDescription format = { .mSampleRate = 48000,
        .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = o->channels * sizeof(float), .mFramesPerPacket = 1,
        .mBytesPerFrame = o->channels * sizeof(float), .mChannelsPerFrame = o->channels, .mBitsPerChannel = 32 };
    status = AudioUnitSetProperty(o->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (status != noErr) return status;
    AURenderCallbackStruct callback = { .inputProc = render, .inputProcRefCon = o };
    status = AudioUnitSetProperty(o->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (status != noErr) return status;
    return AudioUnitInitialize(o->unit);
}
#if TARGET_OS_OSX
static const AudioObjectPropertyAddress default_device_property = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
static const AudioObjectPropertyAddress device_properties[] = {
    { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
};
static void observe_current_device(SFAudioOutput *o) {
    if (o->observed_device != kAudioObjectUnknown) {
        for (unsigned i = 0; i < 2; ++i)
            AudioObjectRemovePropertyListenerBlock(o->observed_device, &device_properties[i], o->control_queue, o->route_listener);
    }
    o->observed_device = kAudioObjectUnknown;
    UInt32 size = sizeof(o->observed_device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &default_device_property, 0, NULL, &size, &o->observed_device) == noErr &&
        o->observed_device != kAudioObjectUnknown) {
        for (unsigned i = 0; i < 2; ++i)
            AudioObjectAddPropertyListenerBlock(o->observed_device, &device_properties[i], o->control_queue, o->route_listener);
    }
}
static void route_changed(SFAudioOutput *o) {
    if (o->retiring) return;
    observe_current_device(o);
    atomic_store_explicit(&o->running, false, memory_order_release);
    // Stop/dispose joins the old render callback before a new consumer touches the ring.
    // Opus remains on its existing producer worker, preserving codec state across routes.
    dispose_unit(o);
    sf_audio_ring_discard_queued(o->ring);
    OSStatus status = configure_unit(o);
    if (status == noErr && o->started) status = AudioOutputUnitStart(o->unit);
    atomic_store_explicit(&o->running, status == noErr && o->started, memory_order_release);
    if (status != noErr && o->failure) o->failure(o->failure_context, (int)status);
}
#endif
SFAudioOutput *sf_audio_create(const OPUS_MULTISTREAM_CONFIGURATION *c, int *error,
                             void (*failure)(void *, int), void *context) {
    *error = -1;
    // Only stereo is advertised; reject layouts the renderer has not implemented.
    if (!c || c->sampleRate != 48000 || c->channelCount != 2 ||
        c->samplesPerFrame <= 0 || c->samplesPerFrame > AUDIO_CAPACITY_FRAMES) return NULL;
    SFAudioOutput *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->channels = (uint32_t)c->channelCount; o->packet_frames = (uint32_t)c->samplesPerFrame;
    o->failure = failure; o->failure_context = context;
    o->control_queue = dispatch_queue_create("net.swiftlight.audio.control", DISPATCH_QUEUE_SERIAL);
    o->ring = sf_audio_ring_create(AUDIO_CAPACITY_FRAMES, o->channels);
    o->decode_buffer = calloc((size_t)MAX_OPUS_FRAMES * o->channels, sizeof(float));
    o->decoder = opus_multistream_decoder_create(c->sampleRate, c->channelCount, c->streams,
                                                c->coupledStreams, c->mapping, error);
    if (!o->control_queue || !o->ring || !o->decode_buffer || !o->decoder) { sf_audio_destroy(o); return NULL; }
    OSStatus status = configure_unit(o);
    if (status != noErr) { *error = (int)status; sf_audio_destroy(o); return NULL; }
#if TARGET_OS_OSX
    o->route_listener = Block_copy(^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses; route_changed(o);
    });
    status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &default_device_property, o->control_queue, o->route_listener);
    if (status != noErr) { *error = (int)status; sf_audio_destroy(o); return NULL; }
    o->system_listener = true;
    dispatch_sync(o->control_queue, ^{ observe_current_device(o); });
#endif
    *error = 0; return o;
}
int sf_audio_start(SFAudioOutput *o) {
    if (!o) return -1;
    __block OSStatus status;
    dispatch_sync(o->control_queue, ^{
        o->started = true;
        status = AudioOutputUnitStart(o->unit);
        atomic_store_explicit(&o->running, status == noErr, memory_order_release);
    });
    return (int)status;
}
void sf_audio_stop(SFAudioOutput *o) {
    if (!o || !o->control_queue) return;
    dispatch_sync(o->control_queue, ^{
        o->started = false;
        atomic_store_explicit(&o->running, false, memory_order_release);
        if (o->unit) AudioOutputUnitStop(o->unit);
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
                for (unsigned i = 0; i < 2; ++i)
                    AudioObjectRemovePropertyListenerBlock(o->observed_device, &device_properties[i], o->control_queue, o->route_listener);
#endif
            dispose_unit(o);
        });
        // Drain already-enqueued notifications after removal; retiring makes them no-ops.
        dispatch_sync(o->control_queue, ^{});
#if TARGET_OS_OSX
        if (o->route_listener) Block_release(o->route_listener);
#endif
        dispatch_release(o->control_queue);
    }
    if (o->decoder) opus_multistream_decoder_destroy(o->decoder);
    sf_audio_ring_destroy(o->ring); free(o->decode_buffer); free(o);
}
void sf_audio_decode(SFAudioOutput *o, const unsigned char *data, int length) {
    if (!o || length < 0) return;
    // Decode through route transitions so a later packet retains the correct Opus state.
    // NULL/zero is common-c's packet-loss indication; Opus performs PLC.
    int frames = opus_multistream_decode_float(o->decoder, data, length, o->decode_buffer, (int)o->packet_frames, 0);
    if (frames > 0 && atomic_load_explicit(&o->running, memory_order_acquire))
        sf_audio_ring_write(o->ring, o->decode_buffer, (uint32_t)frames);
}
void sf_audio_stats(SFAudioOutput *o, uint64_t *queued, uint64_t *underrun, uint64_t *overrun) {
    *queued = o ? sf_audio_ring_queued(o->ring) : 0;
    *underrun = o ? sf_audio_ring_underruns(o->ring) : 0;
    *overrun = o ? sf_audio_ring_overruns(o->ring) : 0;
}
