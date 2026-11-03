#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "windows_audio_device_manager.h"

namespace {

// Smallest client area, in logical pixels, that the desktop layouts support.
constexpr int kMinimumClientWidth = 800;
constexpr int kMinimumClientHeight = 600;

// Gap, in logical pixels, between a new mini player and the screen corner.
constexpr int kMiniPlayerScreenInset = 16;

// Reads a number from the call arguments, or |fallback| when it is missing.
double NumberArgument(const flutter::EncodableValue* arguments,
                      const char* key, double fallback) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return fallback;
  }
  auto entry = map->find(flutter::EncodableValue(key));
  if (entry == map->end()) {
    return fallback;
  }
  if (const auto* value = std::get_if<double>(&entry->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int32_t>(&entry->second)) {
    return *value;
  }
  return fallback;
}

std::string StringArgument(const flutter::EncodableValue* arguments,
                           const char* key) {
  if (arguments == nullptr) return {};
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return {};
  const auto entry = map->find(flutter::EncodableValue(key));
  if (entry == map->end()) return {};
  const auto* value = std::get_if<std::string>(&entry->second);
  return value == nullptr ? std::string() : *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  mornye::WindowsAudioDeviceManager::Register(
      flutter_controller_->engine()->messenger(), GetHandle());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.zarz.mornye/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleWindowCall(call, std::move(result)); });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (auto* adm = mornye::WindowsAudioDeviceManager::GetInstance()) {
    adm->HandleWindowMessage(message, wparam, lparam);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_NCCALCSIZE:
      if (window_mode_ == "borderless" && !mini_player_ && wparam) {
        if (IsZoomed(hwnd)) {
          auto* size = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
          MONITORINFO monitor = {};
          monitor.cbSize = sizeof(monitor);
          if (GetMonitorInfo(
                  MonitorFromRect(&size->rgrc[0], MONITOR_DEFAULTTONEAREST),
                  &monitor)) {
            size->rgrc[0] = monitor.rcWork;
          }
        }
        return 0;
      }
      break;
    case WM_NCHITTEST:
      if (window_mode_ == "borderless" && !mini_player_ && !IsZoomed(hwnd)) {
        RECT bounds;
        GetWindowRect(hwnd, &bounds);
        const UINT dpi = GetDpiForWindow(hwnd);
        const int edge = MulDiv(8, dpi == 0 ? USER_DEFAULT_SCREEN_DPI : dpi,
                                USER_DEFAULT_SCREEN_DPI);
        const int x = GET_X_LPARAM(lparam);
        const int y = GET_Y_LPARAM(lparam);
        const bool left = x < bounds.left + edge;
        const bool right = x >= bounds.right - edge;
        const bool top = y < bounds.top + edge;
        const bool bottom = y >= bounds.bottom - edge;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
      }
      break;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
      if (window_mode_ == "fullscreen") {
        FitFullScreen();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_GETMINMAXINFO: {
      // The mini player is far smaller than the full layouts' minimum.
      if (mini_player_ || window_mode_ == "fullscreen") {
        break;
      }
      UINT dpi = GetDpiForWindow(hwnd);
      if (dpi == 0) {
        dpi = USER_DEFAULT_SCREEN_DPI;
      }
      RECT frame = {0, 0,
                    MulDiv(kMinimumClientWidth, dpi, USER_DEFAULT_SCREEN_DPI),
                    MulDiv(kMinimumClientHeight, dpi, USER_DEFAULT_SCREEN_DPI)};
      AdjustWindowRectExForDpi(
          &frame, static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_STYLE)), FALSE,
          static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_EXSTYLE)), dpi);
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = frame.right - frame.left;
      info->ptMinTrackSize.y = frame.bottom - frame.top;
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "openMiniPlayer") {
    const double width = NumberArgument(call.arguments(), "width", 360);
    const double height = NumberArgument(call.arguments(), "height", 140);
    result->Success(flutter::EncodableValue(OpenMiniPlayer(width, height)));
  } else if (method == "closeMiniPlayer") {
    CloseMiniPlayer();
    result->Success();
  } else if (method == "startDrag") {
    // Answer first: the move loop runs until the mouse button is released.
    result->Success();
    StartDrag();
  } else if (method == "getWindowMode") {
    result->Success(flutter::EncodableValue(window_mode_));
  } else if (method == "isFullScreen") {
    result->Success(flutter::EncodableValue(window_mode_ == "fullscreen"));
  } else if (method == "setWindowMode") {
    result->Success(flutter::EncodableValue(
        SetWindowMode(StringArgument(call.arguments(), "mode"))));
  } else if (method == "minimizeWindow") {
    ShowWindow(GetHandle(), SW_MINIMIZE);
    result->Success();
  } else if (method == "zoomWindow" || method == "titleBarDoubleClick") {
    ZoomWindow();
    result->Success();
  } else if (method == "closeWindow") {
    result->Success();
    PostMessage(GetHandle(), WM_CLOSE, 0, 0);
  } else if (method == "startResize") {
    const bool from_left =
        StringArgument(call.arguments(), "edge") == "bottomLeft";
    result->Success();
    if (window_mode_ == "borderless" && !mini_player_ &&
        !IsZoomed(GetHandle())) {
      ReleaseCapture();
      SendMessage(GetHandle(), WM_SYSCOMMAND,
                  SC_SIZE | (from_left ? WMSZ_BOTTOMLEFT : WMSZ_BOTTOMRIGHT),
                  0);
    }
  } else {
    result->NotImplemented();
  }
}

bool FlutterWindow::OpenMiniPlayer(double width, double height) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || IsIconic(hwnd) || window_mode_ == "fullscreen") {
    return false;
  }
  UINT dpi = GetDpiForWindow(hwnd);
  if (dpi == 0) {
    dpi = USER_DEFAULT_SCREEN_DPI;
  }
  const int panel_width = MulDiv(static_cast<int>(std::lround(width)), dpi,
                                 USER_DEFAULT_SCREEN_DPI);
  const int panel_height = MulDiv(static_cast<int>(std::lround(height)), dpi,
                                  USER_DEFAULT_SCREEN_DPI);

  const bool opening = !mini_player_;
  if (opening) {
    mini_player_restore_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &mini_player_restore_placement_);
    mini_player_restore_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    mini_player_ = true;
    if (IsZoomed(hwnd)) {
      ShowWindow(hwnd, SW_RESTORE);
    }
    // No caption or sizing border: the Flutter content moves the panel.
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     mini_player_restore_style_ &
                         ~(WS_CAPTION | WS_THICKFRAME | WS_MAXIMIZEBOX |
                           WS_MAXIMIZE));
  }

  std::optional<POINT> origin;
  if (!opening) {
    RECT window_rect;
    GetWindowRect(hwnd, &window_rect);
    origin = POINT{window_rect.left, window_rect.top};
  } else {
    origin = mini_player_origin_;
  }

  // Keep the whole panel on the screen it opens on.
  HMONITOR monitor = origin
                         ? MonitorFromPoint(*origin, MONITOR_DEFAULTTONEAREST)
                         : MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(monitor, &monitor_info);
  const RECT& work = monitor_info.rcWork;
  if (!origin) {
    const int inset =
        MulDiv(kMiniPlayerScreenInset, dpi, USER_DEFAULT_SCREEN_DPI);
    origin = POINT{work.right - panel_width - inset, work.top + inset};
  }
  const LONG x = std::clamp<LONG>(
      origin->x, work.left, std::max<LONG>(work.left, work.right - panel_width));
  const LONG y = std::clamp<LONG>(
      origin->y, work.top, std::max<LONG>(work.top, work.bottom - panel_height));

  SetWindowPos(hwnd, HWND_TOPMOST, x, y, panel_width, panel_height,
               SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  return true;
}

void FlutterWindow::CloseMiniPlayer() {
  if (!mini_player_) {
    return;
  }
  HWND hwnd = GetHandle();
  RECT window_rect;
  GetWindowRect(hwnd, &window_rect);
  mini_player_origin_ = POINT{window_rect.left, window_rect.top};
  mini_player_ = false;
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   mini_player_restore_style_ & ~(WS_MAXIMIZE | WS_MINIMIZE));
  SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  // Brings back the size and place, maximized when it was.
  SetWindowPlacement(hwnd, &mini_player_restore_placement_);
}

void FlutterWindow::StartDrag() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || window_mode_ == "fullscreen") {
    return;
  }
  // The Flutter view holds the mouse capture from the button press; hand
  // the drag to the system move loop, as a title bar would.
  ReleaseCapture();
  SendMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
}

void FlutterWindow::NotifyWindowMode() {
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "windowModeChanged",
        std::make_unique<flutter::EncodableValue>(window_mode_));
  }
}

void FlutterWindow::FitFullScreen() {
  const HWND hwnd = GetHandle();
  MONITORINFO monitor = {};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                      &monitor))
    return;
  const RECT& bounds = monitor.rcMonitor;
  SetWindowPos(hwnd, HWND_TOP, bounds.left, bounds.top,
               bounds.right - bounds.left, bounds.bottom - bounds.top,
               SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
}

bool FlutterWindow::SetWindowMode(const std::string& mode) {
  const HWND hwnd = GetHandle();
  if (hwnd == nullptr || mini_player_ ||
      (mode != "windowed" && mode != "fullscreen" && mode != "borderless")) {
    return false;
  }
  if (mode == window_mode_) {
    NotifyWindowMode();
    return true;
  }
  const bool was_fullscreen = window_mode_ == "fullscreen";
  if (window_mode_ == "windowed") {
    windowed_style_ =
        GetWindowLongPtr(hwnd, GWL_STYLE) & ~(WS_MAXIMIZE | WS_MINIMIZE);
    windowed_ex_style_ = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  }
  if (mode == "fullscreen") {
    fullscreen_restore_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &fullscreen_restore_placement_);
    if (IsZoomed(hwnd) || IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  }
  const bool maximized = IsZoomed(hwnd);
  window_mode_ = mode;
  LONG_PTR style = windowed_style_;
  LONG_PTR ex_style = windowed_ex_style_;
  if (mode == "fullscreen") {
    style &= ~WS_OVERLAPPEDWINDOW;
  } else if (mode == "borderless") {
    style &= ~WS_CAPTION;
  }
  if (maximized && mode != "fullscreen") style |= WS_MAXIMIZE;
  if (mode != "windowed") {
    ex_style &= ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE |
                  WS_EX_STATICEDGE);
  }
  SetWindowLongPtr(hwnd, GWL_STYLE, style);
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);
  if (mode == "fullscreen") {
    FitFullScreen();
  } else {
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    if (was_fullscreen)
      SetWindowPlacement(hwnd, &fullscreen_restore_placement_);
  }
  NotifyWindowMode();
  return true;
}

void FlutterWindow::ZoomWindow() {
  if (window_mode_ != "fullscreen" && !mini_player_) {
    ShowWindow(GetHandle(), IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
  }
}
