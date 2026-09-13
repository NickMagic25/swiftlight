#include "StreamBridge.h"
#include <stdlib.h>
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "CHECK failed %s:%d: %s\n", __FILE__, __LINE__, #condition); abort(); } } while (0)
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>

typedef struct { SFAudioRing *ring; unsigned count; } Stress;
static void *producer(void *context) {
    Stress *s = context;
    for (unsigned i = 1; i <= s->count; ++i) {
        float sample[2] = {(float)i, -(float)i};
        while (!sf_audio_ring_write(s->ring, sample, 1)) sched_yield();
    }
    return NULL;
}
static void *consumer(void *context) {
    Stress *s = context;
    for (unsigned i = 1; i <= s->count; ++i) {
        float sample[2];
        while (!sf_audio_ring_read(s->ring, sample, 1)) sched_yield();
        CHECK(sample[0] == (float)i && sample[1] == -(float)i);
    }
    return NULL;
}
int main(void) {
    for (unsigned scenario = 0; scenario <= 5; ++scenario) {
        unsigned completed = 0, submitted = 0;
        int result = sf_stream_validate_frame_ownership(scenario, &completed, &submitted);
        CHECK(completed == 1 && submitted == (scenario <= 1 ? 1 : 0));
        CHECK(result == (scenario == 0 ? 0 : -1));
    }
    CHECK(sf_stream_validate_keyboard_wire_codes());
    CHECK(sf_stream_validate_cancel_state_race());
    CHECK(sf_stream_validate_clock_mapping());
    CHECK(sf_stream_validate_event_retirement());
    CHECK(strstr(sf_stream_launch_query(), "&") != NULL);
    SFStreamConfiguration config = { .address = "localhost", .app_version = "7.1.431.0",
        .video_formats = 0x100, .width = 1920, .height = 1080, .fps = 60, .bitrate_kbps = 20000,
        .has_permissions = true, .permissions = 0 };
    SFStream *denied = sf_stream_create(&config, (SFStreamCallbacks){0}, NULL); CHECK(denied);
    CHECK(sf_stream_key(denied, 0x8041, true, 0) == -2);
    CHECK(sf_stream_mouse_move(denied, 1, 1) == -2);
    CHECK(sf_stream_controller(denied, 0, 1, 0, 0, 0, 0, 0, 0, 0) == -2);
    sf_stream_destroy(denied);
    config.permissions = 0x800;
    SFStream *mouse_only = sf_stream_create(&config, (SFStreamCallbacks){0}, NULL); CHECK(mouse_only);
    CHECK(sf_stream_key(mouse_only, 0x8041, true, 0) == -2);
    CHECK(sf_stream_mouse_move(mouse_only, 1, 1) == -1); // allowed class, session not started
    sf_stream_destroy(mouse_only);
    SFAudioRing *r = sf_audio_ring_create(4, 2); CHECK(r);
    float input[6] = {1,2,3,4,5,6}, out[10];
    CHECK(sf_audio_ring_write(r,input,3)); CHECK(!sf_audio_ring_write(r,input,2));
    CHECK(sf_audio_ring_overruns(r)==2); CHECK(sf_audio_ring_read(r,out,2)==2);
    CHECK(!memcmp(out,input,4*sizeof(float))); CHECK(sf_audio_ring_write(r,input,3));
    CHECK(sf_audio_ring_read(r,out,5)==4);
    float expected[10] = {5,6,1,2,3,4,5,6,0,0}; CHECK(!memcmp(out,expected,sizeof(expected)));
    CHECK(sf_audio_ring_underruns(r)==1);
    CHECK(sf_audio_ring_write(r,input,3)); sf_audio_ring_discard_queued(r);
    CHECK(sf_audio_ring_read(r,out,2)==0); CHECK(out[0]==0 && out[1]==0 && out[2]==0 && out[3]==0);
    sf_audio_ring_destroy(r);
    Stress s = {.ring = sf_audio_ring_create(128, 2), .count = 100000}; CHECK(s.ring);
    pthread_t p,c; CHECK(!pthread_create(&p,NULL,producer,&s)); CHECK(!pthread_create(&c,NULL,consumer,&s));
    pthread_join(p,NULL); pthread_join(c,NULL); CHECK(sf_audio_ring_queued(s.ring)==0); sf_audio_ring_destroy(s.ring);
    puts("{\"status\":\"PASS\",\"ownership_scenarios\":6,\"audio_ordered_frames\":100000,\"audio_ring_wrap_overflow_silence\":true,\"clock_mapping\":true,\"permission_gates\":true,\"event_retirements\":1000,\"keyboard_wire_codes\":true,\"cancel_state_phases\":20000,\"cancel_state_race_iterations\":100000}");
    return 0;
}
