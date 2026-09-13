// Fixture preparation only. Uses the pinned decoder's parser to describe AV1
// coded-frame boundaries; never linked into the app or used to decode video.
#include "bitstream.hpp"
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>
static unsigned le32(const unsigned char* p) {
    return unsigned(p[0]) | unsigned(p[1]) << 8 | unsigned(p[2]) << 16 | unsigned(p[3]) << 24;
}
int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: av1-split input.ivf");
        std::ifstream file(argv[1], std::ios::binary);
        std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(file)), {});
        if (bytes.size() < 32 || bytes.size() > 64 * 1024 * 1024 || std::string(bytes.begin(), bytes.begin() + 4) != "DKIF")
            throw std::runtime_error("invalid IVF");
        mav::Bitstream parser(mav::Codec::AV1);
        size_t position = 32;
        bool first = true;
        std::cout << "[";
        while (position < bytes.size()) {
            if (bytes.size() - position < 12) throw std::runtime_error("truncated IVF packet");
            const auto length = le32(bytes.data() + position);
            position += 12;
            if (!length || length > bytes.size() - position) throw std::runtime_error("invalid packet length");
            mav::Prepared parsed;
            std::string error;
            if (parser.prepare(bytes.data() + position, length, parsed, error) != mav::ParseResult::Ok)
                throw std::runtime_error(error);
            for (const auto& sample : parsed.samples) {
                if (!first) std::cout << ',';
                first = false;
                std::cout << "{\"offset\":" << position + sample.offset << ",\"length\":" << sample.size
                          << ",\"display\":" << sample.display << ",\"existing\":" << sample.show_existing
                          << ",\"random_access\":" << sample.random_access << "}";
            }
            position += length;
        }
        std::cout << "]\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
