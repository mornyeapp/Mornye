#include <jni.h>

#ifdef MORNYE_DISCORD_SDK
#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>
#include <memory>
#include <string>

namespace {
std::unique_ptr<discordpp::Client> client;
int status = 0;
uint64_t generation = 0;

std::string utf8(JNIEnv* env, jstring value) {
    // JNI's modified UTF-8 corrupts supplementary Unicode (e.g. emoji).
    auto stringClass = env->FindClass("java/lang/String");
    auto getBytes = env->GetMethodID(stringClass, "getBytes", "(Ljava/lang/String;)[B");
    auto charset = env->NewStringUTF("UTF-8");
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(value, getBytes, charset));
    std::string result;
    if (bytes) {
        result.resize(env->GetArrayLength(bytes));
        env->GetByteArrayRegion(bytes, 0, static_cast<jsize>(result.size()),
                               reinterpret_cast<jbyte*>(result.data()));
        env->DeleteLocalRef(bytes);
    }
    env->DeleteLocalRef(charset);
    env->DeleteLocalRef(stringClass);
    return result;
}
}
#endif

#define JNI_METHOD(name) Java_com_zarz_mornye_discord_DiscordPresencePlugin_##name

extern "C" JNIEXPORT jboolean JNICALL JNI_METHOD(nativeStart)(JNIEnv*, jobject) {
#ifdef MORNYE_DISCORD_SDK
    if (!client) {
        client = std::make_unique<discordpp::Client>();
        client->SetApplicationId(1549854098801692862ULL);
        client->SetEngineManagedAudioSession(true);
        status = 0;
    }
    return true;
#else
    return false;
#endif
}

extern "C" JNIEXPORT jint JNICALL JNI_METHOD(nativeTick)(JNIEnv*, jobject) {
#ifdef MORNYE_DISCORD_SDK
    discordpp::RunCallbacks();
    return status;
#else
    return 2;
#endif
}

extern "C" JNIEXPORT void JNICALL JNI_METHOD(nativeUpdate)(
    [[maybe_unused]] JNIEnv* env, jobject,
    [[maybe_unused]] jstring title, [[maybe_unused]] jstring artist,
    [[maybe_unused]] jstring album, [[maybe_unused]] jstring artwork,
    [[maybe_unused]] jlong start, [[maybe_unused]] jlong end) {
#ifdef MORNYE_DISCORD_SDK
    if (!client) return;
    discordpp::Activity activity;
    activity.SetName(utf8(env, artist));
    activity.SetType(discordpp::ActivityTypes::Listening);
    activity.SetDetails(utf8(env, title));
    activity.SetState(utf8(env, artist));
    const auto image = utf8(env, artwork);
    if (!image.empty()) {
        discordpp::ActivityAssets assets;
        assets.SetLargeImage(image);
        activity.SetAssets(assets);
    }
    discordpp::ActivityTimestamps timestamps;
    if (start > 0) timestamps.SetStart(start);
    if (end > 0) timestamps.SetEnd(end);
    activity.SetTimestamps(timestamps);
    auto request = ++generation;
    client->UpdateRichPresence(activity, [request](discordpp::ClientResult result) {
        if (generation == request) status = result.Successful() ? 1 : 2;
    });
#endif
}

extern "C" JNIEXPORT void JNICALL JNI_METHOD(nativeClear)(JNIEnv*, jobject) {
#ifdef MORNYE_DISCORD_SDK
    ++generation;
    if (client) client->ClearRichPresence();
    status = 0;
#endif
}

extern "C" JNIEXPORT void JNICALL JNI_METHOD(nativeStop)(JNIEnv*, jobject) {
#ifdef MORNYE_DISCORD_SDK
    ++generation;
    if (client) {
        client->ClearRichPresence();
        client->Disconnect();
        discordpp::RunCallbacks();
        client.reset();
    }
    status = 0;
#endif
}
