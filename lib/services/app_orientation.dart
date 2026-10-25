import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/android_tv.dart';

const fullPlayerRouteName = '/full-player';
final _log = AppLogger('Orientation');

/// Phones rotate in the full player and return to portrait on other pages.
/// TV stays landscape; sheets and dialogs inherit the underlying orientation.
Future<void> setAppOrientation({bool playerVisible = false}) =>
    SystemChrome.setPreferredOrientations([
      if (!isAndroidTv) DeviceOrientation.portraitUp,
      if (isAndroidTv || playerVisible) ...[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    ]);

class AppOrientationObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];
  bool? _playerVisible;

  void _sync() {
    final page = _routes.whereType<PageRoute<dynamic>>().lastOrNull;
    final playerVisible = page?.settings.name == fullPlayerRouteName;
    if (_playerVisible == playerVisible) return;
    _playerVisible = playerVisible;
    unawaited(
      setAppOrientation(playerVisible: playerVisible).catchError((
        Object error,
      ) {
        _log.w('Could not update screen orientation: $error');
      }),
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _sync();
  }
}
