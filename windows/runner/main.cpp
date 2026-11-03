#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include <string>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// Per user session, so two signed-in users each get their own instance.
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\com.zarz.mornye.instance";

// Same ID as the installer's Start Menu shortcut (windows/installer), so the
// taskbar groups the window with its pinned shortcut.
constexpr wchar_t kAppUserModelId[] = L"com.zarz.mornye";

void ForwardAudioToInstance() {
  HWND window = nullptr;
  // A second file-manager launch can arrive before the first window exists.
  for (int attempt = 0; attempt < 50 && window == nullptr; ++attempt) {
    window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Mornye");
    if (window == nullptr) ::Sleep(100);
  }
  if (window == nullptr) return;
  const auto* command = ::GetCommandLineW();
  COPYDATASTRUCT data = {};
  data.dwData = FlutterWindow::kOpenAudioMessage;
  data.cbData = static_cast<DWORD>((wcslen(command) + 1) * sizeof(wchar_t));
  data.lpData = const_cast<wchar_t*>(command);
  DWORD_PTR response = 0;
  ::SendMessageTimeoutW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
                        SMTO_ABORTIFHUNG, 5000, &response);
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
  ::SetForegroundWindow(window);
}

constexpr wchar_t kUrlSchemeKey[] = L"Software\\Classes\\mornye";
constexpr wchar_t kUrlCommandKey[] =
    L"Software\\Classes\\mornye\\shell\\open\\command";

void SetUserRegistryString(const wchar_t* key, const wchar_t* name,
                           const std::wstring& value) {
  ::RegSetKeyValueW(HKEY_CURRENT_USER, key, name, REG_SZ, value.c_str(),
                    static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

// The installer registers mornye://, but a portable copy has no installer,
// so the browser could not hand an extension callback back to it. Points
// the per-user handler at this executable unless it already does.
void RegisterUrlScheme() {
  wchar_t path[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return;
  const std::wstring executable = L"\"" + std::wstring(path) + L"\"";
  const std::wstring command = executable + L" \"%1\"";

  wchar_t current[MAX_PATH + 16];
  DWORD size = sizeof(current);
  if (::RegGetValueW(HKEY_CURRENT_USER, kUrlCommandKey, nullptr,
                     RRF_RT_REG_SZ, nullptr, current,
                     &size) == ERROR_SUCCESS &&
      ::_wcsicmp(current, command.c_str()) == 0) {
    return;
  }
  SetUserRegistryString(kUrlSchemeKey, nullptr, L"URL:Mornye Protocol");
  SetUserRegistryString(kUrlSchemeKey, L"URL Protocol", L"");
  SetUserRegistryString(L"Software\\Classes\\mornye\\DefaultIcon", nullptr,
                        executable + L",0");
  SetUserRegistryString(kUrlCommandKey, nullptr, command);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance. A second launch (for example a mornye:// callback from
  // the browser: the installer and RegisterUrlScheme register
  // `"mornye.exe" "%1"` under HKCU\Software\Classes\mornye) hands its URL
  // to the running window with WM_COPYDATA, raises that window and exits.
  // The installer closes the app before it replaces files, so a
  // /RELAUNCH=1 start finds no instance.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ForwardAudioToInstance();
    SendAppLinkToInstance();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  RegisterUrlScheme();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Mornye", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.OpenAudioFiles(GetCommandLineArguments());

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
