#include "windows_audio_device_manager.h"

#include <functiondiscoverykeys_devpkey.h>
#include <ksmedia.h>
#include <flutter/event_stream_handler_functions.h>

#include <iostream>
#include <mutex>
#include <regex>
#include <queue>

namespace mornye {

namespace {

constexpr UINT kAudioEventMessage = WM_USER + 201;

std::string Utf16ToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()), nullptr, 0, nullptr, nullptr);
  std::string str(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()), &str[0], size_needed, nullptr, nullptr);
  return str;
}

std::wstring Utf8ToUtf16(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()), nullptr, 0);
  std::wstring wstr(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()), &wstr[0], size_needed);
  return wstr;
}

std::string ExtractGuid(const std::wstring& endpoint_id) {
  // Matches {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}
  std::wregex guid_regex(L"\\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\}");
  std::wsregex_iterator it(endpoint_id.begin(), endpoint_id.end(), guid_regex);
  std::wsregex_iterator end;
  std::wstring last_guid;
  while (it != end) {
    last_guid = it->str();
    ++it;
  }
  return Utf16ToUtf8(last_guid);
}

void BuildWaveFormat(
    WAVEFORMATEXTENSIBLE* pwfe,
    int sample_rate,
    int channels,
    int bits_per_sample,
    int valid_bits_per_sample,
    bool is_float) {
  ZeroMemory(pwfe, sizeof(WAVEFORMATEXTENSIBLE));
  pwfe->Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  pwfe->Format.nChannels = static_cast<WORD>(channels);
  pwfe->Format.nSamplesPerSec = static_cast<DWORD>(sample_rate);
  pwfe->Format.wBitsPerSample = static_cast<WORD>(bits_per_sample);
  pwfe->Format.nBlockAlign = static_cast<WORD>((channels * bits_per_sample) / 8);
  pwfe->Format.nAvgBytesPerSec = pwfe->Format.nSamplesPerSec * pwfe->Format.nBlockAlign;
  pwfe->Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  pwfe->Samples.wValidBitsPerSample = static_cast<WORD>(valid_bits_per_sample);
  pwfe->dwChannelMask = (channels == 2) ? (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT) : SPEAKER_FRONT_CENTER;
  pwfe->SubFormat = is_float ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT : KSDATAFORMAT_SUBTYPE_PCM;
}

struct QueuedAudioEvent {
  std::string event_type;
  std::string device_id;
};

std::mutex g_event_mutex;
std::queue<QueuedAudioEvent> g_event_queue;
WindowsAudioDeviceManager* g_instance = nullptr;

Microsoft::WRL::ComPtr<IMMDevice> FindDevice(
    IMMDeviceEnumerator* enumerator, const std::string& device_id) {
  if (!enumerator) return nullptr;

  if (device_id.empty() || device_id == "auto") {
    Microsoft::WRL::ComPtr<IMMDevice> default_dev;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, default_dev.GetAddressOf()))) {
      return default_dev;
    }
    return nullptr;
  }

  // Check if it's already an endpoint ID
  std::wstring wid = Utf8ToUtf16(device_id);
  Microsoft::WRL::ComPtr<IMMDevice> direct_dev;
  if (SUCCEEDED(enumerator->GetDevice(wid.c_str(), direct_dev.GetAddressOf()))) {
    return direct_dev;
  }

  // Extract GUID from device_id if wasapi/{GUID}
  std::string target_guid = ExtractGuid(wid);
  if (target_guid.empty()) {
    target_guid = device_id;
  }

  Microsoft::WRL::ComPtr<IMMDeviceCollection> collection;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, collection.GetAddressOf())) || !collection) {
    return nullptr;
  }

  UINT count = 0;
  collection->GetCount(&count);
  for (UINT i = 0; i < count; ++i) {
    Microsoft::WRL::ComPtr<IMMDevice> dev;
    if (SUCCEEDED(collection->Item(i, dev.GetAddressOf())) && dev) {
      LPWSTR pid = nullptr;
      if (SUCCEEDED(dev->GetId(&pid)) && pid) {
        std::wstring cur_id(pid);
        CoTaskMemFree(pid);
        std::string cur_guid = ExtractGuid(cur_id);
        if (_stricmp(cur_guid.c_str(), target_guid.c_str()) == 0 ||
            _stricmp(Utf16ToUtf8(cur_id).c_str(), device_id.c_str()) == 0) {
          return dev;
        }
      }
    }
  }

  return nullptr;
}

}  // namespace

void WindowsAudioDeviceManager::Register(flutter::BinaryMessenger* messenger, HWND window_handle) {
  g_instance = new WindowsAudioDeviceManager(messenger, window_handle);
}

WindowsAudioDeviceManager* WindowsAudioDeviceManager::GetInstance() {
  return g_instance;
}

WindowsAudioDeviceManager::WindowsAudioDeviceManager(flutter::BinaryMessenger* messenger, HWND window_handle)
    : window_handle_(window_handle) {
  // Method Channel
  method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.zarz.mornye/windows_audio", &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  // Event Channel
  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "com.zarz.mornye/windows_audio_events", &flutter::StandardMethodCodec::GetInstance());
  auto stream_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        event_sink_ = std::move(events);
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        event_sink_ = nullptr;
        return nullptr;
      });
  event_channel_->SetStreamHandler(std::move(stream_handler));

  // Initialize Core Audio Enumerator
  HRESULT hr = CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(enumerator_.GetAddressOf()));
  if (SUCCEEDED(hr) && enumerator_) {
    enumerator_->RegisterEndpointNotificationCallback(this);
  }
}

WindowsAudioDeviceManager::~WindowsAudioDeviceManager() {
  if (enumerator_) {
    enumerator_->UnregisterEndpointNotificationCallback(this);
  }
}

void WindowsAudioDeviceManager::HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kAudioEventMessage) {
    std::vector<QueuedAudioEvent> events_to_dispatch;
    {
      std::lock_guard<std::mutex> lock(g_event_mutex);
      while (!g_event_queue.empty()) {
        events_to_dispatch.push_back(g_event_queue.front());
        g_event_queue.pop();
      }
    }
    for (const auto& ev : events_to_dispatch) {
      DispatchAudioEvent(ev.event_type, ev.device_id);
    }
  }
}

void WindowsAudioDeviceManager::PostAudioEvent(const std::string& event_type, const std::string& device_id) {
  {
    std::lock_guard<std::mutex> lock(g_event_mutex);
    g_event_queue.push({event_type, device_id});
  }
  if (window_handle_) {
    PostMessage(window_handle_, kAudioEventMessage, 0, 0);
  }
}

void WindowsAudioDeviceManager::DispatchAudioEvent(const std::string& event_type, const std::string& device_id) {
  if (event_sink_) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("event")] = flutter::EncodableValue(event_type);
    map[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(device_id);
    event_sink_->Success(flutter::EncodableValue(map));
  }
}

// IUnknown
STDMETHODIMP WindowsAudioDeviceManager::QueryInterface(REFIID riid, void** ppv) {
  if (!ppv) return E_POINTER;
  if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
    *ppv = static_cast<IMMNotificationClient*>(this);
    AddRef();
    return S_OK;
  }
  *ppv = nullptr;
  return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) WindowsAudioDeviceManager::AddRef() {
  return InterlockedIncrement(&ref_count_);
}

STDMETHODIMP_(ULONG) WindowsAudioDeviceManager::Release() {
  LONG val = InterlockedDecrement(&ref_count_);
  if (val == 0) {
    delete this;
  }
  return val;
}

// IMMNotificationClient
STDMETHODIMP WindowsAudioDeviceManager::OnDeviceStateChanged(LPCWSTR pwstrDeviceId, DWORD dwNewState) {
  PostAudioEvent("device_state_changed", pwstrDeviceId ? Utf16ToUtf8(pwstrDeviceId) : "");
  return S_OK;
}

STDMETHODIMP WindowsAudioDeviceManager::OnDeviceAdded(LPCWSTR pwstrDeviceId) {
  PostAudioEvent("device_added", pwstrDeviceId ? Utf16ToUtf8(pwstrDeviceId) : "");
  return S_OK;
}

STDMETHODIMP WindowsAudioDeviceManager::OnDeviceRemoved(LPCWSTR pwstrDeviceId) {
  PostAudioEvent("device_removed", pwstrDeviceId ? Utf16ToUtf8(pwstrDeviceId) : "");
  return S_OK;
}

STDMETHODIMP WindowsAudioDeviceManager::OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR pwstrDefaultDeviceId) {
  if (flow == eRender && role == eConsole) {
    PostAudioEvent("default_device_changed", pwstrDefaultDeviceId ? Utf16ToUtf8(pwstrDefaultDeviceId) : "");
  }
  return S_OK;
}

STDMETHODIMP WindowsAudioDeviceManager::OnPropertyValueChanged(LPCWSTR pwstrDeviceId, const PROPERTYKEY key) {
  if (key == PKEY_Device_FriendlyName) {
    PostAudioEvent("property_changed", pwstrDeviceId ? Utf16ToUtf8(pwstrDeviceId) : "");
  }
  return S_OK;
}

void WindowsAudioDeviceManager::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "getAudioEndpoints") {
    result->Success(flutter::EncodableValue(EnumerateEndpoints()));
  } else if (method == "getDeviceCapabilities") {
    std::string device_id = "";
    if (call.arguments()) {
      if (const auto* str = std::get_if<std::string>(call.arguments())) {
        device_id = *str;
      } else if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
        auto it = map->find(flutter::EncodableValue("deviceId"));
        if (it != map->end() && std::holds_alternative<std::string>(it->second)) {
          device_id = std::get<std::string>(it->second);
        }
      }
    }
    result->Success(flutter::EncodableValue(QueryDeviceCapabilities(device_id)));
  } else if (method == "getDeviceMixFormat") {
    std::string device_id = "";
    if (call.arguments()) {
      if (const auto* str = std::get_if<std::string>(call.arguments())) {
        device_id = *str;
      }
    }
    result->Success(flutter::EncodableValue(QueryDeviceMixFormat(device_id)));
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableList WindowsAudioDeviceManager::EnumerateEndpoints() {
  flutter::EncodableList list;
  if (!enumerator_) return list;

  // Get default device ID
  std::wstring default_id;
  Microsoft::WRL::ComPtr<IMMDevice> default_device;
  if (SUCCEEDED(enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, default_device.GetAddressOf())) && default_device) {
    LPWSTR pstr_id = nullptr;
    if (SUCCEEDED(default_device->GetId(&pstr_id)) && pstr_id) {
      default_id = pstr_id;
      CoTaskMemFree(pstr_id);
    }
  }

  Microsoft::WRL::ComPtr<IMMDeviceCollection> collection;
  HRESULT hr = enumerator_->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, collection.GetAddressOf());
  if (FAILED(hr) || !collection) return list;

  UINT count = 0;
  collection->GetCount(&count);

  for (UINT i = 0; i < count; ++i) {
    Microsoft::WRL::ComPtr<IMMDevice> device;
    if (FAILED(collection->Item(i, device.GetAddressOf())) || !device) continue;

    LPWSTR pstr_id = nullptr;
    if (FAILED(device->GetId(&pstr_id)) || !pstr_id) continue;
    std::wstring endpoint_id_w = pstr_id;
    CoTaskMemFree(pstr_id);

    std::string endpoint_id = Utf16ToUtf8(endpoint_id_w);
    std::string guid = ExtractGuid(endpoint_id_w);
    std::string mpv_id = guid.empty() ? endpoint_id : ("wasapi/" + guid);

    // Friendly Name
    std::string friendly_name = "Unknown Device";
    Microsoft::WRL::ComPtr<IPropertyStore> props;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, props.GetAddressOf())) && props) {
      PROPVARIANT var_name;
      PropVariantInit(&var_name);
      if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &var_name))) {
        if (var_name.vt == VT_LPWSTR && var_name.pwszVal) {
          friendly_name = Utf16ToUtf8(var_name.pwszVal);
        }
      }
      PropVariantClear(&var_name);
    }

    bool is_default = (!default_id.empty() && default_id == endpoint_id_w);

    // Query mix format
    int mix_rate = 0;
    int mix_bits = 0;
    int mix_channels = 0;
    std::string mix_format_str = "pcm";
    Microsoft::WRL::ComPtr<IAudioClient> client;
    if (SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()))) && client) {
      WAVEFORMATEX* mix_wf = nullptr;
      if (SUCCEEDED(client->GetMixFormat(&mix_wf)) && mix_wf) {
        mix_rate = static_cast<int>(mix_wf->nSamplesPerSec);
        mix_bits = static_cast<int>(mix_wf->wBitsPerSample);
        mix_channels = static_cast<int>(mix_wf->nChannels);
        if (mix_wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
          mix_format_str = "float";
        } else if (mix_wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
          auto* wfex = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix_wf);
          if (wfex->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
            mix_format_str = "float";
          }
        }
        CoTaskMemFree(mix_wf);
      }
    }

    flutter::EncodableMap item;
    // Explicit, distinct fields satisfying the C++ to Dart contract:
    item[flutter::EncodableValue("endpointId")] = flutter::EncodableValue(endpoint_id);
    item[flutter::EncodableValue("mpvDeviceId")] = flutter::EncodableValue(mpv_id);
    item[flutter::EncodableValue("guid")] = flutter::EncodableValue(guid);
    item[flutter::EncodableValue("name")] = flutter::EncodableValue(friendly_name);
    item[flutter::EncodableValue("isDefault")] = flutter::EncodableValue(is_default);
    item[flutter::EncodableValue("state")] = flutter::EncodableValue(1); // DEVICE_STATE_ACTIVE
    item[flutter::EncodableValue("mixSampleRate")] = flutter::EncodableValue(mix_rate);
    item[flutter::EncodableValue("mixBitDepth")] = flutter::EncodableValue(mix_bits);
    item[flutter::EncodableValue("mixChannels")] = flutter::EncodableValue(mix_channels);
    item[flutter::EncodableValue("mixFormat")] = flutter::EncodableValue(mix_format_str);
    // Backward compatibility for legacy fixtures/consumers expecting 'id':
    item[flutter::EncodableValue("id")] = flutter::EncodableValue(mpv_id);

    list.push_back(flutter::EncodableValue(item));
  }

  return list;
}

flutter::EncodableMap WindowsAudioDeviceManager::QueryDeviceMixFormat(const std::string& device_id) {
  flutter::EncodableMap result;
  if (!enumerator_) return result;

  auto device = FindDevice(enumerator_.Get(), device_id);
  if (!device) return result;

  Microsoft::WRL::ComPtr<IAudioClient> client;
  if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()))) || !client) {
    return result;
  }

  WAVEFORMATEX* mix_wf = nullptr;
  if (SUCCEEDED(client->GetMixFormat(&mix_wf)) && mix_wf) {
    result[flutter::EncodableValue("sampleRate")] = flutter::EncodableValue(static_cast<int>(mix_wf->nSamplesPerSec));
    result[flutter::EncodableValue("bitDepth")] = flutter::EncodableValue(static_cast<int>(mix_wf->wBitsPerSample));
    result[flutter::EncodableValue("channels")] = flutter::EncodableValue(static_cast<int>(mix_wf->nChannels));
    std::string fmt = "pcm";
    if (mix_wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
      fmt = "float";
    } else if (mix_wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      auto* wfex = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix_wf);
      if (wfex->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
        fmt = "float";
      }
    }
    result[flutter::EncodableValue("format")] = flutter::EncodableValue(fmt);
    CoTaskMemFree(mix_wf);
  }

  return result;
}

flutter::EncodableMap WindowsAudioDeviceManager::QueryDeviceCapabilities(const std::string& device_id) {
  flutter::EncodableMap result;
  if (!enumerator_) return result;

  auto device = FindDevice(enumerator_.Get(), device_id);
  if (!device) {
    result[flutter::EncodableValue("error")] = flutter::EncodableValue("Device not found");
    return result;
  }

  Microsoft::WRL::ComPtr<IAudioClient> client;
  if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()))) || !client) {
    result[flutter::EncodableValue("error")] = flutter::EncodableValue("Failed to activate audio client");
    return result;
  }

  // Get Mix format first
  WAVEFORMATEX* mix_wf = nullptr;
  if (SUCCEEDED(client->GetMixFormat(&mix_wf)) && mix_wf) {
    flutter::EncodableMap mix_map;
    mix_map[flutter::EncodableValue("sampleRate")] = flutter::EncodableValue(static_cast<int>(mix_wf->nSamplesPerSec));
    mix_map[flutter::EncodableValue("bitDepth")] = flutter::EncodableValue(static_cast<int>(mix_wf->wBitsPerSample));
    mix_map[flutter::EncodableValue("channels")] = flutter::EncodableValue(static_cast<int>(mix_wf->nChannels));
    std::string fmt = "pcm";
    if (mix_wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
      fmt = "float";
    } else if (mix_wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      auto* wfex = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix_wf);
      if (wfex->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
        fmt = "float";
      }
    }
    mix_map[flutter::EncodableValue("format")] = flutter::EncodableValue(fmt);
    result[flutter::EncodableValue("sharedMixFormat")] = flutter::EncodableValue(mix_map);
    CoTaskMemFree(mix_wf);
  }

  const int candidate_rates[] = { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 };
  const int candidate_rates_count = sizeof(candidate_rates) / sizeof(candidate_rates[0]);

  struct FormatOption {
    std::string label;
    int bits_per_sample;
    int valid_bits;
    bool is_float;
  };

  const FormatOption formats[] = {
    { "s16", 16, 16, false },
    { "s24", 32, 24, false },
    { "s32", 32, 32, false },
    { "float", 32, 32, true }
  };
  const int formats_count = sizeof(formats) / sizeof(formats[0]);

  flutter::EncodableList exclusive_rates;
  flutter::EncodableList exclusive_formats;
  flutter::EncodableList shared_rates;
  flutter::EncodableMap formats_by_rate;

  std::vector<int> tested_exclusive_rates;
  std::vector<std::string> tested_exclusive_formats;

  for (int r = 0; r < candidate_rates_count; ++r) {
    int rate = candidate_rates[r];
    bool rate_supported_exclusive = false;
    flutter::EncodableList rate_formats;

    // Test Shared Mode (2 channels float/pcm)
    WAVEFORMATEXTENSIBLE wf_shared;
    BuildWaveFormat(&wf_shared, rate, 2, 32, 32, true);
    WAVEFORMATEX* closest = nullptr;
    HRESULT hr_shared = client->IsFormatSupported(
        AUDCLNT_SHAREMODE_SHARED, reinterpret_cast<WAVEFORMATEX*>(&wf_shared), &closest);
    if (closest) CoTaskMemFree(closest);
    if (hr_shared == S_OK) {
      shared_rates.push_back(flutter::EncodableValue(rate));
    }

    // Test Exclusive Mode across all format options
    for (int f = 0; f < formats_count; ++f) {
      WAVEFORMATEXTENSIBLE wf_excl;
      BuildWaveFormat(
          &wf_excl, rate, 2,
          formats[f].bits_per_sample,
          formats[f].valid_bits,
          formats[f].is_float);

      HRESULT hr_excl = client->IsFormatSupported(
          AUDCLNT_SHAREMODE_EXCLUSIVE, reinterpret_cast<WAVEFORMATEX*>(&wf_excl), nullptr);

      if (hr_excl == S_OK) {
        rate_supported_exclusive = true;
        rate_formats.push_back(flutter::EncodableValue(formats[f].label));
        if (std::find(tested_exclusive_formats.begin(), tested_exclusive_formats.end(), formats[f].label) == tested_exclusive_formats.end()) {
          tested_exclusive_formats.push_back(formats[f].label);
          exclusive_formats.push_back(flutter::EncodableValue(formats[f].label));
        }
      }
    }

    if (!rate_formats.empty()) {
      formats_by_rate[flutter::EncodableValue(std::to_string(rate))] = flutter::EncodableValue(rate_formats);
    }

    if (rate_supported_exclusive) {
      tested_exclusive_rates.push_back(rate);
      exclusive_rates.push_back(flutter::EncodableValue(rate));
    }
  }

  bool supports_exclusive = !exclusive_rates.empty();
  bool supports_shared = !shared_rates.empty();
  int min_excl_rate = tested_exclusive_rates.empty() ? 0 : tested_exclusive_rates.front();
  int max_excl_rate = tested_exclusive_rates.empty() ? 0 : tested_exclusive_rates.back();

  result[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(device_id);
  result[flutter::EncodableValue("supportsExclusive")] = flutter::EncodableValue(supports_exclusive);
  result[flutter::EncodableValue("exclusiveSupported")] = flutter::EncodableValue(supports_exclusive);
  result[flutter::EncodableValue("supportsShared")] = flutter::EncodableValue(supports_shared);
  result[flutter::EncodableValue("sharedSupported")] = flutter::EncodableValue(supports_shared);
  result[flutter::EncodableValue("exclusiveSupportedRates")] = flutter::EncodableValue(exclusive_rates);
  result[flutter::EncodableValue("exclusiveRates")] = flutter::EncodableValue(exclusive_rates);
  result[flutter::EncodableValue("exclusiveSupportedFormats")] = flutter::EncodableValue(exclusive_formats);
  result[flutter::EncodableValue("exclusiveFormats")] = flutter::EncodableValue(exclusive_formats);
  result[flutter::EncodableValue("sharedSupportedRates")] = flutter::EncodableValue(shared_rates);
  result[flutter::EncodableValue("sharedRates")] = flutter::EncodableValue(shared_rates);
  result[flutter::EncodableValue("sampleRates")] = flutter::EncodableValue(exclusive_rates.empty() ? shared_rates : exclusive_rates);
  result[flutter::EncodableValue("sampleFormats")] = flutter::EncodableValue(exclusive_formats);
  result[flutter::EncodableValue("formatsByRate")] = flutter::EncodableValue(formats_by_rate);
  result[flutter::EncodableValue("formats_by_rate")] = flutter::EncodableValue(formats_by_rate);
  result[flutter::EncodableValue("minExclusiveSampleRate")] = flutter::EncodableValue(min_excl_rate);
  result[flutter::EncodableValue("maxExclusiveSampleRate")] = flutter::EncodableValue(max_excl_rate);

  return result;
}

}  // namespace mornye

