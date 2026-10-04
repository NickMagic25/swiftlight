#include "SPyrowaveInput.hpp"
#include <algorithm>
#include <limits>

namespace swiftlight {
namespace {
constexpr size_t MaxBytes = 64 * 1024 * 1024, MaxFragments = 4096;
uint32_t le32(const uint8_t *p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
struct Invalid {};
void require(bool value) { if (!value) throw Invalid{}; }
struct Packets {
    const sp_fragment *p;
    size_t count;
    bool has_loss = false;
    size_t index(size_t offset) const {
        size_t a = 0, b = count;
        while (a < b) { const size_t m = a + (b - a) / 2; if (p[m].offset <= offset) a = m + 1; else b = m; }
        return a ? a - 1 : count;
    }
    bool lost(size_t a, size_t b) const {
        if (!has_loss) return false;
        for (size_t i = index(a); i < count && p[i].offset < b; ++i) if (p[i].kind == SP_FRAGMENT_LOST) return true;
        return false;
    }
    bool one(size_t a, size_t b) const { const size_t i = index(a); return i < count && b <= size_t(p[i].offset) + p[i].size; }
    size_t next(size_t offset, bool flagged, size_t end) const {
        for (size_t i = index(offset) + 1; i < count; ++i)
            if (p[i].kind != SP_FRAGMENT_LOST && (!flagged || p[i].kind == SP_FRAGMENT_RECORD_START)) return p[i].offset;
        return end;
    }
};
}
sp_result PyrowaveInput::prepare(const sp_access_unit &input) {
    ranges.clear(); coded_bytes = 0; partial = false;
    if (!input.bytes || !input.size || input.size > MaxBytes || input.fragment_count > MaxFragments || (input.fragment_count && !input.fragments)) return SP_INVALID;
    try {
        const auto *bytes = static_cast<const uint8_t *>(input.bytes);
        const size_t total = input.size;
        require(total >= 8 && total % 4 == 0);
        Packets packets{input.fragments, input.fragment_count};
        size_t extent = 0;
        for (size_t i = 0; i < packets.count; ++i) {
            const auto &f = packets.p[i];
            require(f.offset == extent && f.size && f.size <= total - extent && f.kind <= SP_FRAGMENT_RECORD_START);
            packets.has_loss |= f.kind == SP_FRAGMENT_LOST; extent += f.size;
        }
        require(!packets.count || extent == total);
        require(input.critical_packets <= packets.count && !packets.lost(0, 8));
        // Missing critical transport packets cannot be supplied to the codec.
        // Their host-provided count avoids reconstructing codec block layout.
        for (size_t i = 0; i < input.critical_packets; ++i) require(packets.p[i].kind != SP_FRAGMENT_LOST);
        partial = packets.has_loss;
        const bool records = (le32(bytes) & 0x80000000u) != 0;
        const bool flagged = packets.count && packets.p[0].kind == SP_FRAGMENT_RECORD_START;
        const size_t payload_size = packets.count >= 2 ? size_t(packets.p[0].size) + 8 : std::numeric_limits<size_t>::max();
        bool aligned = false;
        auto keep = [&](size_t offset, size_t size) {
            if (!ranges.empty() && ranges.back().offset + ranges.back().size == offset) ranges.back().size += size;
            else ranges.push_back({offset, size});
        };
        auto walk = [&](size_t start, size_t end, bool allow_padding, bool allow_loss) {
            size_t cursor = start;
            while (cursor < end) {
                if (allow_loss && packets.lost(cursor, std::min(cursor + 8, end))) { cursor = flagged || aligned ? packets.next(cursor, flagged, end) : end; continue; }
                // Only bounded word-aligned complete records may reach native
                // typed loads. No sequence, block or coefficient checks here.
                require(cursor % 4 == 0 && end - cursor >= 8);
                const uint8_t *p = bytes + cursor;
                const uint32_t a = le32(p);
                size_t length = 8;
                if (a == UINT32_MAX) {
                    require(allow_padding);
                    const uint64_t padding = 8 + uint64_t(le32(p + 4)) * 4;
                    require(padding <= end - cursor);
                    cursor += size_t(padding); continue;
                }
                if (!(a & 0x80000000u)) {
                    length = size_t((a >> 16) & 4095) * 4;
                    require(length >= 8 && length <= end - cursor);
                    if (allow_loss && packets.lost(cursor, cursor + length)) { aligned = false; cursor += length; continue; }
                    coded_bytes += length;
                    aligned = packets.has_loss && length + 8 <= payload_size && packets.one(cursor, cursor + length);
                }
                keep(cursor, length); cursor += length;
            }
        };
        if (records) walk(0, total, true, true);
        else {
            require(!packets.has_loss);
            const uint32_t count = le32(bytes); require(count && count <= (total - 4) / 12);
            size_t cursor = 4;
            for (uint32_t i = 0; i < count; ++i) {
                require(total - cursor >= 4); const size_t size = le32(bytes + cursor); cursor += 4;
                require(size >= 8 && size % 4 == 0 && size <= total - cursor);
                walk(cursor, cursor + size, false, false); cursor += size;
            }
            require(cursor == total);
        }
        return SP_OK;
    } catch (const Invalid &) { ranges.clear(); coded_bytes = 0; partial = false; return SP_MALFORMED; }
}
}
