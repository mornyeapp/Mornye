#include "flac_pcm_source.h"

#include <algorithm>
#include <limits>

namespace {
bool fail(std::string *errorOut, const char *message) {
    if (errorOut) *errorOut = message ? message : "FLAC decode failed";
    return false;
}
}

void FlacPcmSource::DeleteDecoder::operator()(FLAC__StreamDecoder *value) const {
    FLAC__stream_decoder_finish(value);
    FLAC__stream_decoder_delete(value);
}

bool FlacPcmSource::open(const char *path, std::string *errorOut) {
    decoder.reset(FLAC__stream_decoder_new());
    if (!decoder) return fail(errorOut, "Cannot allocate FLAC decoder");
    if (FLAC__stream_decoder_init_file(decoder.get(), path, write, metadata, error, this) !=
        FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        return fail(errorOut, "Cannot open FLAC file");
    }
    if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder.get()) || failure) {
        return fail(errorOut, "Cannot read FLAC metadata");
    }
    if (rate < 8000 || rate > 768000 || channels < 1 || channels > 2 ||
        (bits != 16 && bits != 24 && bits != 32) ||
        samples > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) / 1000000) {
        return fail(errorOut, "Unsupported FLAC PCM format");
    }
    return true;
}

void FlacPcmSource::metadata(const FLAC__StreamDecoder *, const FLAC__StreamMetadata *value, void *data) {
    if (value->type != FLAC__METADATA_TYPE_STREAMINFO) return;
    auto &source = *static_cast<FlacPcmSource *>(data);
    const auto &info = value->data.stream_info;
    source.rate = static_cast<int>(info.sample_rate);
    source.channels = static_cast<int>(info.channels);
    source.bits = static_cast<int>(info.bits_per_sample);
    source.samples = info.total_samples;
}

FLAC__StreamDecoderWriteStatus FlacPcmSource::write(
    const FLAC__StreamDecoder *, const FLAC__Frame *frame, const FLAC__int32 *const input[], void *data) {
    auto &source = *static_cast<FlacPcmSource *>(data);
    const auto &header = frame->header;
    if (header.sample_rate != static_cast<unsigned>(source.rate) ||
        header.channels != static_cast<unsigned>(source.channels) ||
        header.bits_per_sample != static_cast<unsigned>(source.bits) ||
        header.blocksize == 0 || header.blocksize > 65535) {
        source.failure = "FLAC format changed during decoding";
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    if (!source.block.resize(static_cast<size_t>(header.blocksize) * source.channels)) {
        source.failure = "Cannot allocate FLAC block";
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    source.offset = 0;
    for (size_t i = 0; i < header.blocksize; ++i) {
        for (int channel = 0; channel < source.channels; ++channel) {
            source.block[i * source.channels + channel] = input[channel][i];
        }
    }
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

void FlacPcmSource::error(const FLAC__StreamDecoder *, FLAC__StreamDecoderErrorStatus, void *data) {
    static_cast<FlacPcmSource *>(data)->failure = "Corrupt FLAC audio data";
}

bool FlacPcmSource::read(
    uint8_t *output, size_t capacity, int outputBits, size_t *bytesRead, std::string *errorOut) {
    if (bytesRead) *bytesRead = 0;
    if (outputBits < bits || (outputBits != 16 && outputBits != 24 && outputBits != 32)) {
        return fail(errorOut, "FLAC output would reduce precision");
    }
    const size_t bytes = outputBits / 8;
    const size_t frameBytes = channels * bytes;
    if (!output || capacity < frameBytes) {
        return fail(errorOut, "Invalid FLAC output buffer");
    }
    if (end) return true;
    while (offset == block.size()) {
        if (failure) return fail(errorOut, failure);
        if (FLAC__stream_decoder_get_state(decoder.get()) == FLAC__STREAM_DECODER_END_OF_STREAM) {
            if (samples != 0 && position != samples) {
                return fail(errorOut, "Truncated FLAC audio data");
            }
            end = true;
            return true;
        }
        if (!FLAC__stream_decoder_process_single(decoder.get()) || failure) {
            return fail(errorOut, failure ? failure : "FLAC decode failed");
        }
    }
    const size_t frames = std::min(capacity / frameBytes, (block.size() - offset) / channels);
    const size_t count = frames * channels;
    for (size_t i = 0; i < count; ++i) {
        // Unsigned shifting preserves negative samples without signed-shift UB.
        const uint32_t value = static_cast<uint32_t>(block[offset + i]) << (outputBits - bits);
        for (size_t byte = 0; byte < bytes; ++byte) {
            output[i * bytes + byte] = static_cast<uint8_t>(value >> (byte * 8));
        }
    }
    offset += count;
    position += frames;
    if (bytesRead) *bytesRead = count * bytes;
    return true;
}

bool FlacPcmSource::seek(uint64_t sample, std::string *errorOut) {
    if (samples > 0) sample = std::min(sample, samples);
    block.clear();
    offset = 0;
    failure = nullptr;
    position = sample;
    end = samples > 0 && sample == samples;
    if (!end) {
        // libFLAC returns the partial target block through write(), preserving
        // the first requested sample even for seeks between frame boundaries.
        if (!FLAC__stream_decoder_seek_absolute(decoder.get(), sample) || failure) {
            return fail(errorOut, failure ? failure : "FLAC seek failed");
        }
    }
    return true;
}
