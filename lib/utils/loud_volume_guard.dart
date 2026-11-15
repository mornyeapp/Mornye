/// What the volume bar does with a value the user asked for: the value to
/// set now, and whether to open the loud volume dialog.
typedef LoudVolumeStep = ({double value, bool ask});

/// Holds the app's volume bar at a chosen level until the user confirms a
/// louder one. Only a move from at or below the level to above it asks; a
/// volume that is already above it (volume buttons, the system, a restored
/// session) moves freely until it comes back to the level or below.
///
/// One question at a time: while it is open the bar stays at the level, and
/// after a cancel it stays there for the rest of that touch.
class LoudVolumeGuard {
  /// Values within this of the level count as the level, so a float that
  /// round-trips through the platform as 0.8000001 does not ask again.
  static const _tolerance = 0.0001;

  bool _asking = false;
  bool _declined = false;
  double? _target;

  /// Whether the dialog is open.
  bool get asking => _asking;

  /// A new touch on the bar; a cancel during the previous one is forgotten.
  void startGesture() {
    if (!_asking) _declined = false;
  }

  /// Decides a move of the bar from [from] to [to], both 0 to 1. [level] is
  /// the confirmation level from 0 to 1, or null while the setting is off.
  LoudVolumeStep request({
    required double from,
    required double to,
    required double? level,
  }) {
    if (level == null) return (value: to, ask: false);
    if (_asking) _target = to;
    if (to <= level + _tolerance) return (value: to, ask: false);
    if (_asking || _declined) return (value: level, ask: false);
    if (from > level + _tolerance) return (value: to, ask: false);
    _asking = true;
    _target = to;
    return (value: level, ask: true);
  }

  /// The dialog's answer. Returns the value to set once [confirmed]: where
  /// the user last moved the bar, which may have changed while it was open.
  double? answer({required bool confirmed}) {
    final target = _target;
    _asking = false;
    _target = null;
    if (!confirmed) {
      _declined = true;
      return null;
    }
    return target;
  }
}
