import 'package:flutter/services.dart';

/// Gives one haptic tick each time a swipe crosses the point where letting
/// go would commit, and none while it stays on either side.
///
/// Haptics stay on under reduced motion: they replace motion rather than
/// add to it.
class SwipeCommitHaptic {
  bool _armed = false;

  /// Reports whether releasing now would commit the swipe.
  void update(bool armed) {
    if (armed && !_armed) HapticFeedback.mediumImpact();
    _armed = armed;
  }
}
