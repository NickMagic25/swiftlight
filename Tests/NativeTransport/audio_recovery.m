#import <Foundation/Foundation.h>
#include <pthread.h>
#include <unistd.h>
// Include the implementation only in this test translation unit so recovery
// state can be inspected without adding production test hooks. Do not also link
// AudioSpatialOutput.m when building this executable.
#include "AudioSpatialOutput.m"

#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); abort(); } } while (0)
typedef struct { SFAudioRing *ring; SFAudioSpatialOutput *audio; pthread_t thread; _Atomic bool stop; uint64_t frame; } Feeder;
typedef struct { _Atomic int errors; _Atomic int last; } Errors;
typedef struct { bool failed, replacing, rebuilt; int phase; uint64_t generation; int64_t frame; } Snapshot;
static void audio_failed(void *context, int error) { Errors *e = context; atomic_fetch_add(&e->errors, 1); atomic_store(&e->last, error); }
static void *feed(void *context) {
    Feeder *f = context; float samples[240 * 8];
    while (!atomic_load(&f->stop)) {
        for (int i = 0; i < 240; ++i) {
            float value = 0.0001f * sinf((float)(f->frame++ % 48000) * 2 * (float)M_PI * 440 / 48000);
            for (int c = 0; c < 8; ++c) samples[i * 8 + c] = c < 2 ? value : 0;
        }
        if (sf_audio_ring_write(f->ring, samples, 240)) sf_audio_spatial_notify(f->audio);
        usleep(5000);
    }
    return NULL;
}
static Snapshot snapshot(SFSpatialAudio *a, dispatch_queue_t q) {
    __block Snapshot s;
    dispatch_sync(q, ^{ s = (Snapshot){a->failed, a->replacementPending, a->rebuildAttempted, a->phase, a->rendererGeneration,
        a->synchronizer ? current_frame(a->synchronizer) : -1}; });
    return s;
}
static void idle(double seconds) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false); }
static Snapshot await_running(SFSpatialAudio *a, dispatch_queue_t q, uint64_t after) {
    uint64_t deadline = host_time_ns() + 8000000000ull;
    Snapshot s = {0};
    while (host_time_ns() < deadline) {
        s = snapshot(a, q);
        REQUIRE(!s.failed);
        if (s.phase == SF_AUDIO_RUNNING && !s.replacing && s.generation > after) return s;
        idle(0.02);
    }
    fprintf(stderr, "timeout phase=%d generation=%llu frame=%lld\n", s.phase, s.generation, s.frame);
    REQUIRE(false); return s;
}
static SFSpatialAudio *make_audio(dispatch_queue_t q, SFAudioRing **ring, Errors *errors, Feeder *f) {
    *ring = sf_audio_ring_create(SF_AUDIO_CAPACITY_FRAMES, 8); REQUIRE(*ring);
    __block SFSpatialAudio *a = nil; __block int error = 0;
    dispatch_sync(q, ^{ a = (SFSpatialAudio *)sf_audio_spatial_create(*ring, 8, 240, q, &error, audio_failed, errors);
        REQUIRE(a && !error); REQUIRE(sf_audio_spatial_start((SFAudioSpatialOutput *)a) == 0); });
    f->ring = *ring; f->audio = (SFAudioSpatialOutput *)a;
    REQUIRE(pthread_create(&f->thread, NULL, feed, f) == 0);
    return a;
}
static void stop_feeder(Feeder *f) { atomic_store(&f->stop, true); REQUIRE(pthread_join(f->thread, NULL) == 0); }
int main(void) {
    const char *smoke = getenv("SWIFTLIGHT_AUDIO_SMOKE");
    if (!smoke || strcmp(smoke, "1") != 0) {
        puts("{\"audio_recovery_skipped\":true}");
        return 0;
    }
    @autoreleasepool {
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    dispatch_queue_t q = dispatch_queue_create("net.swiftlight.tests.audio-recovery", attr);
    SFAudioRing *ring = NULL; Errors errors = {0}; Feeder f = {0};
    SFSpatialAudio *a = make_audio(q, &ring, &errors, &f);
    Snapshot initial = await_running(a, q, 0); idle(0.15);
    Snapshot moving = snapshot(a, q); REQUIRE(moving.frame > initial.frame);
    __block AVSampleBufferAudioRenderer *old = nil;
    dispatch_sync(q, ^{
        old = [a->renderer retain];
        // These handlers are queued behind this block with the old generation.
        [[NSNotificationCenter defaultCenter] postNotificationName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:old];
        [[NSNotificationCenter defaultCenter] postNotificationName:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification object:old];
        [a recoverOrFail:-9101];
        REQUIRE(a->replacementPending);
    });
    Snapshot replacement = await_running(a, q, moving.generation);
    REQUIRE(replacement.rebuilt); idle(0.20);
    Snapshot after = snapshot(a, q); REQUIRE(after.frame > replacement.frame && !after.failed);
    dispatch_sync(q, ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:old];
        [[NSNotificationCenter defaultCenter] postNotificationName:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification object:old];
    });
    idle(0.10); Snapshot stale = snapshot(a, q);
    REQUIRE(stale.generation == after.generation && stale.phase == SF_AUDIO_RUNNING && !stale.failed);
    REQUIRE(atomic_load(&errors.errors) == 0);
    dispatch_sync(q, ^{ [a recoverOrFail:-9102]; REQUIRE(a->failed && !a->started); });
    REQUIRE(atomic_load(&errors.errors) == 1 && atomic_load(&errors.last) == -9102);
    stop_feeder(&f);
    dispatch_sync(q, ^{ sf_audio_spatial_stop((SFAudioSpatialOutput *)a); sf_audio_spatial_destroy((SFAudioSpatialOutput *)a); [old release]; });
    sf_audio_ring_destroy(ring); idle(0.20); dispatch_sync(q, ^{});
    // Continue with a separate instance to exercise teardown during replacement.

    errors = (Errors){0}; f = (Feeder){0}; a = make_audio(q, &ring, &errors, &f);
    await_running(a, q, 0); stop_feeder(&f);
    __block uint64_t retiredGeneration = 0;
    dispatch_sync(q, ^{
        [a retain];
        [a recoverOrFail:-9103]; REQUIRE(a->replacementPending);
        sf_audio_spatial_stop((SFAudioSpatialOutput *)a);
        sf_audio_spatial_destroy((SFAudioSpatialOutput *)a);
        REQUIRE(a->retiring && !a->started); retiredGeneration = a->rendererGeneration;
        // The completion handler dispatches back to this queue. Free the C
        // storage before this block ends so the ordering is deterministic.
        sf_audio_ring_destroy(ring);
    });
    idle(0.50);
    dispatch_sync(q, ^{ REQUIRE(a->retiring && !a->renderer && !a->synchronizer && a->rendererGeneration == retiredGeneration); [a release]; });
    REQUIRE(atomic_load(&errors.errors) == 0); idle(0.10); dispatch_sync(q, ^{});
    dispatch_release(q);
    puts("{\"replacement_running_and_advancing\":true,\"stale_notifications_ignored\":true,\"replacement_budget_enforced\":true,\"stop_retire_during_async_removal\":true,\"freed_ring_not_touched\":true}");
} return 0; }
