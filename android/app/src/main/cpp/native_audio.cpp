#include <jni.h>
#include <oboe/Oboe.h>
#include <wavpack.h>
#include "flac_pcm_source.h"
#include "pcm_buffer.h"

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
bool fail(std::string *errorOut, const char *message) {
    if (errorOut) *errorOut = message;
    return false;
}
void appendFmt(std::string &out, const char *fmt, ...) {
    char buf[256];
    va_list args;
    va_start(args, fmt);
    const int written = std::vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (written > 0) {
        const size_t len = static_cast<size_t>(written) < sizeof(buf)
            ? static_cast<size_t>(written)
            : sizeof(buf) - 1;
        out.append(buf, len);
    }
}
void report(JNIEnv *env, const std::string &message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message.c_str());
}
void report(JNIEnv *env, const char *message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}

// Handles never expose raw pointers. A stale/double-close cannot dereference a
// freed stream; each JNI invocation retains ownership for its entire duration.
template <class T> class Handles {
    std::mutex mutex;
    std::unordered_map<jlong, std::shared_ptr<T>> values;
    jlong next = 1;
public:
    jlong add(std::shared_ptr<T> value) {
        std::lock_guard<std::mutex> lock(mutex);
        const auto id = next++;
        values.emplace(id, std::move(value));
        return id;
    }
    std::shared_ptr<T> get(jlong id, std::string *errorOut) {
        std::lock_guard<std::mutex> lock(mutex);
        auto it = values.find(id);
        if (it == values.end()) {
            fail(errorOut, "Native audio handle closed");
            return nullptr;
        }
        return it->second;
    }
    void remove(jlong id) {
        std::shared_ptr<T> old;
        {
            std::lock_guard<std::mutex> lock(mutex);
            auto it = values.find(id);
            if (it != values.end()) { old = std::move(it->second); values.erase(it); }
        }
    }
};

class ExclusiveOutput final : public oboe::AudioStreamDataCallback {
    std::shared_ptr<oboe::AudioStream> stream;
    // Single producer (Kotlin worker), single consumer (audio callback).
    PcmBuffer<uint8_t> ring;
    std::atomic<uint64_t> read{0}, written{0}, musicFrames{0};
    std::atomic<int64_t> lastMusicEnd{0};
    int64_t callbackFrames = 0;
    int frameBytes = 0;
    bool floatOutput = false;
    int64_t frameBase = 0;
public:
    int bits = 0;
    int deviceId() const { return stream->getDeviceId(); }
    ExclusiveOutput() = default;
    bool open(int rate, int channels, int precision, int device, std::string *errorOut) {
        if (rate < 8000 || rate > 768000 || channels < 1 || channels > 2) {
            return fail(errorOut, "Unsupported hi-res format");
        }
        if (precision != 16 && precision != 24 && precision != 32) {
            return fail(errorOut, "Unsupported PCM precision");
        }
        std::vector<oboe::AudioFormat> formats;
        if (precision == 16) formats.push_back(oboe::AudioFormat::I16);
        if (precision <= 24) formats.push_back(oboe::AudioFormat::I24);
        formats.push_back(oboe::AudioFormat::I32);
        if (precision <= 24) formats.push_back(oboe::AudioFormat::Float);
        std::string attempts;
        attempts.reserve(256);
        appendFmt(attempts, "Exact-rate AAudio exclusive output unavailable: requested=%dHz/%dch/%dbit, device=%d",
                  rate, channels, precision, device);
        for (auto format : formats) {
            oboe::AudioStreamBuilder builder;
            builder.setDirection(oboe::Direction::Output)
                ->setAudioApi(oboe::AudioApi::AAudio)
                ->setSharingMode(oboe::SharingMode::Exclusive)
                ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
                ->setUsage(oboe::Usage::Media)
                ->setContentType(oboe::ContentType::Music)
                ->setSampleRate(rate)->setChannelCount(channels)->setFormat(format)
                ->setDeviceId(device)->setDataCallback(this)
                ->setChannelConversionAllowed(false)->setFormatConversionAllowed(false)
                ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::None);
            const auto result = builder.openStream(stream);
            appendFmt(attempts, "; format=%s", oboe::convertToText(format));
            if (result != oboe::Result::OK) {
                appendFmt(attempts, " open=%s", oboe::convertToText(result));
                continue;
            }
            // Exclusive is a request: Android can silently return Shared. Reject
            // that stream instead of displaying a misleading exclusive badge.
            if (stream->getAudioApi() == oboe::AudioApi::AAudio &&
                stream->getSharingMode() == oboe::SharingMode::Exclusive &&
                stream->getSampleRate() == rate && stream->getChannelCount() == channels &&
                stream->getFormat() == format && (device == 0 || stream->getDeviceId() == device)) {
                floatOutput = format == oboe::AudioFormat::Float;
                bits = format == oboe::AudioFormat::I16 ? 16 : format == oboe::AudioFormat::I24 ? 24 : 32;
                frameBytes = channels * (bits / 8);
                if (!ring.resize(static_cast<size_t>(rate / 4) * frameBytes)) {
                    return fail(errorOut, "Cannot allocate output buffer");
                }
                return true;
            }
            appendFmt(attempts, " actual=%s/%dHz/%dch/%s, api=%s, device=%d",
                      oboe::convertToText(stream->getSharingMode()),
                      stream->getSampleRate(),
                      stream->getChannelCount(),
                      oboe::convertToText(stream->getFormat()),
                      oboe::convertToText(stream->getAudioApi()),
                      stream->getDeviceId());
            stream->close();
            stream.reset();
        }
        if (errorOut) *errorOut = std::move(attempts);
        return false;
    }
    ~ExclusiveOutput() override { if (stream) stream->close(); }

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream *, void *audio, int32_t frames) override {
        const auto r = read.load(std::memory_order_relaxed);
        const auto w = written.load(std::memory_order_acquire);
        const size_t requested = static_cast<size_t>(frames) * frameBytes;
        const size_t available = std::min<uint64_t>(requested, w - r);
        const size_t start = r % ring.size();
        const size_t first = std::min(available, ring.size() - start);
        auto *out = static_cast<uint8_t *>(audio);
        std::memcpy(out, ring.data() + start, first);
        std::memcpy(out + first, ring.data(), available - first);
        std::memset(out + available, 0, requested - available);
        read.store(r + available, std::memory_order_release);
        musicFrames.fetch_add(available / frameBytes, std::memory_order_relaxed);
        if (available > 0) lastMusicEnd.store(frameBase + callbackFrames + available / frameBytes, std::memory_order_release);
        callbackFrames += frames;
        return oboe::DataCallbackResult::Continue;
    }
    bool check(std::string *errorOut) {
        if (!stream || stream->getState() == oboe::StreamState::Disconnected ||
            stream->getState() == oboe::StreamState::Closed) {
            return fail(errorOut, "AAudio output disconnected");
        }
        return true;
    }
    bool write(const uint8_t *data, size_t size, int *writtenOut, std::string *errorOut) {
        if (!check(errorOut)) return false;
        if (size % frameBytes != 0) return fail(errorOut, "Unaligned PCM buffer");
        auto w = written.load(std::memory_order_relaxed);
        auto r = read.load(std::memory_order_acquire);
        size = std::min<uint64_t>(size, ring.size() - (w - r)) / frameBytes * frameBytes;
        for (size_t offset = 0; offset < size;) {
            const size_t index = (w + offset) % ring.size();
            const size_t count = std::min(size - offset, ring.size() - index);
            if (floatOutput) {
                // Integer <=24-bit samples padded to I32 have an exact float
                // representation. Never use this path for 32-bit source audio.
                for (size_t sample = 0; sample < count; sample += 4) {
                    int32_t integer;
                    std::memcpy(&integer, data + offset + sample, 4);
                    const float value = static_cast<float>(integer) * (1.0f / 2147483648.0f);
                    std::memcpy(ring.data() + index + sample, &value, 4);
                }
            } else std::memcpy(ring.data() + index, data + offset, count);
            offset += count;
        }
        written.store(w + size, std::memory_order_release);
        if (writtenOut) *writtenOut = static_cast<int>(size);
        return true;
    }
    bool start(std::string *errorOut) {
        if (!check(errorOut)) return false;
        if (stream->requestStart() != oboe::Result::OK) {
            return fail(errorOut, "AAudio start failed");
        }
        return true;
    }
    bool flush(std::string *errorOut) {
        if (!check(errorOut)) return false;
        // Wait for the callback to stop before resetting its ring/counters.
        const auto state = stream->getState();
        if (state != oboe::StreamState::Open && state != oboe::StreamState::Flushed) {
            if (stream->pause(2000000000LL) != oboe::Result::OK) {
                return fail(errorOut, "AAudio pause failed");
            }
            if (stream->flush(2000000000LL) != oboe::Result::OK) {
                return fail(errorOut, "AAudio flush failed");
            }
        }
        read.store(0); written.store(0); musicFrames.store(0);
        frameBase = stream->getFramesWritten();
        callbackFrames = 0;
        lastMusicEnd.store(frameBase);
        return true;
    }
    bool frames(int64_t *framesOut, std::string *errorOut) {
        if (!check(errorOut)) return false;
        int64_t presented = 0, nanos = 0;
        auto music = static_cast<int64_t>(musicFrames.load(std::memory_order_relaxed));
        if (stream->getTimestamp(CLOCK_MONOTONIC, &presented, &nanos) == oboe::Result::OK) {
            const auto pending = std::max<int64_t>(0, lastMusicEnd.load(std::memory_order_acquire) - presented);
            if (framesOut) *framesOut = std::max<int64_t>(0, music - pending);
            return true;
        }
        // A timestamp may not exist until the first hardware burst completes.
        if (framesOut) *framesOut = 0;
        return true;
    }
};

class DsdDecoder {
public:
    WavpackContext *context = nullptr;
    int channels = 0;
    int rate = 0;
    int64_t samples = 0;
    PcmBuffer<int32_t> unpackScratch;
    PcmBuffer<jbyte> byteScratch;
    DsdDecoder() = default;
    bool open(const char *path, std::string *errorOut) {
        char error[80]{};
        context = WavpackOpenFileInput(path, error, OPEN_DSD_NATIVE | OPEN_ALT_TYPES, 0);
        if (!context) return fail(errorOut, "Cannot open WavPack file");
        channels = WavpackGetNumChannels(context);
        rate = static_cast<int>(WavpackGetNativeSampleRate(context));
        samples = WavpackGetNumSamples64(context);
        return true;
    }
    ~DsdDecoder() { if (context) WavpackCloseFile(context); }
    bool isDsd() const { return (WavpackGetQualifyMode(context) & QMODE_DSD_AUDIO) != 0; }
};
Handles<ExclusiveOutput> outputs;
Handles<DsdDecoder> decoders;
Handles<FlacPcmSource> flacSources;
}

#define JNI_AUDIO(name) Java_com_zarz_mornye_NativeAudio_##name
extern "C" {
JNIEXPORT jlong JNICALL JNI_AUDIO(openOboe)(JNIEnv *env, jobject, jint rate, jint channels, jint bits, jint device) {
    auto output = std::make_shared<ExclusiveOutput>();
    std::string error;
    if (!output->open(rate, channels, bits, device, &error)) {
        report(env, error);
        return 0;
    }
    return outputs.add(std::move(output));
}
JNIEXPORT jint JNICALL JNI_AUDIO(bitsOboe)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto output = outputs.get(handle, &error);
    if (!output) { report(env, error); return 0; }
    return output->bits;
}
JNIEXPORT jint JNICALL JNI_AUDIO(deviceOboe)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto output = outputs.get(handle, &error);
    if (!output) { report(env, error); return 0; }
    return output->deviceId();
}
JNIEXPORT jint JNICALL JNI_AUDIO(writeOboe)(JNIEnv *env, jobject, jlong handle, jobject buffer, jint offset, jint count) {
    auto *data = static_cast<uint8_t *>(env->GetDirectBufferAddress(buffer));
    auto size = env->GetDirectBufferCapacity(buffer);
    if (!data || offset < 0 || count < 0 || count > 262144 || offset > size || count > size - offset) {
        report(env, "Invalid PCM buffer");
        return 0;
    }
    std::string error;
    auto output = outputs.get(handle, &error);
    if (!output) { report(env, error); return 0; }
    int written = 0;
    if (!output->write(data + offset, static_cast<size_t>(count), &written, &error)) {
        report(env, error);
        return 0;
    }
    return written;
}
JNIEXPORT void JNICALL JNI_AUDIO(startOboe)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto output = outputs.get(handle, &error);
    if (!output || !output->start(&error)) report(env, error);
}
JNIEXPORT void JNICALL JNI_AUDIO(flushOboe)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto output = outputs.get(handle, &error);
    if (!output || !output->flush(&error)) report(env, error);
}
JNIEXPORT jlong JNICALL JNI_AUDIO(framesOboe)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto output = outputs.get(handle, &error);
    int64_t count = 0;
    if (!output || !output->frames(&count, &error)) { report(env, error); return 0; }
    return count;
}
JNIEXPORT void JNICALL JNI_AUDIO(closeOboe)(JNIEnv *, jobject, jlong handle) { outputs.remove(handle); }
JNIEXPORT jlong JNICALL JNI_AUDIO(openWavPack)(JNIEnv *env, jobject, jstring path) {
    const char *text = env->GetStringUTFChars(path, nullptr);
    if (!text) return 0;
    auto decoder = std::make_shared<DsdDecoder>();
    std::string error;
    const bool opened = decoder->open(text, &error);
    env->ReleaseStringUTFChars(path, text);
    if (!opened) { report(env, error); return 0; }
    if (!decoder->isDsd()) return 0; // PCM WavPack uses ordinary playback.
    if (decoder->channels < 1 || decoder->channels > 2 || decoder->samples <= 0 ||
        decoder->samples > std::numeric_limits<int64_t>::max() / 8000000 ||
        (decoder->rate != 2822400 && decoder->rate != 5644800 && decoder->rate != 11289600 && decoder->rate != 22579200)) {
        report(env, "Unsupported WavPack DSD format");
        return 0;
    }
    return decoders.add(std::move(decoder));
}
JNIEXPORT jlongArray JNICALL JNI_AUDIO(infoWavPack)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto d = decoders.get(handle, &error);
    if (!d) { report(env, error); return nullptr; }
    jlong data[]{d->rate, d->channels, d->samples};
    auto result = env->NewLongArray(3);
    if (result) env->SetLongArrayRegion(result, 0, 3, data);
    return result;
}
JNIEXPORT jbyteArray JNICALL JNI_AUDIO(readWavPack)(JNIEnv *env, jobject, jlong handle, jint frames) {
    if (frames <= 0 || frames > 16384) {
        report(env, "Invalid DSD read size");
        return nullptr;
    }
    std::string error;
    auto d = decoders.get(handle, &error);
    if (!d) { report(env, error); return nullptr; }
    auto &data = d->unpackScratch;
    auto &bytes = d->byteScratch;
    const size_t requested = static_cast<size_t>(frames) * d->channels;
    if ((data.size() < requested && !data.resize(requested)) ||
        (bytes.size() < requested && !bytes.resize(requested))) {
        report(env, "Cannot allocate DSD buffer");
        return nullptr;
    }
    auto count = WavpackUnpackSamples(d->context, data.data(), frames);
    if (WavpackGetNumErrors(d->context) != 0) {
        report(env, "Corrupt WavPack DSD data");
        return nullptr;
    }
    if (count == 0 && WavpackGetSampleIndex64(d->context) < d->samples) {
        report(env, "Truncated WavPack DSD data");
        return nullptr;
    }
    const size_t total = static_cast<size_t>(count) * d->channels;
    // OPEN_DSD_NATIVE returns interleaved, MSB-first DSD bytes regardless
    // of the wrapper's original DSF bit-order/blocking flags.
    for (size_t i = 0; i < total; ++i) bytes[i] = static_cast<jbyte>(data[i]);
    auto result = env->NewByteArray(static_cast<jsize>(total));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(total), bytes.data());
    return result;
}
JNIEXPORT void JNICALL JNI_AUDIO(seekWavPack)(JNIEnv *env, jobject, jlong handle, jlong sample) {
    std::string error;
    auto d = decoders.get(handle, &error);
    if (!d) { report(env, error); return; }
    if (sample < 0 || sample >= d->samples || !WavpackSeekSample64(d->context, sample)) {
        report(env, "WavPack DSD seek failed");
    }
}
JNIEXPORT void JNICALL JNI_AUDIO(closeWavPack)(JNIEnv *, jobject, jlong handle) { decoders.remove(handle); }
JNIEXPORT jlong JNICALL JNI_AUDIO(openFlac)(JNIEnv *env, jobject, jstring path) {
    const char *text = env->GetStringUTFChars(path, nullptr);
    if (!text) return 0;
    auto source = std::make_shared<FlacPcmSource>();
    std::string error;
    const bool opened = source->open(text, &error);
    env->ReleaseStringUTFChars(path, text);
    if (!opened) { report(env, error); return 0; }
    return flacSources.add(std::move(source));
}
JNIEXPORT jlongArray JNICALL JNI_AUDIO(infoFlac)(JNIEnv *env, jobject, jlong handle) {
    std::string error;
    auto source = flacSources.get(handle, &error);
    if (!source) { report(env, error); return nullptr; }
    jlong data[]{source->rate, source->channels, source->bits, static_cast<jlong>(source->samples)};
    auto result = env->NewLongArray(4);
    if (result) env->SetLongArrayRegion(result, 0, 4, data);
    return result;
}
JNIEXPORT jint JNICALL JNI_AUDIO(readFlac)(JNIEnv *env, jobject, jlong handle, jobject buffer, jint bits) {
    auto *data = static_cast<uint8_t *>(env->GetDirectBufferAddress(buffer));
    const auto capacity = env->GetDirectBufferCapacity(buffer);
    if (!data || capacity <= 0 || capacity > 262144) {
        report(env, "Invalid FLAC PCM buffer");
        return 0;
    }
    std::string error;
    auto source = flacSources.get(handle, &error);
    if (!source) { report(env, error); return 0; }
    size_t readBytes = 0;
    if (!source->read(data, static_cast<size_t>(capacity), bits, &readBytes, &error)) {
        report(env, error);
        return 0;
    }
    return static_cast<jint>(readBytes);
}
JNIEXPORT void JNICALL JNI_AUDIO(seekFlac)(JNIEnv *env, jobject, jlong handle, jlong sample) {
    if (sample < 0) { report(env, "Invalid FLAC seek position"); return; }
    std::string error;
    auto source = flacSources.get(handle, &error);
    if (!source || !source->seek(static_cast<uint64_t>(sample), &error)) {
        report(env, error);
    }
}
JNIEXPORT void JNICALL JNI_AUDIO(closeFlac)(JNIEnv *, jobject, jlong handle) { flacSources.remove(handle); }
}
