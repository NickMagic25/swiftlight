#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#include "AudioSpatialOutput.h"
#include "AudioFormat.h"
#include "AudioQueuePolicy.h"
#include <stdatomic.h>
#include <os/log.h>
#include <math.h>

static uint64_t host_time_ns(void) {
    return (uint64_t)CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()),
        1000000000, kCMTimeRoundingMethod_RoundTowardZero).value;
}
static int64_t current_frame(AVSampleBufferRenderSynchronizer *synchronizer) {
    CMTime time = [synchronizer currentTime];
    return CMTIME_IS_NUMERIC(time)
        ? CMTimeConvertScale(time, 48000, kCMTimeRoundingMethod_RoundTowardPositiveInfinity).value : 0;
}
static bool audio_property(AudioObjectID object, AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope, void *value, UInt32 size) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value) == noErr;
}
static uint32_t route_floor_frames(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    Float64 rate = 0;
    if (!audio_property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal, &device, sizeof(device)) ||
        !audio_property(device, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate)) || !isfinite(rate) || rate <= 0)
        return SF_AUDIO_SPATIAL_TARGET_FRAMES;
    UInt32 latency = 0, safety = 0, buffer = 0, streamLatency = 0;
    audio_property(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &latency, sizeof(latency));
    audio_property(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety, sizeof(safety));
    audio_property(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buffer, sizeof(buffer));
    AudioStreamID streams[64]; UInt32 size = sizeof(streams);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, streams) == noErr) {
        for (UInt32 i = 0; i < size / sizeof(*streams); ++i) {
            UInt32 value = 0;
            if (audio_property(streams[i], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &value, sizeof(value)))
                streamLatency = MAX(streamLatency, value);
        }
    }
    // A public route-latency floor, not a claim to measure AVFoundation's DSP.
    // Apple's prerecorded-media preroll flag remains diagnostic: the measured
    // threshold exceeds our entire real-time queue bound.
    uint64_t frames = (uint64_t)ceil(((double)latency + safety + buffer + streamLatency) * 48000 / rate);
    return sf_audio_spatial_route_floor(frames);
}
static double mapped_host_delta(CMTimebaseRef timebase, int64_t frame, uint64_t host) {
    CMTime mapped = CMSyncConvertTime(CMTimeMake(frame, 48000), timebase, CMClockGetHostTimeClock());
    return CMTIME_IS_NUMERIC(mapped) ? CMTimeGetSeconds(mapped) * 1000 - (double)host / NSEC_PER_MSEC : NAN;
}

@interface SFSpatialAudio : NSObject {
@public
    SFAudioRing *ring;
    uint32_t channels;
    dispatch_queue_t queue;
    dispatch_source_t wake, timer;
    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    CMAudioFormatDescriptionRef format;
    id flushObserver, configurationObserver;
    float *pcm;
    bool started, retiring, failed, rebuildAttempted, replacementPending;
    SFAudioSpatialPhase phase;
    int64_t nextFrame;
    uint32_t routeFloorFrames, targetFrames;
    uint64_t rendererGeneration, transitionHostNs, firstPrerollHostNs;
    uint64_t lastStateLogNs, enqueuedBuffers, pcmFrames, nonzeroSamples;
    float peak;
    SFAudioRecoveryWindow recovery;
    SFAudioClockProgress clockProgress;
    SFAudioQueueProgress queueProgress;
    SFAudioSubmittedQueue submitted;
    _Atomic uint64_t pendingFrames, underrunFrames, overrunFrames;
    _Atomic bool playbackRunning;
    void (*failure)(void *, int);
    void *failureContext;
}
- (void)pump;
- (void)flush;
- (void)reset;
- (void)fail:(int)error;
- (void)recoverOrFail:(int)error;
- (bool)buildRenderer;
- (void)discardRenderer;
- (void)removeObservers;
- (void)retire;
@end

@implementation SFSpatialAudio
- (void)removeObservers {
    ++rendererGeneration;
    if (flushObserver) [[NSNotificationCenter defaultCenter] removeObserver:flushObserver];
    if (configurationObserver) [[NSNotificationCenter defaultCenter] removeObserver:configurationObserver];
    [flushObserver release]; flushObserver = nil;
    [configurationObserver release]; configurationObserver = nil;
}
- (void)discardRenderer {
    [self removeObservers];
    [synchronizer setRate:0 time:kCMTimeInvalid];
    [renderer flush];
    if (renderer && synchronizer) [synchronizer removeRenderer:renderer atTime:kCMTimeInvalid completionHandler:nil];
    [renderer release]; renderer = nil;
    [synchronizer release]; synchronizer = nil;
}
- (bool)buildRenderer {
    renderer = [[AVSampleBufferAudioRenderer alloc] init];
    synchronizer = [[AVSampleBufferRenderSynchronizer alloc] init];
    if (!renderer || !synchronizer) { [self discardRenderer]; return false; }
    renderer.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMultichannel;
    renderer.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmVarispeed;
    synchronizer.delaysRateChangeUntilHasSufficientMediaData = NO;
    [synchronizer addRenderer:renderer];
    uint64_t generation = ++rendererGeneration;
    SFSpatialAudio *audio = self;
    void (^routeFlush)(NSNotification *) = ^(NSNotification *notification) {
        dispatch_async(queue, ^{
            if (!audio->retiring && audio->rendererGeneration == generation && audio->started) {
                os_log(OS_LOG_DEFAULT, "Swiftlight spatial recovery: %{public}@, generation=%{public}llu",
                    notification.name, (unsigned long long)generation);
                [audio flush];
            }
        });
    };
    flushObserver = [[[NSNotificationCenter defaultCenter]
        addObserverForName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
        object:renderer queue:nil usingBlock:routeFlush] retain];
    configurationObserver = [[[NSNotificationCenter defaultCenter]
        addObserverForName:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification
        object:renderer queue:nil usingBlock:routeFlush] retain];
    return true;
}
- (void)reset {
    [synchronizer setRate:0 time:kCMTimeZero];
    [renderer flush];
    sf_audio_ring_discard_queued(ring);
    submitted = (SFAudioSubmittedQueue){0};
    queueProgress = (SFAudioQueueProgress){0}; recovery = (SFAudioRecoveryWindow){0};
    nextFrame = 0; phase = SF_AUDIO_PAUSING;
    transitionHostNs = host_time_ns(); firstPrerollHostNs = 0;
    atomic_store(&pendingFrames, 0);
    atomic_store(&playbackRunning, false);
}
- (void)flush {
    // A normal pause preserves the epoch and does not itself trigger automatic
    // flush. Coalesce notification bursts before discarding and priming once.
    if (synchronizer.rate != 0) [synchronizer setRate:0 time:kCMTimeInvalid];
    atomic_store(&playbackRunning, false);
    if (phase == SF_AUDIO_RUNNING) recovery = (SFAudioRecoveryWindow){0};
    if (phase != SF_AUDIO_PAUSING) transitionHostNs = host_time_ns();
    sf_audio_spatial_request_recovery(&recovery, host_time_ns());
    phase = SF_AUDIO_PAUSING;
}
- (void)fail:(int)error {
    if (failed || retiring) return;
    failed = true; started = false;
    [self reset];
    if (failure) failure(failureContext, error ? error : -1);
}
- (void)recoverOrFail:(int)error {
    // Exactly one replacement per stream. Never rebuild for an ordinary input
    // gap, or repeatedly spin up hardware when a route cannot meet the bound.
    if (rebuildAttempted) { [self fail:error]; return; }
    rebuildAttempted = true;
    atomic_store(&playbackRunning, false);
    os_log(OS_LOG_DEFAULT, "Swiftlight spatial rebuilding renderer after bounded recovery failure: %{public}d", error);
    [self removeObservers];
    uint64_t generation = rendererGeneration;
    AVSampleBufferAudioRenderer *oldRenderer = renderer;
    AVSampleBufferRenderSynchronizer *oldSynchronizer = synchronizer;
    renderer = nil; synchronizer = nil;
    replacementPending = true; transitionHostNs = host_time_ns();
    [oldSynchronizer setRate:0 time:kCMTimeInvalid];
    [oldRenderer flush];
    [oldSynchronizer removeRenderer:oldRenderer atTime:kCMTimeInvalid completionHandler:^(BOOL removed) {
        dispatch_async(queue, ^{
            [oldRenderer release]; [oldSynchronizer release];
            if (retiring || !started || rendererGeneration != generation) return;
            replacementPending = false;
            if (!removed || ![self buildRenderer]) { [self fail:error]; return; }
            [self reset];
        });
    }];
}
- (void)pump {
    @autoreleasepool {
        if (!started || retiring || failed) return;
        if (replacementPending) {
            if (host_time_ns() - transitionHostNs > SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS) [self fail:-2007];
            return;
        }
        if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [self recoverOrFail:(int)renderer.error.code]; return;
        }
        uint64_t hostNow = host_time_ns();
        int64_t now = current_frame(synchronizer);
        double syncRate = CMTimebaseGetEffectiveRate(synchronizer.timebase);
        double rendererRate = CMTimebaseGetEffectiveRate(renderer.timebase);
        uint32_t queued = sf_audio_ring_queued(ring);
        if (phase != SF_AUDIO_RUNNING && recovery.generation &&
            hostNow - recovery.incident_ns > SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS) {
            [self recoverOrFail:-2008]; return;
        }
        if (!lastStateLogNs || hostNow - lastStateLogNs >= 5 * NSEC_PER_SEC) {
            os_log(OS_LOG_DEFAULT, "Swiftlight spatial state: phase=%{public}d rate=%{public}.2f sync_rate=%{public}.2f renderer_rate=%{public}.2f time_ms=%{public}.3f ring=%{public}u submitted=%{public}llu target_ms=%{public}.1f ready=%{public}d sufficient=%{public}d muted=%{public}d volume=%{public}.2f status=%{public}ld buffers=%{public}llu pcm_frames=%{public}llu nonzero=%{public}llu peak=%{public}.4f sync_lead_ms=%{public}.3f renderer_lead_ms=%{public}.3f",
                phase, (double)synchronizer.rate, syncRate, rendererRate, (double)now / 48, queued,
                (unsigned long long)sf_audio_submitted_frames(&submitted, now), (double)targetFrames / 48,
                renderer.readyForMoreMediaData, renderer.hasSufficientMediaDataForReliablePlaybackStart,
                renderer.muted, (double)renderer.volume, (long)renderer.status, (unsigned long long)enqueuedBuffers,
                (unsigned long long)pcmFrames, (unsigned long long)nonzeroSamples, (double)peak,
                mapped_host_delta(synchronizer.timebase, nextFrame, hostNow), mapped_host_delta(renderer.timebase, nextFrame, hostNow));
            lastStateLogNs = hostNow;
        }
        if (sf_audio_queue_stalled(&queueProgress, hostNow, queued)) {
            atomic_fetch_add(&overrunFrames, queued);
            sf_audio_ring_discard_queued(ring);
            queueProgress = (SFAudioQueueProgress){0};
        }
        atomic_store(&pendingFrames, sf_audio_submitted_frames(&submitted, now));
        SFAudioSpatialPhase acknowledged = sf_audio_spatial_acknowledge(phase, syncRate, rendererRate);
        if (phase == SF_AUDIO_PAUSING) {
            if (hostNow - transitionHostNs > SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS) {
                [self recoverOrFail:-2001]; return;
            }
            if (acknowledged != SF_AUDIO_PRIMING || (recovery.pending && !sf_audio_spatial_recovery_due(&recovery, hostNow))) return;
            [renderer flush];
            sf_audio_ring_discard_queued(ring);
            queueProgress = (SFAudioQueueProgress){0}; submitted = (SFAudioSubmittedQueue){0};
            recovery.pending = false; firstPrerollHostNs = pcmFrames ? hostNow : 0;
            nextFrame = current_frame(synchronizer);
            routeFloorFrames = route_floor_frames(); targetFrames = routeFloorFrames;
            if (!routeFloorFrames) { [self fail:-2002]; return; }
            phase = SF_AUDIO_PRIMING;
            atomic_store(&pendingFrames, 0);
            os_log(OS_LOG_DEFAULT, "Swiftlight spatial preroll: route_floor_ms=%{public}.1f generation=%{public}llu", (double)routeFloorFrames / 48, (unsigned long long)rendererGeneration);
            return;
        }
        if (phase == SF_AUDIO_RESUMING) {
            if (acknowledged == SF_AUDIO_RUNNING) {
                phase = SF_AUDIO_RUNNING; recovery = (SFAudioRecoveryWindow){0};
                atomic_store(&playbackRunning, true);
                clockProgress = (SFAudioClockProgress){now, hostNow}; return;
            }
            if (hostNow - transitionHostNs > SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS) [self recoverOrFail:-2003];
            return;
        }
        if (phase == SF_AUDIO_RUNNING && (synchronizer.rate == 0 || syncRate == 0 || rendererRate == 0)) {
            [self flush]; return;
        }
        if (phase == SF_AUDIO_RUNNING && sf_audio_spatial_clock_stalled(&clockProgress, now, hostNow,
                sf_audio_submitted_frames(&submitted, now))) {
            [self recoverOrFail:-2009]; return;
        }
        if (phase == SF_AUDIO_RUNNING && now > nextFrame) {
            atomic_fetch_add(&underrunFrames, (uint64_t)(now - nextFrame));
            [self flush]; return;
        }
        if (phase == SF_AUDIO_PRIMING && firstPrerollHostNs && hostNow - firstPrerollHostNs > SF_AUDIO_SPATIAL_TRANSITION_TIMEOUT_NS) {
            [self recoverOrFail:-2004]; return;
        }
        // Apple's ready flag is advisory for non-real-time sources. A paused
        // renderer may say NO before our route floor; bounded preroll must still
        // be allowed to reach that floor instead of deadlocking on readiness.
        while (phase == SF_AUDIO_PRIMING || renderer.readyForMoreMediaData) {
            now = current_frame(synchronizer);
            uint64_t pending = sf_audio_submitted_frames(&submitted, now);
            if (phase == SF_AUDIO_PRIMING && sf_audio_spatial_preroll_ready(pending, routeFloorFrames)) {
                targetFrames = sf_audio_spatial_running_target(pending);
                phase = SF_AUDIO_RESUMING; transitionHostNs = host_time_ns();
                [synchronizer setRate:1 time:kCMTimeInvalid];
                os_log(OS_LOG_DEFAULT, "Swiftlight spatial resume: preroll_ms=%{public}.1f target_ms=%{public}.1f generation=%{public}llu",
                    (double)pending / 48, (double)targetFrames / 48, (unsigned long long)rendererGeneration);
                break;
            }
            if (phase == SF_AUDIO_PRIMING && pending >= SF_AUDIO_SPATIAL_MAX_TARGET_FRAMES) {
                [self recoverOrFail:-2005]; return;
            }
            uint32_t available = sf_audio_ring_queued(ring);
            uint64_t feedHost = host_time_ns();
            if (phase == SF_AUDIO_PRIMING && !firstPrerollHostNs && available) firstPrerollHostNs = feedHost;
            bool fillSilence = true;
            uint32_t limit = targetFrames;
            if (phase == SF_AUDIO_PRIMING) {
                limit = SF_AUDIO_SPATIAL_MAX_TARGET_FRAMES;
                // Begin with real PCM, including legitimately all-zero PCM.
                // Pad network/DTX gaps only at real-time pace after input began.
                if (!firstPrerollHostNs) break;
                if (!pending && available < SF_AUDIO_SPATIAL_BATCH_FRAMES && feedHost - firstPrerollHostNs < SF_AUDIO_SPATIAL_BATCH_NS) break;
                fillSilence = feedHost - firstPrerollHostNs >= pending * 1000000000ull / 48000;
            }
            uint32_t count = sf_audio_spatial_chunk_frames((int64_t)pending, available, fillSilence, limit);
            if (!count) break;
            uint32_t realFrames = sf_audio_ring_read(ring, pcm, count);
            pcmFrames += realFrames;
            for (uint32_t i = 0; i < realFrames * channels; ++i) {
                if (pcm[i] != 0) ++nonzeroSamples;
                peak = fmaxf(peak, fabsf(pcm[i]));
            }
            CMSampleBufferRef sample = NULL;
            OSStatus status = sf_audio_sample_buffer(format, pcm, count, nextFrame, &sample);
            if (status != noErr) { [self fail:(int)status]; return; }
            int64_t sampleFrame = nextFrame;
            [renderer enqueueSampleBuffer:sample]; ++enqueuedBuffers; CFRelease(sample);
            uint64_t enqueueFinished = host_time_ns();
            sf_audio_queue_did_consume(&queueProgress, enqueueFinished);
            if (enqueueFinished - feedHost > SF_AUDIO_STALL_LIMIT_NS) {
                atomic_fetch_add(&overrunFrames, sf_audio_ring_queued(ring));
                sf_audio_ring_discard_queued(ring);
            }
            nextFrame = sampleFrame + count;
            now = current_frame(synchronizer);
            if (!sf_audio_submitted_add(&submitted, sampleFrame, count, now)) { [self fail:-2006]; return; }
            if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                [self recoverOrFail:(int)renderer.error.code]; return;
            }
        }
        atomic_store(&pendingFrames, sf_audio_submitted_frames(&submitted, current_frame(synchronizer)));
    }
}
- (void)retire {
    retiring = true; started = false;
    if (wake) { dispatch_source_cancel(wake); dispatch_release(wake); wake = NULL; }
    if (timer) { dispatch_source_cancel(timer); dispatch_release(timer); timer = NULL; }
    [self discardRenderer];
    sf_audio_ring_discard_queued(ring);
    atomic_store(&pendingFrames, 0);
    atomic_store(&playbackRunning, false);
}
- (void)dealloc {
    if (format) CFRelease(format);
    free(pcm);
    if (queue) dispatch_release(queue);
    [super dealloc];
}
@end

SFAudioSpatialOutput *sf_audio_spatial_create(SFAudioRing *ring, uint32_t channels, uint32_t packet_frames,
    dispatch_queue_t queue, int *error, void (*failure)(void *, int), void *context) {
    @autoreleasepool {
        SFSpatialAudio *audio = [[SFSpatialAudio alloc] init];
        if (!audio) { *error = -1; return NULL; }
        audio->ring = ring; audio->channels = channels;
        audio->queue = queue; dispatch_retain(queue);
        audio->failure = failure; audio->failureContext = context;
        audio->pcm = calloc((size_t)MAX(packet_frames, SF_AUDIO_SPATIAL_BATCH_FRAMES) * channels, sizeof(float));
        OSStatus status = sf_audio_format_description(channels, &audio->format);
        if (!audio->pcm || status != noErr) { *error = status ? (int)status : -1; [audio release]; return NULL; }
        if (![audio buildRenderer]) { *error = -1; [audio release]; return NULL; }
        audio->wake = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, queue);
        audio->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        if (!audio->wake || !audio->timer) {
            if (audio->wake) { dispatch_resume(audio->wake); dispatch_source_cancel(audio->wake); dispatch_release(audio->wake); }
            if (audio->timer) { dispatch_resume(audio->timer); dispatch_source_cancel(audio->timer); dispatch_release(audio->timer); }
            [audio discardRenderer]; *error = -1; [audio release]; return NULL;
        }
        dispatch_source_set_event_handler(audio->wake, ^{ [audio pump]; });
        dispatch_source_set_event_handler(audio->timer, ^{ [audio pump]; });
        dispatch_source_set_timer(audio->timer, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_MSEC),
                                  4 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_resume(audio->wake); dispatch_resume(audio->timer);
        *error = 0;
        return (SFAudioSpatialOutput *)audio;
    }
}
int sf_audio_spatial_start(SFAudioSpatialOutput *output) {
    SFSpatialAudio *audio = (SFSpatialAudio *)output;
    if (audio->retiring || audio->failed) return -1;
    [audio reset]; audio->rebuildAttempted = false; audio->started = true;
    return 0;
}
void sf_audio_spatial_stop(SFAudioSpatialOutput *output) {
    SFSpatialAudio *audio = (SFSpatialAudio *)output;
    audio->started = false; [audio reset];
}
void sf_audio_spatial_flush(SFAudioSpatialOutput *output) { [(SFSpatialAudio *)output flush]; }
void sf_audio_spatial_destroy(SFAudioSpatialOutput *output) {
    SFSpatialAudio *audio = (SFSpatialAudio *)output;
    [audio retire]; [audio release];
}
void sf_audio_spatial_notify(SFAudioSpatialOutput *output) {
    SFSpatialAudio *audio = (SFSpatialAudio *)output;
    dispatch_source_merge_data(audio->wake, 1);
}
void sf_audio_spatial_stats(SFAudioSpatialOutput *output, uint64_t *queued, uint64_t *underrun, uint64_t *overrun) {
    SFSpatialAudio *audio = (SFSpatialAudio *)output;
    *queued = atomic_load(&audio->pendingFrames);
    *underrun = atomic_load(&audio->underrunFrames);
    *overrun = atomic_load(&audio->overrunFrames);
}
bool sf_audio_spatial_playback_running(SFAudioSpatialOutput *output) {
    return atomic_load(&((SFSpatialAudio *)output)->playbackRunning);
}
