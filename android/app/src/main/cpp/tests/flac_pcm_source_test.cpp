#include "../flac_pcm_source.h"
#include <FLAC/stream_encoder.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <unistd.h>
#include <vector>

namespace {
void check(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
struct Fixture {
    std::string path;
    std::vector<int32_t> input;
    const unsigned frames = 15000;
    Fixture(unsigned bits, unsigned rate, unsigned channels) {
        path = (std::filesystem::temp_directory_path() / "mornye-flac-XXXXXX").string();
        const int fd = mkstemp(path.data());
        check(fd >= 0, "create fixture");
        close(fd);
        // Include signs, extrema, and nonzero low bits that 16-bit decoding
        // would discard. Different channels exercise FLAC decorrelation too.
        const int32_t maximum = static_cast<int32_t>((uint32_t{1} << (bits - 1)) - 1);
        const int32_t minimum = -maximum - 1;
        const std::array<int32_t, 8> values{0, 1, -1, maximum, minimum, 0x1235, -0x1235, 127};
        for (unsigned i = 0; i < frames * channels; ++i) input.push_back(values[i % values.size()]);
        auto *encoder = FLAC__stream_encoder_new();
        check(encoder != nullptr, "allocate encoder");
        check(FLAC__stream_encoder_set_channels(encoder, channels) &&
              FLAC__stream_encoder_set_bits_per_sample(encoder, bits) &&
              FLAC__stream_encoder_set_sample_rate(encoder, rate) &&
              FLAC__stream_encoder_set_blocksize(encoder, 4096), "configure fixture");
        check(FLAC__stream_encoder_init_file(encoder, path.c_str(), nullptr, nullptr) ==
              FLAC__STREAM_ENCODER_INIT_STATUS_OK, "open fixture");
        check(FLAC__stream_encoder_process_interleaved(encoder, input.data(), frames), "encode fixture");
        check(FLAC__stream_encoder_finish(encoder), "finish fixture");
        FLAC__stream_encoder_delete(encoder);
    }
    ~Fixture() { std::remove(path.c_str()); }
};

void compare(FlacPcmSource &source, const Fixture &fixture, uint64_t first, int outputBits) {
    // Deliberately split decoded blocks across many small, unaligned buffers.
    std::array<uint8_t, 269> data{};
    size_t sample = static_cast<size_t>(first) * source.channels;
    size_t count = 0;
    std::string error;
    while (true) {
        check(source.read(data.data(), data.size(), outputBits, &count, &error), error.c_str());
        if (count == 0) break;
        const size_t bytes = outputBits / 8;
        check(count % (bytes * source.channels) == 0, "unaligned output");
        for (size_t offset = 0; offset < count; offset += bytes, ++sample) {
            check(sample < fixture.input.size(), "extra decoded samples");
            const uint32_t expected = static_cast<uint32_t>(fixture.input[sample]) << (outputBits - source.bits);
            for (size_t byte = 0; byte < bytes; ++byte) {
                check(data[offset + byte] == static_cast<uint8_t>(expected >> (byte * 8)),
                      "sample precision changed");
            }
        }
    }
    check(sample == fixture.input.size(), "missing decoded samples");
}

void preservesPrecisionAndSeeks(unsigned bits, unsigned rate, unsigned channels) {
    Fixture fixture(bits, rate, channels);
    FlacPcmSource source;
    std::string error;
    check(source.open(fixture.path.c_str(), &error), error.c_str());
    check(source.bits == static_cast<int>(bits) && source.rate == static_cast<int>(rate) &&
          source.channels == static_cast<int>(channels) && source.samples == fixture.frames,
          "source format changed");
    for (int output : {16, 24, 32}) {
        if (output < static_cast<int>(bits)) continue;
        for (uint64_t first : {0u, 5001u, 14999u, 15000u, 17u, 4096u, 4097u}) {
            check(source.seek(first, &error), error.c_str());
            compare(source, fixture, first, output);
        }
    }
    if (bits > 16) {
        std::array<uint8_t, 256> data{};
        size_t count = 0;
        const bool ok = source.read(data.data(), data.size(), 16, &count, &error);
        check(!ok, "silently reduced output precision");
    }
}

void rejectsTruncatedData() {
    Fixture fixture(24, 96000, 2);
    std::filesystem::resize_file(fixture.path, std::filesystem::file_size(fixture.path) / 2);
    FlacPcmSource source;
    std::string error;
    bool rejected = !source.open(fixture.path.c_str(), &error);
    if (!rejected) {
        std::array<uint8_t, 256> data{};
        size_t count = 0;
        while (true) {
            if (!source.read(data.data(), data.size(), 24, &count, &error)) {
                rejected = true;
                break;
            }
            if (count == 0) break;
        }
    }
    check(rejected, "accepted truncated audio");
}

void retainsDescriptor() {
    Fixture fixture(24, 96000, 2);
    auto *file = std::fopen(fixture.path.c_str(), "rb");
    check(file != nullptr, "open descriptor fixture");
#ifdef __ANDROID__
    const auto path = "/proc/self/fd/" + std::to_string(fileno(file));
#else
    const auto path = "/dev/fd/" + std::to_string(fileno(file));
#endif
    FlacPcmSource source;
    std::string error;
    check(source.open(path.c_str(), &error), error.c_str());
    std::fclose(file);
    compare(source, fixture, 0, 32);
    check(source.seek(5001, &error), error.c_str());
    compare(source, fixture, 5001, 24);
}

void reportsFailedAllocation() {
    PcmBuffer<int32_t> buffer;
    check(buffer.resize(8), "allocate buffer");
    buffer[7] = 42;
    const size_t impossible = std::numeric_limits<size_t>::max() / sizeof(int32_t);
    check(!buffer.resize(impossible), "accepted an impossible size");
    check(buffer.size() == 8 && buffer[7] == 42, "failed growth changed the buffer");
}
}

int main() {
    try {
        for (unsigned channels : {1u, 2u}) {
            preservesPrecisionAndSeeks(16, 44100, channels);
            preservesPrecisionAndSeeks(24, 96000, channels);
            preservesPrecisionAndSeeks(32, 192000, channels);
        }
        rejectsTruncatedData();
        retainsDescriptor();
        reportsFailedAllocation();
        std::cout << "FLAC integer precision, padding, seek, EOF and truncation checks passed\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
