#ifndef RUNNER_WINDOWS_AUDIO_DEVICE_MANAGER_H_
#define RUNNER_WINDOWS_AUDIO_DEVICE_MANAGER_H_

#include <flutter/binary_messenger.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <wrl/client.h>

#include <memory>
#include <string>
#include <vector>

namespace mornye {

class WindowsAudioDeviceManager : public IMMNotificationClient {
 public:
  static void Register(flutter::BinaryMessenger* messenger, HWND window_handle);
  static WindowsAudioDeviceManager* GetInstance();

  WindowsAudioDeviceManager(flutter::BinaryMessenger* messenger, HWND window_handle);
  virtual ~WindowsAudioDeviceManager();

  // Handle window message on the main thread for thread-safe event dispatch.
  void HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);

  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  STDMETHODIMP_(ULONG) AddRef() override;
  STDMETHODIMP_(ULONG) Release() override;

  // IMMNotificationClient
  STDMETHODIMP OnDeviceStateChanged(LPCWSTR pwstrDeviceId, DWORD dwNewState) override;
  STDMETHODIMP OnDeviceAdded(LPCWSTR pwstrDeviceId) override;
  STDMETHODIMP OnDeviceRemoved(LPCWSTR pwstrDeviceId) override;
  STDMETHODIMP OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR pwstrDefaultDeviceId) override;
  STDMETHODIMP OnPropertyValueChanged(LPCWSTR pwstrDeviceId, const PROPERTYKEY key) override;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::EncodableList EnumerateEndpoints();
  flutter::EncodableMap QueryDeviceCapabilities(const std::string& device_id);
  flutter::EncodableMap QueryDeviceMixFormat(const std::string& device_id);

  void PostAudioEvent(const std::string& event_type, const std::string& device_id);
  void DispatchAudioEvent(const std::string& event_type, const std::string& device_id);

  HWND window_handle_;
  LONG ref_count_ = 1;
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
};

}  // namespace mornye

#endif  // RUNNER_WINDOWS_AUDIO_DEVICE_MANAGER_H_

