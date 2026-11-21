#pragma once

#include <FLAC/stream_decoder.h>
#include "pcm_buffer.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

// Owns its file descriptor, decodes one FLAC block at a time, and never passes
// samples through Android's extractor (which may silently emit 16-bit PCM).
class FlacPcmSource final {
    struct DeleteDecoder {
        void operator()(FLAC__StreamDecoder *decoder) const;
    };
    std::unique_ptr<FLAC__StreamDecoder, DeleteDecoder> decoder;
    PcmBuffer<int32_t> block;
    size_t offset = 0;
    uint64_t position = 0;
    bool end = false;
    const char *failure = nullptr;

    static FLAC__StreamDecoderWriteStatus write(
        const FLAC__StreamDecoder *, const FLAC__Frame *, const FLAC__int32 *const[], void *);
    static void metadata(const FLAC__StreamDecoder *, const FLAC__StreamMetadata *, void *);
    static void error(const FLAC__StreamDecoder *, FLAC__StreamDecoderErrorStatus, void *);
public:
    int rate = 0;
    int channels = 0;
    int bits = 0;
    uint64_t samples = 0;

    FlacPcmSource() = default;
    bool open(const char *path, std::string *errorOut);
    bool read(uint8_t *output, size_t capacity, int outputBits, size_t *bytesRead, std::string *errorOut);
    bool seek(uint64_t sample, std::string *errorOut);
};
