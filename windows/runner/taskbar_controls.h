#ifndef RUNNER_TASKBAR_CONTROLS_H_
#define RUNNER_TASKBAR_CONTROLS_H_

#include <shobjidl.h>
#include <windows.h>

#include <array>
#include <functional>
#include <string>

struct TaskbarPlaybackState {
  bool visible = false;
  bool playing = false;
  bool toggle = false;
  bool previous = false;
  bool next = false;
  std::wstring toggle_label = L"Play";
  std::wstring previous_label = L"Previous";
  std::wstring next_label = L"Next";
};

// Native thumbnail controls. The last state survives an Explorer restart.
class TaskbarControls {
 public:
  TaskbarControls(HWND window, std::function<void(const char*)> pressed);
  ~TaskbarControls();
  TaskbarControls(const TaskbarControls&) = delete;
  TaskbarControls& operator=(const TaskbarControls&) = delete;

  void Update(TaskbarPlaybackState state);
  bool HandleMessage(UINT message, WPARAM wparam);

 private:
  void Publish();
  bool ResetIcons();
  void ReleaseTaskbar();

  HWND window_;
  std::function<void(const char*)> pressed_;
  UINT created_message_;
  ITaskbarList3* taskbar_ = nullptr;
  bool ready_ = false;
  bool added_ = false;
  TaskbarPlaybackState state_;
  std::array<HICON, 4> icons_ = {};
  int last_icon_size_ = 0;
  COLORREF last_icon_color_ = CLR_INVALID;
};

#endif  // RUNNER_TASKBAR_CONTROLS_H_
