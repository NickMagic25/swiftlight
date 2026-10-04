#include "StreamBridge.h"
#include "Limelight-internal.h"
#include <stdlib.h>
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "CHECK failed %s:%d: %s\n", __FILE__, __LINE__, #condition); abort(); } } while (0)
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>

extern int sf_common_select_pyrowave_format(uint32_t server_formats, uint32_t client_formats);
extern bool sf_common_pyrowave_bitstream_compatible(const char *sdp);
static void validate_pyrowave_negotiation(void) {
    const uint32_t profiles[] = { VIDEO_FORMAT_PYROWAVE, VIDEO_FORMAT_PYROWAVE_444,
        VIDEO_FORMAT_PYROWAVE_HDR10, VIDEO_FORMAT_PYROWAVE_HDR10_444 };
    const uint32_t server_profiles[] = { SCM_PYROWAVE, SCM_PYROWAVE_444, SCM_PYROWAVE_HDR10, SCM_PYROWAVE_HDR10_444 };
    CHECK(sf_common_select_pyrowave_format(SCM_MASK_PYROWAVE, VIDEO_FORMAT_MASK_PYROWAVE) == VIDEO_FORMAT_PYROWAVE_HDR10_444);
    CHECK(sf_common_select_pyrowave_format(SCM_HEVC, VIDEO_FORMAT_MASK_PYROWAVE) == 0);
    CHECK(sf_common_pyrowave_bitstream_compatible("a=rtpmap:99 PYROWAVE/90000\r\na=x-ss-pyrowave.bitstream:186f0393\r\n"));
    CHECK(sf_common_pyrowave_bitstream_compatible("a=rtpmap:99 PYROWAVE/90000\r\n")); // legacy unknown revision
    CHECK(!sf_common_pyrowave_bitstream_compatible("a=x-ss-pyrowave.bitstream:deadbeef\r\n"));
    CHECK(!sf_common_pyrowave_bitstream_compatible("a=x-ss-pyrowave.bitstream:186f0393123456789012345678901234567890\r\n"));
    CHECK(!sf_common_pyrowave_bitstream_compatible("a=x-unrelated.x-ss-pyrowave.bitstream:186f0393\r\na=x-ss-pyrowave.bitstream:bad00000\r\n"));
    AppVersionQuad[0] = 7; AppVersionQuad[1] = 1; AppVersionQuad[2] = 431; AppVersionQuad[3] = -1;
    RemoteAddr.ss_family = AF_INET;
    ((struct sockaddr_in *)&RemoteAddr)->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    VideoPortNumber = 47998;
    StreamConfig = (STREAM_CONFIGURATION) { .width = 1920, .height = 1080, .fps = 120,
        .bitrate = 1000000, .packetSize = 1392, .streamingRemotely = STREAM_CFG_LOCAL,
        .audioConfiguration = AUDIO_CONFIGURATION_STEREO, .colorSpace = COLORSPACE_REC_709,
        .colorRange = COLOR_RANGE_LIMITED };
    for (unsigned i = 0; i < 4; ++i) {
        CHECK(sf_common_select_pyrowave_format(SCM_MASK_PYROWAVE, profiles[i]) == (int)profiles[i]);
        CHECK(sf_common_select_pyrowave_format(server_profiles[i], profiles[(i + 1) % 4]) == 0);
        NegotiatedVideoFormat = (int)profiles[i];
        int length = 0; char *sdp = getSdpPayloadForStreamConfig(14, &length); CHECK(sdp && length > 0);
        CHECK(strstr(sdp, "a=x-nv-vqos[0].bitStreamFormat:3 \r\n"));
        CHECK(strstr(sdp, "a=x-ss-video[0].pyrowaveAdaptiveFec:0 \r\n"));
        CHECK(strstr(sdp, "a=x-ss-video[0].pyrowaveAdaptiveBitrate:0 \r\n"));
        CHECK(strstr(sdp, "a=x-ss-video[0].pyrowaveFeatures:1 \r\n"));
        CHECK(strstr(sdp, i >= 2 ? "a=x-nv-video[0].dynamicRangeMode:1 \r\n" : "a=x-nv-video[0].dynamicRangeMode:0 \r\n"));
        CHECK(strstr(sdp, i & 1 ? "a=x-ss-video[0].chromaSamplingType:1 \r\n" : "a=x-ss-video[0].chromaSamplingType:0 \r\n"));
        free(sdp);
    }
}
static void depacketize_pyrowave_packet(unsigned frame, unsigned index, uint8_t flags, int payload_length, bool lost, bool record_start) {
    const size_t storage_length = MAX_RTP_HEADER_SIZE + 64;
    char *storage = calloc(1, storage_length + sizeof(RTPV_QUEUE_ENTRY)); CHECK(storage);
    PRTP_PACKET rtp = (PRTP_PACKET)storage;
    rtp->header = FLAG_EXTENSION; rtp->sequenceNumber = index + 1; rtp->timestamp = frame * 750;
    PNV_VIDEO_PACKET packet = (PNV_VIDEO_PACKET)(storage + MAX_RTP_HEADER_SIZE);
    packet->frameIndex = frame; packet->streamPacketIndex = index << 8; packet->flags = flags;
    packet->extraFlags = record_start ? NV_VIDEO_PACKET_EXTRA_FLAG_PYROWAVE_RECORD_START : 0;
    uint8_t *payload = (uint8_t *)(packet + 1);
    if (!lost) memset(payload, 0xA5, payload_length);
    if (flags & FLAG_SOF) {
        payload[0] = 1; payload[1] = 3; payload[2] = 0; payload[3] = 2;
        payload[4] = flags & FLAG_EOF ? payload_length : 7; payload[5] = 0;
        payload[6] = 1; payload[7] = 0;
        // An Annex B-looking prefix must remain untouched in an independent PyroWave payload.
        if (payload_length >= 12) { payload[8] = 0; payload[9] = 0; payload[10] = 1; payload[11] = 0x67; }
    }
    PRTPV_QUEUE_ENTRY entry = (PRTPV_QUEUE_ENTRY)(storage + storage_length);
    *entry = (RTPV_QUEUE_ENTRY) { .packet = rtp, .receiveTimeUs = 1000 + index,
        .lastRequiredPacketReceiveTimeUs = frame == 1 ? 0 : 1500 + frame,
        .fecReadyTimeUs = 2000 + frame, .transportPartial = frame == 1,
        .presentationTimeUs = frame * 8333, .rtpTimestamp = rtp->timestamp,
        .length = MAX_RTP_HEADER_SIZE + sizeof(NV_VIDEO_PACKET) + payload_length, .isLost = lost };
    queueRtpPacket(entry);
}
static void validate_pyrowave_depacketizer(void) {
    NegotiatedVideoFormat = VIDEO_FORMAT_PYROWAVE;
    VideoCallbacks.capabilities = CAPABILITY_PULL_RENDERER;
    ReferenceFrameInvalidationSupported = false;
    SS_HDR_METADATA metadata = { .displayPrimaries = {{32000, 16500}, {15000, 30000}, {7500, 3000}},
        .whitePoint = {15635, 16450}, .maxDisplayLuminance = 1000, .minDisplayLuminance = 1,
        .maxContentLightLevel = 1200, .maxFrameAverageLightLevel = 400, .maxFullFrameLuminance = 500 };
    sf_common_publish_hdr_state(true, &metadata);
    initializeVideoDepacketizer(64);
    depacketize_pyrowave_packet(1, 0, FLAG_SOF | FLAG_CONTAINS_PIC_DATA, 48, false, true);
    depacketize_pyrowave_packet(1, 1, FLAG_CONTAINS_PIC_DATA, 48, true, false);
    depacketize_pyrowave_packet(1, 2, FLAG_EOF | FLAG_CONTAINS_PIC_DATA, 48, false, true);
    // State can change while the completed AU is still queued. Its captured color must not.
    sf_common_publish_hdr_state(false, NULL);
    VIDEO_FRAME_HANDLE handle; PDECODE_UNIT du;
    CHECK(LiPollNextVideoFrame(&handle, &du));
    CHECK(du->fullLength == 95 && du->pyrowaveCriticalPackets == 1 && du->frameType == FRAME_TYPE_IDR);
    CHECK(du->lastRequiredPacketReceiveTimeUs == 0 && du->fecReadyTimeUs == 2001 && du->transportPartial);
    CHECK(du->queueOfferTimeUs >= du->enqueueTimeUs && du->queueOfferTimeUs != 0);
    CHECK(du->hdrActive && du->hdrMetadataValid && !memcmp(&du->hdrMetadata, &metadata, sizeof(metadata)));
    PLENTRY entry = du->bufferList;
    CHECK(entry && entry->length == 40 && entry->bufferType == BUFFER_TYPE_RECORD_START);
    CHECK(!memcmp(entry->data, "\0\0\1\x67", 4));
    entry = entry->next; CHECK(entry && entry->length == 48 && entry->bufferType == BUFFER_TYPE_LOST);
    entry = entry->next; CHECK(entry && entry->length == 7 && entry->bufferType == BUFFER_TYPE_RECORD_START && !entry->next);
    LiCompleteVideoFrame(handle, DR_OK);
    // A truncated frame header is rejected; the next independent frame is accepted.
    depacketize_pyrowave_packet(2, 3, FLAG_SOF | FLAG_EOF | FLAG_CONTAINS_PIC_DATA, 4, false, true);
    CHECK(!LiPollNextVideoFrame(&handle, &du));
    depacketize_pyrowave_packet(3, 4, FLAG_SOF | FLAG_EOF | FLAG_CONTAINS_PIC_DATA, 16, false, true);
    CHECK(LiPollNextVideoFrame(&handle, &du)); CHECK(du->fullLength == 8 && du->frameNumber == 3);
    CHECK(!du->hdrActive && !du->hdrMetadataValid);
    CHECK(du->lastRequiredPacketReceiveTimeUs == 1503 && du->fecReadyTimeUs == 2003 && !du->transportPartial);
    CHECK(du->queueOfferTimeUs >= du->enqueueTimeUs && du->queueOfferTimeUs != 0);
    LiCompleteVideoFrame(handle, DR_OK);
    stopVideoDepacketizer(); destroyVideoDepacketizer();
}
typedef struct { _Atomic bool done; } HDRSnapshotRace;
static void *hdr_snapshot_reader(void *context) {
    HDRSnapshotRace *race = context;
    do {
        bool active, valid; SS_HDR_METADATA metadata;
        sf_common_hdr_snapshot(&active, &valid, &metadata);
        CHECK(active == valid);
        if (active) {
            CHECK(metadata.displayPrimaries[0].x == 111 && metadata.displayPrimaries[1].y == 222);
            CHECK(metadata.whitePoint.x == 333 && metadata.maxDisplayLuminance == 444);
            CHECK(metadata.minDisplayLuminance == 555 && metadata.maxContentLightLevel == 666);
            CHECK(metadata.maxFrameAverageLightLevel == 777 && metadata.maxFullFrameLuminance == 888);
        }
        else CHECK(metadata.maxDisplayLuminance == 0 && metadata.maxContentLightLevel == 0);
    } while (!atomic_load(&race->done));
    return NULL;
}
static void validate_hdr_snapshot_race(void) {
    SS_HDR_METADATA metadata = { .displayPrimaries = {{111, 0}, {0, 222}, {0, 0}}, .whitePoint = {333, 0},
        .maxDisplayLuminance = 444, .minDisplayLuminance = 555, .maxContentLightLevel = 666,
        .maxFrameAverageLightLevel = 777, .maxFullFrameLuminance = 888 };
    sf_common_publish_hdr_state(true, &metadata);
    SS_HDR_METADATA official = {0}; CHECK(LiGetCurrentHostDisplayHdrMode()); CHECK(LiGetHdrMetadata(&official));
    CHECK(!memcmp(&official, &metadata, sizeof(metadata)));
    sf_common_publish_hdr_state(false, NULL); CHECK(!LiGetCurrentHostDisplayHdrMode()); CHECK(!LiGetHdrMetadata(&official));
    HDRSnapshotRace race = {0}; pthread_t reader; CHECK(!pthread_create(&reader, NULL, hdr_snapshot_reader, &race));
    for (unsigned i = 0; i < 100000; ++i) sf_common_publish_hdr_state((i & 1) != 0, i & 1 ? &metadata : NULL);
    atomic_store(&race.done, true); CHECK(!pthread_join(reader, NULL));
    sf_common_publish_hdr_state(false, NULL);
}

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
    CHECK(sf_stream_validate_video_telemetry());
    CHECK(sf_stream_validate_event_retirement());
    CHECK(sf_stream_validate_pyrowave_sideband());
    CHECK(sf_stream_validate_pyrowave_queue_ownership());
    CHECK(strstr(sf_stream_launch_query(), "&") != NULL);
    SFStreamConfiguration config = { .address = "localhost", .app_version = "7.1.431.0",
        .video_formats = 0x100, .width = 1920, .height = 1080, .fps = 60, .bitrate_kbps = 20000,
        .has_permissions = true, .permissions = 0, .audio_channels = 2 };
    const uint32_t compressed_profiles[] = {0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000, 0x4000, 0x8000};
    for (unsigned i = 0; i < sizeof(compressed_profiles) / sizeof(compressed_profiles[0]); ++i) {
        config.video_formats = compressed_profiles[i];
        SFStream *profile = sf_stream_create(&config, (SFStreamCallbacks){0}, NULL); CHECK(profile);
        sf_stream_destroy(profile);
    }
    config.video_formats = 0x1; // Unsupported H.264 remains rejected.
    CHECK(!sf_stream_create(&config, (SFStreamCallbacks){0}, NULL));
    config.video_formats = 0x100000; // Unknown formats remain rejected.
    CHECK(!sf_stream_create(&config, (SFStreamCallbacks){0}, NULL));
    config.video_formats = 0x100;
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
    validate_pyrowave_negotiation();
    validate_pyrowave_depacketizer();
    validate_hdr_snapshot_race();
    puts("{\"status\":\"PASS\",\"pyrowave_negotiation_sdp_depacketizer_sideband\":true,\"pyrowave_queue_ownership_scenarios\":10,\"video_telemetry_units_windows_concurrency\":true,\"ownership_scenarios\":6,\"audio_ordered_frames\":100000,\"audio_ring_wrap_overflow_silence\":true,\"clock_mapping\":true,\"permission_gates\":true,\"event_retirements\":1000,\"keyboard_wire_codes\":true,\"cancel_state_phases\":20000,\"cancel_state_race_iterations\":100000}");
    return 0;
}
