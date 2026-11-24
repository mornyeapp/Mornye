import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/media_session_mpris.dart';
import 'package:mornye/services/media_session_smtc.dart';
import 'package:mornye/services/windows_taskbar_controls.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// The media session audio_service drives on this OS, or null to keep its
/// own: the plugin on Android, iOS and macOS. Linux gets MPRIS and Windows
/// the System Media Transport Controls, where audio_service has no plugin.
AudioServicePlatform? desktopMediaSession() {
  if (!isDesktopPlatform) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.linux => MprisAudioService(),
    TargetPlatform.windows => SmtcAudioService(
      taskbar: WindowsTaskbarControls(),
    ),
    _ => null,
  };
}

/// Installs [desktopMediaSession] before `AudioService.init`, which reads
/// the platform instance once.
void installDesktopMediaSession() {
  final session = desktopMediaSession();
  if (session != null) AudioServicePlatform.instance = session;
}
