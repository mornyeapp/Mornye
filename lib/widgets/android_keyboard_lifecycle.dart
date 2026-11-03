import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/utils/android_tv.dart';

/// Ends the mobile IME session on backgrounding without waiting for a frame.
/// Keeping a focused editor across backgrounding can leave its old keyboard
/// inset behind when Android hides the IME while the activity is stopped.
class AndroidKeyboardLifecycle extends StatefulWidget {
  const AndroidKeyboardLifecycle({super.key, required this.child});

  final Widget child;

  @override
  State<AndroidKeyboardLifecycle> createState() =>
      _AndroidKeyboardLifecycleState();
}

class _AndroidKeyboardLifecycleState extends State<AndroidKeyboardLifecycle>
    with WidgetsBindingObserver {
  bool _backgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        isAndroidTv) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
    } else if (!_backgrounded &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      _backgrounded = true;
      FocusManager.instance.primaryFocus?.unfocus();
      // Send this immediately, even if no frame runs to detach the editor.
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
