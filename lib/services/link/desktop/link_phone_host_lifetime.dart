import 'dart:async';

/// When a phone's Link host may run ("Share with other phones"): while the
/// app is in the foreground or plays. Phones have no always-on service for
/// it, so after the app leaves the foreground with nothing playing the host
/// stops once [grace] passes; a song change or a quick look at another app
/// does not stop it.
class LinkPhoneHostLifetime {
  LinkPhoneHostLifetime({
    required void Function(bool allowed, String reason) onChanged,
    bool foreground = true,
    bool playing = false,
    this.grace = const Duration(seconds: 10),
  }) : _onChanged = onChanged,
       _foreground = foreground,
       _playing = playing,
       _allowed = foreground || playing;

  final void Function(bool allowed, String reason) _onChanged;
  final Duration grace;
  bool _foreground;
  bool _playing;
  bool _allowed;
  bool _disposed = false;
  Timer? _timer;

  /// Whether the host may run now.
  bool get allowed => _allowed;

  set foreground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    _update();
  }

  set playing(bool value) {
    if (value == _playing) return;
    _playing = value;
    _update();
  }

  /// Why the host may or may not run, for the log.
  String get reason => _foreground
      ? 'the app is open'
      : _playing
      ? 'the app plays in the background'
      : 'the app is in the background with nothing playing';

  void _update() {
    if (_disposed) return;
    if (_foreground || _playing) {
      _timer?.cancel();
      _timer = null;
      _set(true);
      return;
    }
    if (!_allowed || _timer != null) return;
    _timer = Timer(grace, () {
      _timer = null;
      if (!_foreground && !_playing) _set(false);
    });
  }

  void _set(bool allowed) {
    if (allowed == _allowed) return;
    _allowed = allowed;
    _onChanged(allowed, reason);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
