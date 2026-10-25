import 'package:mornye/services/link/link_protocol.dart';

/// Keeps the phone's preferences with the computer currently playing for it.
/// Incoming state and command rollbacks must not echo another command.
class LinkPlaybackPreferencesSync {
  LinkPlaybackPreferencesSync({
    required this.readAutoplay,
    required this.readAutoMix,
    required this.writeAutoplay,
    required this.writeAutoMix,
    required this.sendAutoplay,
    required this.sendAutoMix,
  });

  final bool Function() readAutoplay;
  final bool Function() readAutoMix;
  final void Function(bool) writeAutoplay;
  final void Function(bool) writeAutoMix;
  final Future<void> Function(bool) sendAutoplay;
  final Future<void> Function(bool) sendAutoMix;
  bool? _autoplay;
  bool? _autoMix;
  bool _applyingRemote = false;

  void updateRemote(LinkPlayerState? player) {
    _autoplay = player?.autoplay;
    _autoMix = player?.autoMix;
    _applyingRemote = true;
    try {
      if (_autoplay case final enabled? when enabled != readAutoplay()) {
        writeAutoplay(enabled);
      }
      if (_autoMix case final enabled? when enabled != readAutoMix()) {
        writeAutoMix(enabled);
      }
    } finally {
      _applyingRemote = false;
    }
  }

  Future<void> updateLocal() async {
    if (_applyingRemote) return;
    final autoplay = readAutoplay();
    final autoMix = readAutoMix();
    final pending = <Future<void>>[];
    if (_autoplay != null && _autoplay != autoplay) {
      _autoplay = autoplay;
      pending.add(sendAutoplay(autoplay));
    }
    if (_autoMix != null && _autoMix != autoMix) {
      _autoMix = autoMix;
      pending.add(sendAutoMix(autoMix));
    }
    await Future.wait(pending);
  }
}
