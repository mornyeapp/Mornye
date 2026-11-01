import 'package:mornye/utils/logger.dart';

/// Serializes update progress writes while retaining only the latest value.
class UpdateProgressNotifications {
  UpdateProgressNotifications(this._show);

  final Future<void> Function(int received, int total) _show;
  (int, int)? _pending;
  Future<void>? _completion;
  bool _writing = false;
  bool _finished = false;

  void update(int received, int total) {
    if (_finished) return;
    _pending = (received, total);
    if (_writing) return;
    _writing = true;
    _completion = _flush();
  }

  Future<void> _flush() async {
    try {
      while (_pending != null) {
        final value = _pending!;
        _pending = null;
        try {
          await _show(value.$1, value.$2);
        } catch (error) {
          AppLogger('UpdateProgress').w('Progress notification failed: $error');
        }
      }
    } finally {
      _writing = false;
    }
  }

  /// Finish progress before stopping the service or showing its final result.
  Future<void> finish() async {
    _finished = true;
    await _completion;
  }
}
