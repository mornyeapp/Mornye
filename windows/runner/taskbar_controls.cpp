#include "taskbar_controls.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iterator>
#include <utility>
#include <vector>

namespace {

constexpr UINT kPrevious = 0x5201;
constexpr UINT kToggle = 0x5202;
constexpr UINT kNext = 0x5203;
enum Glyph { kPreviousGlyph, kPlayGlyph, kPauseGlyph, kNextGlyph };

COLORREF IconColor() {
  HIGHCONTRAST contrast = {};
  contrast.cbSize = sizeof(contrast);
  if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast,
                            0) &&
      (contrast.dwFlags & HCF_HIGHCONTRASTON)) {
    return GetSysColor(COLOR_BTNTEXT);
  }
  DWORD light = 1;
  DWORD size = sizeof(light);
  RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  return light ? RGB(0, 0, 0) : RGB(255, 255, 255);
}

bool Inside(Glyph glyph, double x, double y) {
  if (y < 3 || y > 13) return false;
  switch (glyph) {
    case kPlayGlyph:
      return x >= 4 && x <= 12 && std::abs(y - 8) <= (12 - x) * 5 / 8;
    case kPauseGlyph:
      return (x >= 4 && x <= 7) || (x >= 9 && x <= 12);
    case kPreviousGlyph:
      return (x >= 3 && x <= 5) ||
             (x >= 6 && x <= 13 && std::abs(y - 8) <= (x - 6) * 5 / 7);
    case kNextGlyph:
      return (x >= 11 && x <= 13) ||
             (x >= 3 && x <= 10 && std::abs(y - 8) <= (10 - x) * 5 / 7);
  }
  return false;
}

// Rasterize small media glyphs at the window's DPI, with premultiplied alpha.
HICON MakeIcon(Glyph glyph, int size, COLORREF color) {
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (bitmap == nullptr) return nullptr;
  auto* output = static_cast<uint32_t*>(pixels);
  for (int y = 0; y < size; ++y) {
    for (int x = 0; x < size; ++x) {
      unsigned covered = 0;
      for (int sy = 0; sy < 2; ++sy) {
        for (int sx = 0; sx < 2; ++sx) {
          if (Inside(glyph, (x + (sx + 0.5) / 2) * 16 / size,
                     (y + (sy + 0.5) / 2) * 16 / size)) {
            ++covered;
          }
        }
      }
      const uint32_t alpha = covered * 255 / 4;
      output[y * size + x] = (alpha << 24) |
                             (GetRValue(color) * alpha / 255 << 16) |
                             (GetGValue(color) * alpha / 255 << 8) |
                             (GetBValue(color) * alpha / 255);
    }
  }
  const std::vector<uint8_t> mask_bits(((size + 15) / 16) * 2 * size, 0);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, mask_bits.data());
  ICONINFO icon = {};
  icon.fIcon = TRUE;
  icon.hbmColor = bitmap;
  icon.hbmMask = mask;
  HICON result = mask == nullptr ? nullptr : CreateIconIndirect(&icon);
  if (mask != nullptr) DeleteObject(mask);
  DeleteObject(bitmap);
  return result;
}

THUMBBUTTON Button(UINT id, HICON icon, const std::wstring& label, bool visible,
                   bool enabled) {
  THUMBBUTTON button = {};
  button.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
  button.iId = id;
  button.hIcon = icon;
  button.dwFlags = static_cast<THUMBBUTTONFLAGS>((visible ? 0 : THBF_HIDDEN) |
                                                 (enabled ? 0 : THBF_DISABLED));
  std::copy_n(label.data(), std::min(label.size(), std::size(button.szTip) - 1),
              button.szTip);
  return button;
}

}  // namespace

TaskbarControls::TaskbarControls(HWND window,
                                 std::function<void(const char*)> pressed)
    : window_(window),
      pressed_(std::move(pressed)),
      created_message_(RegisterWindowMessageW(L"TaskbarButtonCreated")) {}

TaskbarControls::~TaskbarControls() {
  ReleaseTaskbar();
  for (auto icon : icons_) {
    if (icon != nullptr) DestroyIcon(icon);
  }
}

void TaskbarControls::ReleaseTaskbar() {
  if (taskbar_ != nullptr) taskbar_->Release();
  taskbar_ = nullptr;
  added_ = false;
}

bool TaskbarControls::ResetIcons() {
  const UINT dpi = GetDpiForWindow(window_);
  const int size =
      std::max(16, GetSystemMetricsForDpi(
                       SM_CXSMICON, dpi == 0 ? USER_DEFAULT_SCREEN_DPI : dpi));
  const COLORREF color = IconColor();
  if (icons_[0] != nullptr && size == last_icon_size_ &&
      color == last_icon_color_) {
    return false;
  }
  for (size_t i = 0; i < icons_.size(); ++i) {
    if (icons_[i] != nullptr) DestroyIcon(icons_[i]);
    icons_[i] = MakeIcon(static_cast<Glyph>(i), size, color);
  }
  last_icon_size_ = size;
  last_icon_color_ = color;
  return true;
}

void TaskbarControls::Update(TaskbarPlaybackState state) {
  state_ = std::move(state);
  Publish();
}

void TaskbarControls::Publish() {
  if (!ready_) return;
  if (taskbar_ == nullptr) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_))))
      return;
    if (FAILED(taskbar_->HrInit())) {
      ReleaseTaskbar();
      return;
    }
  }
  if (icons_[0] == nullptr) ResetIcons();
  THUMBBUTTON buttons[] = {
      Button(kPrevious, icons_[kPreviousGlyph], state_.previous_label,
             state_.visible, state_.previous),
      Button(kToggle, icons_[state_.playing ? kPauseGlyph : kPlayGlyph],
             state_.toggle_label, state_.visible, state_.toggle),
      Button(kNext, icons_[kNextGlyph], state_.next_label, state_.visible,
             state_.next),
  };
  const HRESULT result =
      added_ ? taskbar_->ThumbBarUpdateButtons(window_, 3, buttons)
             : taskbar_->ThumbBarAddButtons(window_, 3, buttons);
  if (SUCCEEDED(result)) added_ = true;
}

bool TaskbarControls::HandleMessage(UINT message, WPARAM wparam) {
  if (created_message_ != 0 && message == created_message_) {
    ReleaseTaskbar();
    ready_ = true;
    Publish();
    return true;
  }
  if (message == WM_THEMECHANGED || message == WM_SETTINGCHANGE ||
      message == WM_SYSCOLORCHANGE || message == WM_DPICHANGED) {
    if (ResetIcons()) {
      Publish();
    }
  }
  if (message != WM_COMMAND || HIWORD(wparam) != THBN_CLICKED) return false;
  switch (LOWORD(wparam)) {
    case kPrevious:
      if (state_.visible && state_.previous) pressed_("previous");
      return true;
    case kToggle:
      if (state_.visible && state_.toggle) {
        pressed_(state_.playing ? "pause" : "play");
      }
      return true;
    case kNext:
      if (state_.visible && state_.next) pressed_("next");
      return true;
  }
  return false;
}
