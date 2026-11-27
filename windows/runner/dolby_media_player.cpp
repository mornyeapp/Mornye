#include "dolby_media_player.h"

#include <audiosessiontypes.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <mftransform.h>
#include <mmdeviceapi.h>
#include <oleauto.h>
#include <spatialaudioclient.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <utility>
#include <variant>

// winbase.h maps GetCurrentTime() to GetTickCount(), which breaks
// IMFMediaEngine::GetCurrentTime.
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif

using Microsoft::WRL::ComPtr;

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr wchar_t kWindowClass[] = L"MornyeDolbyMediaPlayers";
constexpr UINT kEngineEventMessage = WM_APP + 0x4D44;
constexpr char kChannel[] = "com.zarz.mornye/windows_media_player";

static_assert(sizeof(LPARAM) == 8 && sizeof(WPARAM) == 8,
              "Engine events are packed for 64-bit Windows.");

// An engine event in one LPARAM: the event in bits 48-63, its first
// parameter (an MF_MEDIA_ENGINE_ERR for errors) in 32-47, the second (an
// HRESULT for errors) in 0-31.
LPARAM PackEvent(DWORD event, DWORD_PTR param1, DWORD param2) {
  const uint64_t value = (static_cast<uint64_t>(event & 0xFFFF) << 48) |
                         (static_cast<uint64_t>(param1 & 0xFFFF) << 32) |
                         static_cast<uint64_t>(param2);
  return static_cast<LPARAM>(value);
}

// Receives media engine events on Media Foundation threads and posts them
// to the players' message window. It holds no pointer to a player, so an
// event for a player disposed meanwhile is simply dropped.
class EngineNotify : public IMFMediaEngineNotify {
 public:
  EngineNotify(HWND window, uint64_t serial)
      : window_(window), serial_(serial) {}

  STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
    if (object == nullptr) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMFMediaEngineNotify)) {
      *object = static_cast<IMFMediaEngineNotify*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  STDMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&references_));
  }

  STDMETHODIMP_(ULONG) Release() override {
    const LONG left = InterlockedDecrement(&references_);
    if (left == 0) delete this;
    return static_cast<ULONG>(left);
  }

  STDMETHODIMP EventNotify(DWORD event, DWORD_PTR param1,
                           DWORD param2) override {
    PostMessage(window_, kEngineEventMessage, static_cast<WPARAM>(serial_),
                PackEvent(event, param1, param2));
    return S_OK;
  }

 private:
  virtual ~EngineNotify() = default;

  LONG references_ = 1;
  HWND window_;
  uint64_t serial_;
};

const EncodableValue* Argument(const EncodableValue* arguments,
                               const char* key) {
  if (arguments == nullptr) return nullptr;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  const auto entry = map->find(EncodableValue(key));
  return entry == map->end() ? nullptr : &entry->second;
}

std::string StringArgument(const EncodableValue* arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  if (value == nullptr) return {};
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

bool BoolArgument(const EncodableValue* arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  if (value == nullptr) return false;
  const auto* flag = std::get_if<bool>(value);
  return flag != nullptr && *flag;
}

double NumberArgument(const EncodableValue* arguments, const char* key,
                      double fallback) {
  const auto* value = Argument(arguments, key);
  if (value == nullptr) return fallback;
  if (const auto* number = std::get_if<double>(value)) return *number;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<double>(*number);
  }
  return fallback;
}

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      result.data(), length);
  return result;
}

// Milliseconds for an engine time in seconds; -1 while it is unknown.
int64_t Milliseconds(double seconds) {
  if (!std::isfinite(seconds) || seconds <= 0) return -1;
  return static_cast<int64_t>(seconds * 1000.0 + 0.5);
}

std::string Hex(HRESULT hr) {
  char text[16];
  std::snprintf(text, sizeof(text), "0x%08lX", static_cast<unsigned long>(hr));
  return text;
}

// Media subtypes of the Dolby formats, written out so the check does not
// depend on the SDK version: MFAudioFormat_Dolby_DDPlus, and
// MFAudioFormat_Dolby_AC4 with its V1, V2, V1_ES and V2_ES variants.
constexpr GUID kDolbyDigitalPlus = {
    0xa7fb87af, 0x2d02, 0x42fb, {0xa4, 0xd4, 0x05, 0xcd, 0x93, 0x84, 0x3b, 0xdd}};
constexpr GUID kDolbyAc4[] = {
    {0x0000ac40, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}},
    {0x36b7927c, 0x3d87, 0x4a2a, {0x91, 0x96, 0xa2, 0x1a, 0xd9, 0xe9, 0x35, 0xe6}},
    {0x7998b2a0, 0x17dd, 0x49b6, {0x8d, 0xfa, 0x9b, 0x27, 0x85, 0x52, 0xa2, 0xac}},
    {0x9d8dccc6, 0xd156, 0x4fb8, {0x97, 0x9c, 0xa8, 0x5b, 0xe7, 0xd2, 0x1d, 0xfa}},
    {0x7e58c9f9, 0xb070, 0x45f4, {0x8c, 0xcd, 0xa9, 0x9a, 0x04, 0x17, 0xc1, 0xac}},
};

// Whether Media Foundation has a decoder for the audio [subtype]: one that
// ships with Windows, or one a PC maker installed (Dolby's AC-4 decoder is
// installed by PC makers only).
bool HasAudioDecoder(const GUID& subtype) {
  MFT_REGISTER_TYPE_INFO input = {MFMediaType_Audio, subtype};
  IMFActivate** activates = nullptr;
  UINT32 count = 0;
  const HRESULT hr = MFTEnumEx(
      MFT_CATEGORY_AUDIO_DECODER,
      MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
          MFT_ENUM_FLAG_SORTANDFILTER,
      &input, nullptr, &activates, &count);
  if (activates != nullptr) {
    for (UINT32 i = 0; i < count; ++i) activates[i]->Release();
    CoTaskMemFree(activates);
  }
  return SUCCEEDED(hr) && count > 0;
}

// Whether the default output renders spatial audio: a spatial sound format
// (Dolby Atmos for headphones, speakers or home theater, or Windows Sonic)
// is on. Without one, Dolby songs play their channel mix without Atmos.
bool SpatialSoundOn() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&enumerator)))) {
    return false;
  }
  ComPtr<IMMDevice> device;
  if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia,
                                                 &device))) {
    return false;
  }
  ComPtr<ISpatialAudioClient> client;
  if (FAILED(device->Activate(__uuidof(ISpatialAudioClient),
                              CLSCTX_INPROC_SERVER, nullptr,
                              reinterpret_cast<void**>(
                                  client.GetAddressOf())))) {
    return false;
  }
  UINT32 objects = 0;
  return SUCCEEDED(client->GetMaxDynamicObjectCount(&objects)) && objects > 0;
}

// The channel error code for an MF_MEDIA_ENGINE_ERR. `unsupported` tells
// the Dart side to play the song through libmpv instead.
const char* ErrorCode(DWORD error) {
  switch (error) {
    case MF_MEDIA_ENGINE_ERR_SRC_NOT_SUPPORTED:
    case MF_MEDIA_ENGINE_ERR_DECODE:
      return "unsupported";
    case MF_MEDIA_ENGINE_ERR_NETWORK:
      return "network";
    default:
      return "failed";
  }
}

}  // namespace

struct DolbyMediaPlayer {
  std::string id;
  uint64_t serial = 0;
  ComPtr<IMFMediaEngine> engine;
  ComPtr<IMFMediaEngineEx> engine_ex;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink;
  // setSource replies once the song can play, or fails.
  std::unique_ptr<flutter::MethodResult<EncodableValue>> pending;

  void Send(EncodableMap event) {
    if (sink) sink->Success(EncodableValue(std::move(event)));
  }

  void Supersede() {
    if (!pending) return;
    pending->Error("superseded", "A newer source replaced this one.");
    pending = nullptr;
  }
};

DolbyMediaPlayers::DolbyMediaPlayers(flutter::BinaryMessenger* messenger)
    : messenger_(messenger) {
  media_foundation_ = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_FULL));

  const HINSTANCE instance = GetModuleHandle(nullptr);
  WNDCLASSEX window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kWindowClass;
  RegisterClassEx(&window_class);
  window_ = CreateWindowEx(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                           nullptr, instance, nullptr);
  if (window_ != nullptr) {
    SetWindowLongPtr(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger_, kChannel, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleCall(call, std::move(result));
      });
}

DolbyMediaPlayers::~DolbyMediaPlayers() {
  channel_->SetMethodCallHandler(nullptr);
  while (!players_.empty()) Dispose(players_.begin()->first);
  if (window_ != nullptr) {
    SetWindowLongPtr(window_, GWLP_USERDATA, 0);
    DestroyWindow(window_);
    window_ = nullptr;
  }
  UnregisterClass(kWindowClass, GetModuleHandle(nullptr));
  if (media_foundation_) MFShutdown();
}

LRESULT CALLBACK DolbyMediaPlayers::WindowProc(HWND window, UINT message,
                                               WPARAM wparam, LPARAM lparam) {
  if (message == kEngineEventMessage) {
    auto* self = reinterpret_cast<DolbyMediaPlayers*>(
        GetWindowLongPtr(window, GWLP_USERDATA));
    if (self != nullptr) {
      self->OnEngineEvent(static_cast<uint64_t>(wparam), lparam);
    }
    return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

DolbyMediaPlayer* DolbyMediaPlayers::Find(const std::string& id) {
  const auto entry = players_.find(id);
  return entry == players_.end() ? nullptr : entry->second.get();
}

DolbyMediaPlayer* DolbyMediaPlayers::FindSerial(uint64_t serial) {
  for (auto& entry : players_) {
    if (entry.second->serial == serial) return entry.second.get();
  }
  return nullptr;
}

void DolbyMediaPlayers::Create(
    const std::string& id,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (!media_foundation_ || window_ == nullptr) {
    result->Error("unavailable", "Media Foundation is not available.");
    return;
  }
  if (Find(id) != nullptr) {
    result->Success();
    return;
  }
  auto player = std::make_unique<DolbyMediaPlayer>();
  player->id = id;
  player->serial = next_serial_++;

  ComPtr<IMFMediaEngineClassFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(hr)) hr = MFCreateAttributes(&attributes, 3);
  if (SUCCEEDED(hr)) {
    ComPtr<EngineNotify> notify;
    notify.Attach(new EngineNotify(window_, player->serial));
    hr = attributes->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = attributes->SetUINT32(MF_MEDIA_ENGINE_AUDIO_CATEGORY,
                               AudioCategory_Media);
  }
  if (SUCCEEDED(hr)) {
    hr = attributes->SetUINT32(MF_MEDIA_ENGINE_AUDIO_ENDPOINT_ROLE,
                               eMultimedia);
  }
  // Audio only: no window or video device. The engine plays through the
  // Streaming Audio Renderer, which hands Atmos to the spatial sound
  // format chosen in Windows' sound settings.
  if (SUCCEEDED(hr)) {
    hr = factory->CreateInstance(MF_MEDIA_ENGINE_AUDIOONLY, attributes.Get(),
                                 &player->engine);
  }
  if (SUCCEEDED(hr)) hr = player->engine.As(&player->engine_ex);
  if (SUCCEEDED(hr)) hr = player->engine->SetAutoPlay(FALSE);
  if (SUCCEEDED(hr)) {
    hr = player->engine->SetPreload(MF_MEDIA_ENGINE_PRELOAD_AUTOMATIC);
  }
  if (FAILED(hr)) {
    if (player->engine) player->engine->Shutdown();
    result->Error("unavailable",
                  "Could not create the Windows media engine (" + Hex(hr) +
                      ").");
    return;
  }

  DolbyMediaPlayer* raw = player.get();
  player->events = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger_, std::string(kChannel) + "/events/" + id,
      &flutter::StandardMethodCodec::GetInstance());
  player->events->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [raw](const EncodableValue* arguments,
                std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            raw->sink = std::move(events);
            return nullptr;
          },
          [raw](const EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            raw->sink = nullptr;
            return nullptr;
          }));
  players_[id] = std::move(player);
  result->Success();
}

void DolbyMediaPlayers::Dispose(const std::string& id) {
  const auto entry = players_.find(id);
  if (entry == players_.end()) return;
  DolbyMediaPlayer& player = *entry->second;
  player.Supersede();
  if (player.events) player.events->SetStreamHandler(nullptr);
  player.sink = nullptr;
  if (player.engine) player.engine->Shutdown();
  players_.erase(entry);
}

void DolbyMediaPlayers::HandleCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableValue* arguments = call.arguments();
  const std::string id = StringArgument(arguments, "playerId");

  if (method == "create") {
    Create(id, std::move(result));
    return;
  }
  if (method == "getCapabilities") {
    const bool available = media_foundation_;
    bool ac4 = false;
    for (const GUID& subtype : kDolbyAc4) {
      if (available && HasAudioDecoder(subtype)) {
        ac4 = true;
        break;
      }
    }
    EncodableMap reply;
    reply[EncodableValue("available")] = EncodableValue(available);
    reply[EncodableValue("dolbyDigitalPlus")] =
        EncodableValue(available && HasAudioDecoder(kDolbyDigitalPlus));
    reply[EncodableValue("ac4")] = EncodableValue(ac4);
    reply[EncodableValue("spatialSound")] = EncodableValue(SpatialSoundOn());
    result->Success(EncodableValue(std::move(reply)));
    return;
  }
  if (method == "dispose") {
    Dispose(id);
    result->Success();
    return;
  }
  DolbyMediaPlayer* player = Find(id);
  if (player == nullptr) {
    result->Error("missing", "No Windows media player with this id.");
    return;
  }
  IMFMediaEngine* engine = player->engine.Get();

  if (method == "setSource") {
    player->Supersede();
    engine->Pause();
    const std::wstring uri = Wide(StringArgument(arguments, "uri"));
    if (uri.empty()) {
      result->Error("unsupported", "No source.");
      return;
    }
    HRESULT hr = S_OK;
    BSTR url = SysAllocString(uri.c_str());
    if (BoolArgument(arguments, "isLocal")) {
      // A byte stream opens any Windows path, Unicode and long paths
      // included; the URL only tells the engine the file type.
      ComPtr<IMFByteStream> stream;
      hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                        MF_FILEFLAGS_ALLOW_WRITE_SHARING, uri.c_str(), &stream);
      if (SUCCEEDED(hr)) {
        hr = player->engine_ex->SetSourceFromByteStream(stream.Get(), url);
      }
    } else {
      hr = engine->SetSource(url);
    }
    SysFreeString(url);
    if (FAILED(hr)) {
      result->Error("unsupported",
                    "Windows could not open this song (" + Hex(hr) + ").");
      return;
    }
    player->pending = std::move(result);
    return;
  }
  if (method == "play") {
    const HRESULT hr = engine->Play();
    if (FAILED(hr)) {
      result->Error("failed", "Could not start playback (" + Hex(hr) + ").");
      return;
    }
    result->Success();
    return;
  }
  if (method == "pause") {
    engine->Pause();
    result->Success();
    return;
  }
  if (method == "stop" || method == "clearSource") {
    player->Supersede();
    engine->Pause();
    result->Success();
    return;
  }
  if (method == "seek") {
    const double milliseconds =
        std::max(0.0, NumberArgument(arguments, "positionMs", 0));
    engine->SetCurrentTime(milliseconds / 1000.0);
    result->Success();
    return;
  }
  if (method == "setVolume") {
    const double volume =
        std::clamp(NumberArgument(arguments, "volume", 1), 0.0, 1.0);
    engine->SetVolume(volume);
    result->Success();
    return;
  }
  if (method == "getPosition") {
    const double seconds = engine->GetCurrentTime();
    const int64_t position =
        std::isfinite(seconds) && seconds > 0
            ? static_cast<int64_t>(seconds * 1000.0 + 0.5)
            : 0;
    result->Success(EncodableValue(position));
    return;
  }
  if (method == "getDuration") {
    result->Success(EncodableValue(Milliseconds(engine->GetDuration())));
    return;
  }
  result->NotImplemented();
}

void DolbyMediaPlayers::OnEngineEvent(uint64_t serial, LPARAM packed) {
  DolbyMediaPlayer* player = FindSerial(serial);
  if (player == nullptr) return;
  const auto value = static_cast<uint64_t>(packed);
  const auto event = static_cast<DWORD>((value >> 48) & 0xFFFF);
  const auto param1 = static_cast<DWORD>((value >> 32) & 0xFFFF);
  const auto param2 =
      static_cast<HRESULT>(static_cast<uint32_t>(value & 0xFFFFFFFF));
  IMFMediaEngine* engine = player->engine.Get();

  switch (event) {
    case MF_MEDIA_ENGINE_EVENT_CANPLAY:
    case MF_MEDIA_ENGINE_EVENT_CANPLAYTHROUGH:
      if (player->pending) {
        EncodableMap reply;
        reply[EncodableValue("durationMs")] =
            EncodableValue(Milliseconds(engine->GetDuration()));
        player->pending->Success(EncodableValue(std::move(reply)));
        player->pending = nullptr;
      }
      break;
    case MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA:
    case MF_MEDIA_ENGINE_EVENT_DURATIONCHANGE: {
      const int64_t duration = Milliseconds(engine->GetDuration());
      if (duration > 0) {
        player->Send({{EncodableValue("event"), EncodableValue("duration")},
                      {EncodableValue("durationMs"), EncodableValue(duration)}});
      }
      break;
    }
    case MF_MEDIA_ENGINE_EVENT_PLAYING:
      player->Send({{EncodableValue("event"), EncodableValue("state")},
                    {EncodableValue("state"), EncodableValue("playing")}});
      break;
    case MF_MEDIA_ENGINE_EVENT_PAUSE:
      // The engine also pauses when a song ends; that reports completed.
      if (!engine->IsEnded()) {
        player->Send({{EncodableValue("event"), EncodableValue("state")},
                      {EncodableValue("state"), EncodableValue("paused")}});
      }
      break;
    case MF_MEDIA_ENGINE_EVENT_ENDED:
      player->Send({{EncodableValue("event"), EncodableValue("completed")}});
      break;
    case MF_MEDIA_ENGINE_EVENT_ERROR: {
      if (param1 == static_cast<DWORD>(MF_MEDIA_ENGINE_ERR_ABORTED)) break;
      const std::string message =
          "Windows could not play this audio (media engine error " +
          std::to_string(param1) + ", " + Hex(param2) + ").";
      if (player->pending) {
        player->pending->Error(ErrorCode(param1), message);
        player->pending = nullptr;
      } else {
        player->Send({{EncodableValue("event"), EncodableValue("error")},
                      {EncodableValue("errorCode"),
                       EncodableValue(std::string(ErrorCode(param1)))},
                      {EncodableValue("message"), EncodableValue(message)}});
      }
      break;
    }
    default:
      break;
  }
}
