#pragma once
#include "include/SPyrowave.h"
#include <vector>

namespace swiftlight {
struct PyrowaveRange { size_t offset, size; };
// Strip only Vibepollo's transport envelope. Codec contents and decode readiness
// belong to the pinned PyroWave decoder. Ranges borrow the submitted access unit.
class PyrowaveInput {
public:
    std::vector<PyrowaveRange> ranges;
    uint64_t coded_bytes = 0;
    bool partial = false;
    sp_result prepare(const sp_access_unit &);
};
}
