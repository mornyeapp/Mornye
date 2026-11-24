import 'dart:ui';

/// The display [view] is on, or null. [FlutterView.display] throws while a
/// desktop window moves between screens.
Display? displayOf(FlutterView? view) {
  if (view == null) return null;
  try {
    return view.display;
  } on Error {
    return null;
  }
}
