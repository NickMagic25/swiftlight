// Test-only deterministic fixture encoder. Never linked into the application.
#include "pyrowave_metal.h"
#import <Metal/Metal.h>
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <vector>

static void require(bool value, const char *message)
{
    if (!value) { std::cerr << message << '\n'; std::exit(1); }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        require(argc == 6, "Usage: writer width height chroma(420|444) budget-bytes output.bin");
        const int width = std::atoi(argv[1]), height = std::atoi(argv[2]);
        const bool chroma444 = std::atoi(argv[3]) == 444;
        const size_t budget = std::strtoull(argv[4], nullptr, 10);
        require(width > 0 && height > 0 && width <= 16384 && height <= 16384 && budget > 0,
                "Invalid fixture dimensions or budget");
        pyrowave_device device = nullptr;
        require(pyrowave_create_default_device(&device) == PYROWAVE_SUCCESS, "Apple7 Metal device unavailable");
        pyrowave_encoder_create_info info{device, width, height,
            chroma444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420};
        pyrowave_encoder encoder = nullptr;
        require(pyrowave_encoder_create(&info, &encoder) == PYROWAVE_SUCCESS, "Encoder create failed");
        std::vector<uint8_t> samples[3];
        pyrowave_cpu_buffer input{};
        input.width = width; input.height = height;
        input.format = chroma444 ? PYROWAVE_CPU_BUFFER_FORMAT_YUV444P : PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;
        for (int plane = 0; plane < 3; ++plane) {
            const int w = plane && !chroma444 ? width / 2 : width;
            const int h = plane && !chroma444 ? height / 2 : height;
            samples[plane].resize(size_t(w) * h);
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
                const int dx = std::max(1, w - 1), dy = std::max(1, h - 1);
                samples[plane][size_t(y) * w + x] = uint8_t(plane == 0 ? 32 + 96 * x / dx + 96 * y / dy :
                    plane == 1 ? 64 + 64 * x / dx + 32 * y / dy : 160 - 48 * x / dx + 32 * y / dy);
            }
            input.data[plane] = samples[plane].data();
            input.row_stride_in_bytes[plane] = size_t(w);
            input.plane_size_in_bytes[plane] = samples[plane].size();
        }
        pyrowave_rate_control rate{budget};
        require(pyrowave_encoder_encode_cpu_synchronous(encoder, &input, &rate) == PYROWAVE_SUCCESS, "Encode failed");
        size_t count = 0;
        require(pyrowave_encoder_compute_num_packets(encoder, 1024, &count) == PYROWAVE_SUCCESS, "Packet count failed");
        std::vector<pyrowave_packet> packets(count);
        std::vector<uint8_t> bytes(size_t(width) * height * 16 + 65536);
        require(pyrowave_encoder_packetize(encoder, packets.data(), 1024, &count, bytes.data(), bytes.size()) == PYROWAVE_SUCCESS, "Packetization failed");
        size_t end = 0;
        for (size_t i = 0; i < count; ++i) end = std::max(end, packets[i].offset + packets[i].size);
        std::ofstream output(argv[5], std::ios::binary);
        require(bool(output.write(reinterpret_cast<const char *>(bytes.data()), std::streamsize(end))), "Fixture write failed");
        pyrowave_encoder_destroy(encoder); pyrowave_device_destroy(device);
        std::cout << width << 'x' << height << " chroma=" << (chroma444 ? 444 : 420)
                  << " bytes=" << end << " packets=" << count << '\n';
    }
}
