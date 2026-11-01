import 'dart:async';

import 'package:flutter/widgets.dart';

bool _attached(AppLifecycleState? state) =>
    state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

/// Whether an Activity is attached to the Flutter engine now. The engine
/// reports no lifecycle state until one attaches.
bool isActivityAttached(WidgetsBinding binding) =>
    _attached(binding.lifecycleState);

/// Completes once an Activity is attached to the Flutter engine.
///
/// A media service (for example media resumption after boot, or Android Auto)
/// can start the engine without an Activity. Only playback channels are
/// registered then; the rest of the backend channel is registered when
/// MainActivity attaches, so startup work that calls it must wait.
Future<void> waitForActivityAttachment(WidgetsBinding binding) {
  if (isActivityAttached(binding)) return Future<void>.value();
  final observer = _AttachmentObserver(_attached);
  binding.addObserver(observer);
  return observer.done.future.whenComplete(
    () => binding.removeObserver(observer),
  );
}

class _AttachmentObserver with WidgetsBindingObserver {
  _AttachmentObserver(this._attached);

  final bool Function(AppLifecycleState? state) _attached;
  final done = Completer<void>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_attached(state) && !done.isCompleted) done.complete();
  }
}
