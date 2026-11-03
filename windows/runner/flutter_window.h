#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();
  static constexpr ULONG_PTR kOpenAudioMessage = 0x4D415544;
  void OpenAudioFiles(const std::vector<std::string>& paths);

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Answers the window channel (lib/widgets/desktop/desktop_window.dart).
  void HandleWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Turns the window into a small frameless panel of |width| x |height|
  // logical pixels that stays above other windows, or resizes the panel
  // when it already shows. It keeps its top-left corner when it resizes
  // and opens where it last sat (first at the top right of the screen).
  bool OpenMiniPlayer(double width, double height);

  // Returns the window to the frame, size and place it had before.
  void CloseMiniPlayer();

  // Moves the window with the mouse, as dragging a title bar does.
  void StartDrag();

  bool SetWindowMode(const std::string& mode);
  void NotifyWindowMode();
  void FitFullScreen();
  void ZoomWindow();

  flutter::DartProject project_;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> audio_channel_;
  flutter::EncodableList pending_audio_;
  bool audio_ready_ = false;

  // Whether the window shows the mini player, and what it restores.
  bool mini_player_ = false;
  WINDOWPLACEMENT mini_player_restore_placement_ = {};
  LONG_PTR mini_player_restore_style_ = 0;

  // Where the mini player last sat, by its top-left corner.
  std::optional<POINT> mini_player_origin_;

  std::string window_mode_ = "windowed";
  LONG_PTR windowed_style_ = 0;
  LONG_PTR windowed_ex_style_ = 0;
  WINDOWPLACEMENT fullscreen_restore_placement_ = {};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
