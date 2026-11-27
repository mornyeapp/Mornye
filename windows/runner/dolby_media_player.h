#ifndef RUNNER_DOLBY_MEDIA_PLAYER_H_
#define RUNNER_DOLBY_MEDIA_PLAYER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>

struct DolbyMediaPlayer;

// Plays songs through the Media Foundation media engine, the engine behind
// the Windows Media Player app, so Windows decodes Dolby audio itself
// (E-AC-3 with Atmos, and AC-4 where the PC has its decoder) and renders
// Atmos through the system's spatial sound: Dolby Atmos for headphones,
// for built-in speakers, or for home theater. libmpv decodes those songs
// to plain channels and drops the Atmos objects.
//
// Answers lib/services/windows_media_playback_deck.dart on
// `com.zarz.mornye/windows_media_player`; each player reports to
// `com.zarz.mornye/windows_media_player/events/<playerId>`.
class DolbyMediaPlayers {
 public:
  explicit DolbyMediaPlayers(flutter::BinaryMessenger* messenger);
  ~DolbyMediaPlayers();
  DolbyMediaPlayers(const DolbyMediaPlayers&) = delete;
  DolbyMediaPlayers& operator=(const DolbyMediaPlayers&) = delete;

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Runs on the platform thread for an event the engine posted.
  void OnEngineEvent(uint64_t serial, LPARAM packed);

  DolbyMediaPlayer* Find(const std::string& id);
  DolbyMediaPlayer* FindSerial(uint64_t serial);
  void Create(
      const std::string& id,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Dispose(const std::string& id);

  flutter::BinaryMessenger* messenger_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // Message-only window: engine events arrive on Media Foundation threads
  // and are posted here, so the channels are only used on this thread.
  HWND window_ = nullptr;
  bool media_foundation_ = false;
  std::map<std::string, std::unique_ptr<DolbyMediaPlayer>> players_;
  uint64_t next_serial_ = 1;
};

#endif  // RUNNER_DOLBY_MEDIA_PLAYER_H_
