// Exercise the actual patched RTP queue with synthetic packets. No sockets,
// control connection, decoder, or video host are involved.
#include "Limelight-internal.h"
#include <rs.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "CHECK %s:%d: %s\n", __FILE__, __LINE__, #x); abort(); } } while (0)
int AppVersionQuad[4] = {7, 1, 431, 0};
STREAM_CONFIGURATION StreamConfig = {.packetSize = 64};
static void discard_log(const char *format, ...) { (void)format; }
CONNECTION_LISTENER_CALLBACKS ListenerCallbacks = {.logMessage = discard_log};
static bool enable_speculation;
static unsigned speculative_notifications, confirmed_notifications, submitted_packets;
static uint64_t tick = 1000000;
uint64_t PltGetMicroseconds(void) { return ++tick; }
bool isReferenceFrameInvalidationEnabled(void) { return enable_speculation; }
void connectionSawFrame(uint32_t frame) { (void)frame; }
void connectionSendFrameFecStatus(PSS_FRAME_FEC_STATUS status) { (void)status; }
void notifyFrameLost(unsigned frame, bool speculative) {
    (void)frame;
    if (speculative) ++speculative_notifications; else ++confirmed_notifications;
}
void queueRtpPacket(PRTPV_QUEUE_ENTRY entry) { ++submitted_packets; free(entry->packet); }
static const int packet_size = 80;
static unsigned char *make_packet(uint32_t frame, uint16_t base, unsigned index, unsigned data_count,
                                  unsigned fec_percent, unsigned block, unsigned last_block) {
    unsigned char *bytes = calloc(1, packet_size + sizeof(RTPV_QUEUE_ENTRY)); CHECK(bytes);
    PRTP_PACKET rtp = (PRTP_PACKET)bytes;
    rtp->header = FLAG_EXTENSION; rtp->sequenceNumber = base + index; rtp->timestamp = frame * 1500;
    PNV_VIDEO_PACKET nv = (PNV_VIDEO_PACKET)(bytes + MAX_RTP_HEADER_SIZE);
    nv->frameIndex = frame; nv->streamPacketIndex = (base + index) << 8;
    nv->flags = FLAG_CONTAINS_PIC_DATA | (index == 0 ? FLAG_SOF : 0) | (index == data_count - 1 ? FLAG_EOF : 0);
    nv->multiFecFlags = 0x10; nv->multiFecBlocks = (last_block << 6) | (block << 4);
    nv->fecInfo = (data_count << 22) | (index << 12) | (fec_percent << 4);
    return bytes;
}
static void ingest(PRTP_VIDEO_QUEUE queue, unsigned char *bytes) {
    PRTPV_QUEUE_ENTRY entry = (PRTPV_QUEUE_ENTRY)(bytes + packet_size);
    if (RtpvAddPacket(queue, (PRTP_PACKET)bytes, packet_size, entry) == RTPF_RET_REJECTED) free(bytes);
}
static void send_packet(PRTP_VIDEO_QUEUE q, uint32_t frame, uint16_t base, unsigned index,
                        unsigned count, unsigned block, unsigned last) {
    ingest(q, make_packet(frame, base, index, count, 0, block, last));
}
static void outcome(PRTP_VIDEO_QUEUE queue, uint64_t received, uint64_t lost) {
    CHECK(atomic_load(&queue->receivedFrameCount) == received);
    CHECK(atomic_load(&queue->networkLostFrameCount) == lost);
}
static void reset(PRTP_VIDEO_QUEUE queue) {
    RtpvCleanupQueue(queue); RtpvInitializeQueue(queue);
    enable_speculation = false; speculative_notifications = confirmed_notifications = submitted_packets = 0;
    outcome(queue, 0, 0);
}
typedef struct { PRTP_VIDEO_QUEUE queue; _Atomic bool done; } SnapshotRace;
static void *read_counters(void *context) {
    SnapshotRace *race = context; uint64_t previous_received = 0, previous_lost = 0;
    do {
        uint64_t received = atomic_load_explicit(&race->queue->receivedFrameCount, memory_order_relaxed);
        uint64_t lost = atomic_load_explicit(&race->queue->networkLostFrameCount, memory_order_relaxed);
        CHECK(received >= previous_received && lost >= previous_lost);
        previous_received = received; previous_lost = lost;
        sched_yield();
    } while (!atomic_load(&race->done));
    return NULL;
}
int main(void) {
    RTP_VIDEO_QUEUE q; RtpvInitializeQueue(&q);
    send_packet(&q, 1, 1, 0, 1, 0, 0);
    send_packet(&q, 4, 4, 0, 1, 0, 0); outcome(&q, 2, 2); // entire missing frames
    send_packet(&q, 4, 4, 0, 1, 0, 0); outcome(&q, 2, 2); // duplicate/late has no effect
    reset(&q);
    send_packet(&q, 1, 1, 0, 2, 0, 1); outcome(&q, 0, 0); // pending is not yet loss
    send_packet(&q, 1, 3, 0, 1, 1, 1); outcome(&q, 0, 1); // incomplete preceding block
    send_packet(&q, 1, 3, 0, 1, 1, 1); outcome(&q, 0, 1);
    reset(&q);
    send_packet(&q, 1, 1, 0, 1, 0, 2); // block zero complete, block one entirely missing
    send_packet(&q, 1, 3, 0, 1, 2, 2); outcome(&q, 0, 1);
    reset(&q);
    send_packet(&q, 1, 1, 0, 2, 0, 1);
    send_packet(&q, 4, 8, 0, 1, 1, 1); outcome(&q, 0, 4); // previous+intervening+new partial
    send_packet(&q, 5, 9, 0, 1, 0, 0); outcome(&q, 1, 4);
    reset(&q); enable_speculation = true;
    send_packet(&q, 1, 1, 1, 2, 0, 0); outcome(&q, 0, 0); CHECK(speculative_notifications == 1);
    send_packet(&q, 1, 1, 0, 2, 0, 0); outcome(&q, 1, 0); CHECK(submitted_packets == 2); // OOS recovery
    reset(&q); enable_speculation = true;
    send_packet(&q, 1, 1, 1, 2, 0, 0);
    send_packet(&q, 2, 3, 0, 1, 0, 0); outcome(&q, 1, 1);
    CHECK(speculative_notifications == 1 && confirmed_notifications == 0); // loss counted despite RFI suppression
    reset(&q);
    unsigned char *shards[] = { make_packet(1, 1, 0, 2, 50, 0, 0), make_packet(1, 1, 1, 2, 50, 0, 0), make_packet(1, 1, 2, 2, 50, 0, 0) };
    reed_solomon *rs = reed_solomon_new(2, 1); CHECK(rs);
    CHECK(reed_solomon_encode(rs, shards, 3, packet_size) == 0); reed_solomon_release(rs);
    // Packet-routing headers on parity are outside the recovered video payload.
    PRTP_PACKET parity_rtp = (PRTP_PACKET)shards[2]; parity_rtp->header = FLAG_EXTENSION; parity_rtp->sequenceNumber = 3; parity_rtp->timestamp = 1500;
    PNV_VIDEO_PACKET parity_nv = (PNV_VIDEO_PACKET)(shards[2] + MAX_RTP_HEADER_SIZE);
    parity_nv->frameIndex = 1; parity_nv->multiFecFlags = 0x10; parity_nv->multiFecBlocks = 0;
    parity_nv->fecInfo = (2 << 22) | (2 << 12) | (50 << 4);
    free(shards[1]); ingest(&q, shards[0]); ingest(&q, shards[2]);
    outcome(&q, 1, 0); CHECK(submitted_packets == 2); // actual Reed-Solomon packet recovery
    reset(&q);
    // The queue's normal uint32 frame-number progression wraps without inventing loss.
    q.currentFrameNumber = UINT32_MAX;
    send_packet(&q, UINT32_MAX, 1, 0, 1, 0, 0); send_packet(&q, 0, 2, 0, 1, 0, 0); outcome(&q, 2, 0);
    reset(&q); SnapshotRace race = {.queue = &q}; pthread_t reader;
    CHECK(!pthread_create(&reader, NULL, read_counters, &race));
    for (unsigned i = 1; i <= 100000; ++i) send_packet(&q, i, (uint16_t)i, 0, 1, 0, 0);
    atomic_store(&race.done, true); CHECK(!pthread_join(reader, NULL)); outcome(&q, 100000, 0);
    reset(&q); RtpvCleanupQueue(&q);
    puts("{\"status\":\"PASS\",\"rtp_loss_scenarios\":8,\"concurrent_frame_outcomes\":100000,\"real_reed_solomon_recovery\":true,\"host_used\":false}");
}
