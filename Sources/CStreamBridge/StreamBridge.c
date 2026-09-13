#include "StreamBridge.h"
#include "AudioOutput.h"
#include "vendor/common-c/src/Limelight.h"
#include <arpa/inet.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <sys/socket.h>
#include <time.h>
#include <dispatch/dispatch.h>
extern uint64_t PltGetMicroseconds(void);
extern _Atomic bool ConnectionInterrupted;
extern uint64_t sf_common_clock_epoch_ns(void);
extern bool sf_common_video_local_address(struct sockaddr_storage*, socklen_t*);

#define MAX_COMPRESSED_FRAME (32u * 1024u * 1024u)
enum { CREATED, STARTING, STREAMING, STOPPING, STOPPED };
struct SFStream {
    SFStreamConfiguration configuration;
    SFStreamCallbacks callbacks;
    void *context;
    pthread_mutex_t api_mutex;
    // State is read under two independent gates, so publication is atomic.
    // api_mutex gates media/input lifetime; active_mutex gates callback identity.
    // Never acquire either gate while holding the other.
    _Atomic int state;
    _Atomic bool cancelled;
    _Atomic bool video_stopping;
    pthread_t video_thread;
    bool video_thread_created;
    uint8_t *frame_buffer;
    SFAudioOutput *audio;
    int (*send_key)(struct SFStream *, uint16_t, char, char, char);
    uint16_t held_keys[256];
    bool held_mouse[6];
    uint16_t controller_mask;
};
// common-c is process-global. Event dispatch and retirement use this gate, so an event
// already in progress completes before its Swift callback context can be released.
static pthread_mutex_t active_mutex = PTHREAD_MUTEX_INITIALIZER;
static SFStream *active_stream;
static void emit(int kind, int a, int b, int c, const char *message) {
    pthread_mutex_lock(&active_mutex);
    SFStream *s = active_stream;
    if (s && s->callbacks.event) s->callbacks.event(s->context, kind, a, b, c, message);
    if (s && atomic_load_explicit(&s->cancelled, memory_order_acquire) && atomic_load_explicit(&s->state, memory_order_acquire) == STARTING)
        LiInterruptConnection();
    pthread_mutex_unlock(&active_mutex);
}
static void stage_start(int stage) { emit(SF_STAGE, stage, 0, 0, LiGetStageName(stage)); }
static void stage_fail(int stage, int error) { emit(SF_FAILED, stage, error, 0, LiGetStageName(stage)); }
static void started(void) { emit(SF_STARTED, 0, 0, 0, NULL); }
static void terminated(int error) { emit(SF_TERMINATED, error, 0, 0, NULL); }
static void quality(int status) { emit(SF_QUALITY, status, 0, 0, NULL); }
static void hdr(bool enabled) { emit(SF_HDR, enabled, 0, 0, NULL); }
static void rumble(unsigned short index, unsigned short low, unsigned short high) { emit(SF_RUMBLE, index, low, high, NULL); }
static void log_message(const char *format, ...) { (void)format; /* Do not leak address/key-bearing RTSP logs. */ }

// This owner is deliberately shared by the real worker and deterministic harness.
// Every successful Wait/Poll acquisition enters here once; all paths converge on complete.
typedef void (*CompleteFrame)(void *handle, int status);
static int consume_frame(SFStream *s, VIDEO_FRAME_HANDLE handle, PDECODE_UNIT du, CompleteFrame complete) {
    int result = DR_NEED_IDR;
    if (!atomic_load_explicit(&s->video_stopping, memory_order_acquire) && du &&
        du->fullLength > 0 && (unsigned)du->fullLength <= MAX_COMPRESSED_FRAME) {
        size_t copied = 0;
        PLENTRY entry = du->bufferList;
        unsigned entries = 0;
        while (entry && ++entries <= 65536) {
            if (!entry->data || entry->length <= 0 || (size_t)entry->length > (size_t)du->fullLength - copied) break;
            memcpy(s->frame_buffer + copied, entry->data, (size_t)entry->length);
            copied += (size_t)entry->length;
            entry = entry->next;
        }
        if (!entry && copied == (size_t)du->fullLength && s->callbacks.video) {
            SFVideoFrame frame = { .bytes = s->frame_buffer, .length = copied,
                .frame_id = (uint32_t)du->frameNumber, .receive_time_us = du->receiveTimeUs,
                .enqueue_time_us = du->enqueueTimeUs, .presentation_time_us = du->presentationTimeUs,
                .rtp_timestamp = du->rtpTimestamp,
                .receive_uptime_ns = du->receiveTimeUs ? sf_common_clock_epoch_ns() + du->receiveTimeUs * 1000 : 0,
                .enqueue_uptime_ns = du->enqueueTimeUs ? sf_common_clock_epoch_ns() + du->enqueueTimeUs * 1000 : 0,
                .is_idr = du->frameType == FRAME_TYPE_IDR };
            result = s->callbacks.video(s->context, &frame) == DR_OK ? DR_OK : DR_NEED_IDR;
        }
    }
    complete(handle, result);
    return result;
}
static void *video_worker(void *context) {
    SFStream *s = context;
    pthread_setname_np("Swiftlight video admission");
    while (!atomic_load_explicit(&s->video_stopping, memory_order_acquire)) {
        VIDEO_FRAME_HANDLE handle; PDECODE_UNIT du;
        if (!LiWaitForNextVideoFrame(&handle, &du)) break;
        consume_frame(s, handle, du, LiCompleteVideoFrame);
    }
    return NULL;
}
static int video_setup(int format, int width, int height, int fps, void *context, int flags) {
    (void)flags;
    SFStream *s = context;
    const unsigned allowed = VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10 | VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_AV1_MAIN10;
    if (!(format & allowed) || (format & ~allowed) || !s->callbacks.setup) return -1;
    SFVideoDescription description = { .format = (uint32_t)format, .width = width, .height = height, .fps = fps };
    return s->callbacks.setup(s->context, &description);
}
static void video_start(void) {
    SFStream *s = active_stream; // lifecycle owns this pointer until common-c joins callbacks
    atomic_store(&s->video_stopping, false);
    int result = pthread_create(&s->video_thread, NULL, video_worker, s);
    s->video_thread_created = result == 0;
    if (result) { atomic_store(&s->video_stopping, true); emit(SF_FAILED, 0, result, 0, "video worker"); LiInterruptConnection(); }
}
static void video_stop(void) {
    SFStream *s = active_stream;
    atomic_store_explicit(&s->video_stopping, true, memory_order_release);
    LiWakeWaitForVideoFrame();
    if (s->video_thread_created) { pthread_join(s->video_thread, NULL); s->video_thread_created = false; }
}
static void video_cleanup(void) { }
static void audio_failure(void *context, int error) { (void)context; emit(SF_AUDIO_ERROR, error, 0, 0, NULL); }
static int audio_init(int configuration, OPUS_MULTISTREAM_CONFIGURATION *const opus, void *context, int flags) {
    (void)configuration; (void)flags;
    SFStream *s = context; int error;
    s->audio = sf_audio_create(opus, &error, audio_failure, s);
    return s->audio ? 0 : error;
}
static void audio_start(void) {
    int error = sf_audio_start(active_stream->audio);
    if (error) emit(SF_AUDIO_ERROR, error, 0, 0, NULL);
}
static void audio_stop(void) { sf_audio_stop(active_stream->audio); }
static void audio_cleanup(void) { sf_audio_destroy(active_stream->audio); active_stream->audio = NULL; }
static void audio_decode(char *data, int length) { sf_audio_decode(active_stream->audio, (unsigned char *)data, length); }
static int send_key_common(SFStream *s, uint16_t key, char action, char modifiers, char flags) {
    (void)s; return LiSendKeyboardEvent2((short)key, action, modifiers, flags);
}
static char *copy_string(const char *s) { return s ? strdup(s) : NULL; }
SFStream *sf_stream_create(const SFStreamConfiguration *c, SFStreamCallbacks callbacks, void *context) {
    const unsigned allowed = VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10 | VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_AV1_MAIN10;
    if (!c || !c->address || !c->app_version || !c->video_formats || (c->video_formats & ~allowed) ||
        c->width < 16 || c->width > 16384 || c->height < 16 || c->height > 16384 ||
        c->fps < 1 || c->fps > 1000 || c->bitrate_kbps < 500 || c->bitrate_kbps > 500000) return NULL;
    SFStream *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    pthread_mutex_init(&s->api_mutex, NULL);
    s->configuration = *c;
    s->configuration.address = copy_string(c->address); s->configuration.app_version = copy_string(c->app_version);
    s->configuration.gfe_version = copy_string(c->gfe_version); s->configuration.rtsp_url = copy_string(c->rtsp_url);
    s->callbacks = callbacks; s->context = context; s->send_key = send_key_common;
    s->frame_buffer = malloc(MAX_COMPRESSED_FRAME);
    if (!s->configuration.address || !s->configuration.app_version || !s->frame_buffer) { sf_stream_destroy(s); return NULL; }
    return s;
}
int sf_stream_start(SFStream *s) {
    pthread_mutex_lock(&active_mutex);
    if (active_stream || atomic_load_explicit(&s->state, memory_order_acquire) != CREATED) { pthread_mutex_unlock(&active_mutex); return -20001; }
    if (atomic_load(&s->cancelled)) { atomic_store_explicit(&s->state, STOPPED, memory_order_release); pthread_mutex_unlock(&active_mutex); return -20002; }
    active_stream = s; atomic_store_explicit(&s->state, STARTING, memory_order_release);
    pthread_mutex_unlock(&active_mutex);
    SERVER_INFORMATION server; LiInitializeServerInformation(&server);
    server.address = s->configuration.address; server.serverInfoAppVersion = s->configuration.app_version;
    server.serverInfoGfeVersion = s->configuration.gfe_version; server.rtspSessionUrl = s->configuration.rtsp_url;
    server.serverCodecModeSupport = (int)s->configuration.server_codec_support;
    STREAM_CONFIGURATION config; LiInitializeStreamConfiguration(&config);
    config.width = s->configuration.width; config.height = s->configuration.height; config.fps = s->configuration.fps;
    config.bitrate = s->configuration.bitrate_kbps; config.packetSize = 1392;
    config.streamingRemotely = STREAM_CFG_AUTO; config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    config.supportedVideoFormats = (int)s->configuration.video_formats; config.clientRefreshRateX100 = s->configuration.display_refresh_rate_x100;
    config.colorSpace = s->configuration.hdr ? COLORSPACE_REC_2020 : COLORSPACE_REC_709;
    config.colorRange = COLOR_RANGE_LIMITED; config.encryptionFlags = ENCFLG_ALL;
    memcpy(config.remoteInputAesKey, s->configuration.input_key, 16);
    uint32_t key_id = htonl(s->configuration.input_key_id); memcpy(config.remoteInputAesIv, &key_id, sizeof(key_id));
    DECODER_RENDERER_CALLBACKS video; LiInitializeVideoCallbacks(&video);
    video.setup = video_setup; video.start = video_start; video.stop = video_stop; video.cleanup = video_cleanup;
    video.capabilities = CAPABILITY_PULL_RENDERER; // Never DIRECT_SUBMIT: VT calls can block.
    AUDIO_RENDERER_CALLBACKS audio; LiInitializeAudioCallbacks(&audio);
    audio.init = audio_init; audio.start = audio_start; audio.stop = audio_stop;
    audio.cleanup = audio_cleanup; audio.decodeAndPlaySample = audio_decode;
    audio.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;
    CONNECTION_LISTENER_CALLBACKS events; LiInitializeConnectionCallbacks(&events);
    events.stageStarting = stage_start; events.stageFailed = stage_fail; events.connectionStarted = started;
    events.connectionTerminated = terminated; events.connectionStatusUpdate = quality; events.setHdrMode = hdr;
    events.rumble = rumble; events.logMessage = log_message;
    int result = LiStartConnection(&server, &config, &events, &video, &audio, s, 0, s, 0);
    pthread_mutex_lock(&s->api_mutex);
    atomic_store_explicit(&s->state, result == 0 ? STREAMING : STOPPED, memory_order_release);
    pthread_mutex_unlock(&s->api_mutex);
    if (result) {
        pthread_mutex_lock(&active_mutex); active_stream = NULL; pthread_mutex_unlock(&active_mutex);
    } else if (atomic_load(&s->cancelled)) {
        sf_stream_stop(s); result = -20002;
    }
    return result;
}
void sf_stream_cancel_start(SFStream *s) {
    atomic_store_explicit(&s->cancelled, true, memory_order_release);
    pthread_mutex_lock(&active_mutex);
    if (active_stream == s && atomic_load_explicit(&s->state, memory_order_acquire) == STARTING) LiInterruptConnection();
    pthread_mutex_unlock(&active_mutex);
}
static void release_inputs_locked(SFStream *s) {
    for (unsigned i = 0; i < 256; ++i) if (s->held_keys[i]) {
        s->send_key(s, s->held_keys[i], KEY_ACTION_UP, 0, 0); s->held_keys[i] = 0;
    }
    for (int i = 1; i < 6; ++i) if (s->held_mouse[i]) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, i); s->held_mouse[i] = false;
    }
    for (int i = 0; i < 16; ++i) if (s->controller_mask & (1u << i))
        LiSendMultiControllerEvent((short)i, (short)s->controller_mask, 0, 0, 0, 0, 0, 0, 0);
    s->controller_mask = 0;
}
void sf_stream_release_inputs(SFStream *s) {
    pthread_mutex_lock(&s->api_mutex);
    if (atomic_load_explicit(&s->state, memory_order_acquire) == STREAMING) release_inputs_locked(s);
    pthread_mutex_unlock(&s->api_mutex);
}
void sf_stream_stop(SFStream *s) {
    pthread_mutex_lock(&s->api_mutex);
    if (atomic_load_explicit(&s->state, memory_order_acquire) != STREAMING) { pthread_mutex_unlock(&s->api_mutex); return; }
    release_inputs_locked(s); atomic_store_explicit(&s->state, STOPPING, memory_order_release);
    pthread_mutex_unlock(&s->api_mutex);
    LiStopConnection(); // Serialized after start, never concurrently, joins pull worker before destroying queues.
    pthread_mutex_lock(&active_mutex); if (active_stream == s) active_stream = NULL; pthread_mutex_unlock(&active_mutex);
    pthread_mutex_lock(&s->api_mutex); atomic_store_explicit(&s->state, STOPPED, memory_order_release); pthread_mutex_unlock(&s->api_mutex);
}
void sf_stream_destroy(SFStream *s) {
    if (!s) return;
    sf_stream_stop(s);
    free((void *)s->configuration.address); free((void *)s->configuration.app_version);
    free((void *)s->configuration.gfe_version); free((void *)s->configuration.rtsp_url);
    free(s->frame_buffer); pthread_mutex_destroy(&s->api_mutex); free(s);
}
void sf_stream_request_idr(SFStream *s) {
    pthread_mutex_lock(&s->api_mutex); if (atomic_load_explicit(&s->state, memory_order_acquire) == STREAMING) LiRequestIdrFrame(); pthread_mutex_unlock(&s->api_mutex);
}
#define PERMISSION(bit) (!s->configuration.has_permissions || (s->configuration.permissions & (bit)) != 0)
#define INPUT_BEGIN pthread_mutex_lock(&s->api_mutex); int r = -1; if (atomic_load_explicit(&s->state, memory_order_acquire) == STREAMING) {
#define INPUT_END } pthread_mutex_unlock(&s->api_mutex); return r
int sf_stream_mouse_move(SFStream *s, int16_t x, int16_t y) { if (!PERMISSION(0x800)) return -2; INPUT_BEGIN r = LiSendMouseMoveEvent(x, y); INPUT_END; }
int sf_stream_mouse_position(SFStream *s, int16_t x, int16_t y, int16_t w, int16_t h) {
    if (!PERMISSION(0x800)) return -2;
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || x >= w || y >= h) return -1;
    INPUT_BEGIN r = LiSendMousePositionEvent(x, y, w, h); INPUT_END;
}
int sf_stream_mouse_button(SFStream *s, int button, bool pressed) {
    if (!PERMISSION(0x800)) return -2;
    if (button < 1 || button > 5) return -1;
    INPUT_BEGIN r = LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, button);
    if (!r) s->held_mouse[button] = pressed; INPUT_END;
}
int sf_stream_key(SFStream *s, uint16_t key, bool pressed, uint8_t modifiers) {
    if (!PERMISSION(0x1000)) return -2;
    // GameStream keyboard events carry 0x8000 | Win32 VK (Qt/iOS reference).
    // Idempotent normalization also accepts callers that already set the marker.
    key |= 0x8000u;
    INPUT_BEGIN r = s->send_key(s, key, pressed ? KEY_ACTION_DOWN : KEY_ACTION_UP, (char)modifiers, 0);
    if (!r) s->held_keys[key & 255] = pressed ? key : 0; INPUT_END;
}
int sf_stream_scroll(SFStream *s, int16_t vertical, int16_t horizontal) {
    if (!PERMISSION(0x800)) return -2;
    INPUT_BEGIN r = vertical ? LiSendHighResScrollEvent(vertical) : 0;
    if (horizontal) { int h = LiSendHighResHScrollEvent(horizontal); if (!r) r = h; } INPUT_END;
}
int sf_stream_controller(SFStream *s, uint8_t index, uint16_t mask, uint32_t buttons,
    uint8_t lt, uint8_t rt, int16_t lx, int16_t ly, int16_t rx, int16_t ry) {
    if (!PERMISSION(0x100)) return -2;
    if (index > 15) return -1;
    INPUT_BEGIN r = LiSendMultiControllerEvent(index, (short)mask, (int)buttons, lt, rt, lx, ly, rx, ry);
    if (!r) s->controller_mask = mask; INPUT_END;
}
bool sf_stream_diagnostics(SFStream *s, SFTransportDiagnostics *d) {
    memset(d, 0, sizeof(*d));
    pthread_mutex_lock(&s->api_mutex);
    if (atomic_load_explicit(&s->state, memory_order_acquire) != STREAMING) { pthread_mutex_unlock(&s->api_mutex); return false; }
    d->rtt_available = LiGetEstimatedRttInfo(&d->rtt_ms, &d->rtt_variance_ms);
    d->pending_video_frames = LiGetPendingVideoFrames();
    d->pending_audio_ms = LiGetPendingAudioDuration();
    sf_audio_stats(s->audio, &d->audio_queued_frames, &d->audio_underrun_frames, &d->audio_overrun_frames);
    struct sockaddr_storage address; socklen_t length = sizeof(address);
    if (sf_common_video_local_address(&address, &length)) {
        getnameinfo((struct sockaddr *)&address, length, d->local_address, sizeof(d->local_address), NULL, 0, NI_NUMERICHOST);
        struct ifaddrs *interfaces;
        if (getifaddrs(&interfaces) == 0) {
            for (struct ifaddrs *i = interfaces; i; i = i->ifa_next) {
                if (!i->ifa_addr || i->ifa_addr->sa_family != address.ss_family) continue;
                bool match = false;
                if (address.ss_family == AF_INET)
                    match = ((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr == ((struct sockaddr_in *)&address)->sin_addr.s_addr;
                else if (address.ss_family == AF_INET6)
                    match = memcmp(&((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, &((struct sockaddr_in6 *)&address)->sin6_addr, sizeof(struct in6_addr)) == 0;
                if (match) { strlcpy(d->interface_name, i->ifa_name, sizeof(d->interface_name)); break; }
            }
            freeifaddrs(interfaces);
        }
    }
    pthread_mutex_unlock(&s->api_mutex); return true;
}
const char *sf_stream_launch_query(void) { return LiGetLaunchUrlQueryParameters(); }

typedef struct { unsigned completions, submissions; int result; } TestFrameContext;
static void test_complete(void *context, int result) { TestFrameContext *c = context; ++c->completions; c->result = result; }
static int test_submit(void *context, const SFVideoFrame *frame) {
    TestFrameContext *c = context; ++c->submissions;
    if (frame->length != 6 || memcmp(frame->bytes, "abcdef", 6)) return DR_NEED_IDR;
    return c->result;
}
int sf_stream_validate_frame_ownership(unsigned scenario, unsigned *completions, unsigned *submissions) {
    TestFrameContext c = { .result = scenario == 1 ? DR_NEED_IDR : DR_OK };
    SFStream s = { .context = &c, .callbacks.video = test_submit };
    uint8_t buffer[8]; s.frame_buffer = buffer;
    LENTRY second = { .data = "def", .length = 3 };
    LENTRY first = { .data = "abc", .length = 3, .next = &second };
    DECODE_UNIT du = { .fullLength = 6, .bufferList = &first };
    if (scenario == 2) du.fullLength = 5;
    if (scenario == 3) atomic_store(&s.video_stopping, true);
    if (scenario == 4) du.fullLength = MAX_COMPRESSED_FRAME + 1;
    if (scenario == 5) second.next = &first;
    int result = consume_frame(&s, &c, &du, test_complete);
    *completions = c.completions; *submissions = c.submissions;
    return result;
}

bool sf_stream_validate_clock_mapping(void) {
    // Initialize the common-c clock before sampling the immutable epoch.
    PltGetMicroseconds();
    uint64_t before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t relative = PltGetMicroseconds();
    uint64_t after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t mapped = sf_common_clock_epoch_ns() + relative * 1000;
    return mapped + 1000 >= before && mapped <= after;
}
typedef struct { _Atomic unsigned count; } TestEventContext;
static void test_event(void *context, int kind, int a, int b, int c, const char *message) {
    (void)kind; (void)a; (void)b; (void)c; (void)message;
    TestEventContext *events = context;
    atomic_fetch_add(&events->count, 1);
}
static void *test_event_producer(void *context) {
    (void)context;
    for (unsigned i = 0; i < 100000; ++i) emit(SF_QUALITY, 0, 0, 0, NULL);
    return NULL;
}
typedef struct {
    dispatch_semaphore_t entered, release_callback, retire_started;
    SFStream *stream;
    unsigned callbacks;
} RetirementRace;
static void blocking_test_event(void *context, int kind, int a, int b, int c, const char *message) {
    (void)kind; (void)a; (void)b; (void)c; (void)message;
    RetirementRace *race = context;
    ++race->callbacks;
    dispatch_semaphore_signal(race->entered);
    dispatch_semaphore_wait(race->release_callback, DISPATCH_TIME_FOREVER);
}
static void *one_test_event(void *context) { (void)context; emit(SF_QUALITY, 0, 0, 0, NULL); return NULL; }
static void *retire_test_event(void *context) {
    RetirementRace *race = context;
    dispatch_semaphore_signal(race->retire_started);
    pthread_mutex_lock(&active_mutex);
    active_stream = NULL; free(race->stream);
    pthread_mutex_unlock(&active_mutex);
    return NULL;
}
bool sf_stream_validate_event_retirement(void) {
    // Standalone deterministic harness only: no live session may be active.
    pthread_mutex_lock(&active_mutex);
    if (active_stream) { pthread_mutex_unlock(&active_mutex); return false; }
    pthread_mutex_unlock(&active_mutex);
    RetirementRace race = { .entered = dispatch_semaphore_create(0), .release_callback = dispatch_semaphore_create(0),
        .retire_started = dispatch_semaphore_create(0), .stream = calloc(1, sizeof(SFStream)) };
    if (!race.stream) return false;
    race.stream->context = &race; race.stream->callbacks.event = blocking_test_event;
    pthread_mutex_lock(&active_mutex); active_stream = race.stream; pthread_mutex_unlock(&active_mutex);
    pthread_t callback_thread, retirement_thread;
    if (pthread_create(&callback_thread, NULL, one_test_event, NULL)) {
        pthread_mutex_lock(&active_mutex); active_stream = NULL; free(race.stream); pthread_mutex_unlock(&active_mutex);
        dispatch_release(race.entered); dispatch_release(race.release_callback); dispatch_release(race.retire_started);
        return false;
    }
    dispatch_semaphore_wait(race.entered, DISPATCH_TIME_FOREVER);
    if (pthread_create(&retirement_thread, NULL, retire_test_event, &race)) {
        dispatch_semaphore_signal(race.release_callback); pthread_join(callback_thread, NULL);
        pthread_mutex_lock(&active_mutex); active_stream = NULL; free(race.stream); pthread_mutex_unlock(&active_mutex);
        dispatch_release(race.entered); dispatch_release(race.release_callback); dispatch_release(race.retire_started);
        return false;
    }
    dispatch_semaphore_wait(race.retire_started, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(race.release_callback);
    pthread_join(callback_thread, NULL); pthread_join(retirement_thread, NULL);
    dispatch_release(race.entered); dispatch_release(race.release_callback); dispatch_release(race.retire_started);
    if (race.callbacks != 1) return false;
    pthread_t producer;
    if (pthread_create(&producer, NULL, test_event_producer, NULL)) return false;
    for (unsigned i = 0; i < 1000; ++i) {
        SFStream *s = calloc(1, sizeof(*s)); TestEventContext *context = calloc(1, sizeof(*context));
        if (!s || !context) { free(s); free(context); pthread_join(producer, NULL); return false; }
        s->context = context; s->callbacks.event = test_event;
        pthread_mutex_lock(&active_mutex); active_stream = s; pthread_mutex_unlock(&active_mutex);
        // Event callbacks and context destruction synchronize on the same retirement gate.
        pthread_mutex_lock(&active_mutex); active_stream = NULL; free(context); free(s); pthread_mutex_unlock(&active_mutex);
    }
    pthread_join(producer, NULL);
    return true;
}

typedef struct { unsigned count; uint16_t keys[8]; char actions[8], modifiers[8]; } KeyWireSpy;
static int spy_key(SFStream *s, uint16_t key, char action, char modifiers, char flags) {
    (void)flags; KeyWireSpy *spy = s->context;
    if (spy->count >= 8) return -1;
    unsigned i = spy->count++; spy->keys[i] = key; spy->actions[i] = action; spy->modifiers[i] = modifiers;
    return 0;
}
bool sf_stream_validate_keyboard_wire_codes(void) {
    KeyWireSpy spy = {0}; SFStream s = { .state = STREAMING, .context = &spy, .send_key = spy_key };
    pthread_mutex_init(&s.api_mutex, NULL);
    bool ok = sf_stream_key(&s, 0x41, true, MODIFIER_SHIFT) == 0 &&
              sf_stream_key(&s, 0x8041, false, 0) == 0 &&
              sf_stream_key(&s, 0x12, true, MODIFIER_ALT) == 0;
    sf_stream_release_inputs(&s);
    ok = ok && spy.count == 4 && spy.keys[0] == 0x8041 && spy.keys[1] == 0x8041 &&
         spy.keys[2] == 0x8012 && spy.keys[3] == 0x8012 &&
         spy.actions[0] == KEY_ACTION_DOWN && spy.actions[1] == KEY_ACTION_UP &&
         spy.actions[2] == KEY_ACTION_DOWN && spy.actions[3] == KEY_ACTION_UP &&
         spy.modifiers[0] == MODIFIER_SHIFT && spy.modifiers[2] == MODIFIER_ALT && !s.held_keys[0x12];
    pthread_mutex_destroy(&s.api_mutex); return ok;
}
typedef struct { SFStream *stream; dispatch_semaphore_t ready, done; _Atomic bool valid; } CancelRace;
static void *cancellation_test_worker(void *context) {
    CancelRace *race = context;
    for (unsigned i = 0; i < 20000; ++i) {
        dispatch_semaphore_wait(race->ready, DISPATCH_TIME_FOREVER);
        sf_stream_cancel_start(race->stream);
        bool expected = i % 4 == 0;
        if (atomic_load_explicit(&ConnectionInterrupted, memory_order_acquire) != expected)
            atomic_store(&race->valid, false);
        dispatch_semaphore_signal(race->done);
    }
    // Unsynchronized cancellation races the writer's state publication below.
    for (unsigned i = 0; i < 100000; ++i) sf_stream_cancel_start(race->stream);
    return NULL;
}
bool sf_stream_validate_cancel_state_race(void) {
    // No host/socket use: exercise production cancel against atomic lifecycle states.
    SFStream s = {0}; pthread_mutex_init(&s.api_mutex, NULL);
    CancelRace race = { .stream = &s, .ready = dispatch_semaphore_create(0), .done = dispatch_semaphore_create(0), .valid = true };
    pthread_mutex_lock(&active_mutex);
    if (active_stream) { pthread_mutex_unlock(&active_mutex); pthread_mutex_destroy(&s.api_mutex); return false; }
    active_stream = &s; pthread_mutex_unlock(&active_mutex);
    pthread_t thread;
    if (pthread_create(&thread, NULL, cancellation_test_worker, &race)) {
        pthread_mutex_lock(&active_mutex); active_stream = NULL; pthread_mutex_unlock(&active_mutex);
        dispatch_release(race.ready); dispatch_release(race.done); pthread_mutex_destroy(&s.api_mutex); return false;
    }
    int phases[] = { STARTING, STREAMING, STOPPING, STOPPED };
    for (unsigned i = 0; i < 20000; ++i) {
        pthread_mutex_lock(&s.api_mutex);
        atomic_store_explicit(&s.state, phases[i % 4], memory_order_release);
        atomic_store_explicit(&ConnectionInterrupted, false, memory_order_release);
        pthread_mutex_unlock(&s.api_mutex);
        dispatch_semaphore_signal(race.ready); dispatch_semaphore_wait(race.done, DISPATCH_TIME_FOREVER);
    }
    for (unsigned i = 0; i < 100000; ++i) {
        pthread_mutex_lock(&s.api_mutex);
        atomic_store_explicit(&s.state, phases[i % 4], memory_order_release);
        atomic_store_explicit(&ConnectionInterrupted, false, memory_order_release);
        pthread_mutex_unlock(&s.api_mutex);
    }
    pthread_join(thread, NULL);
    pthread_mutex_lock(&active_mutex); active_stream = NULL; pthread_mutex_unlock(&active_mutex);
    bool valid = atomic_load(&race.valid);
    dispatch_release(race.ready); dispatch_release(race.done); pthread_mutex_destroy(&s.api_mutex);
    return valid;
}
