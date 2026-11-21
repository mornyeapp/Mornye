import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// How long a paired device may stay disconnected before the Library hides
/// its songs, so a reconnect or a quick app switch goes unnoticed.
const linkSourceOfflineGrace = Duration(seconds: 10);

/// Decides whether the Library shows the songs of each Mornye Link device:
/// on a phone its paired computers, on the desktop its paired phones. Such a
/// device is a `network://` source whose songs need it connected, so they
/// hide once it has been disconnected for [grace] and return as soon as it
/// connects. Other network sources keep their songs through outages.
class LinkSourcePresence {
  LinkSourcePresence({
    required void Function() onChanged,
    this.grace = linkSourceOfflineGrace,
    DateTime Function()? now,
  }) : _onChanged = onChanged,
       _now = now ?? DateTime.now {
    _since = _now();
  }

  final Duration grace;
  final void Function() _onChanged;
  final DateTime Function() _now;
  bool _enabled = true;
  bool _ready = false;
  bool Function(String source) _isLink = _none;
  Set<String> _connected = const {};
  final _disconnectedAt = <String, DateTime>{};
  late DateTime _since;
  bool _paused = false;
  Timer? _timer;

  static bool _none(String _) => false;

  /// True to show the songs of [source] (a `network://` host), false to hide
  /// them, null to leave them as they are.
  bool? availability(String source) {
    if (!_enabled) return true;
    if (!_ready) return null;
    if (!_isLink(source)) return true;
    if (_connected.contains(source)) return true;
    if (_paused) return null;
    final at = _disconnectedAt[source];
    final from = at == null || at.isBefore(_since) ? _since : at;
    return _now().difference(from) >= grace ? false : null;
  }

  /// [ready] once the paired devices are known; [isLink] tells their
  /// sources, [connected] those whose device is connected now.
  void update({
    required bool ready,
    required bool Function(String source) isLink,
    required Set<String> connected,
  }) {
    final now = _now();
    for (final source in _connected.difference(connected)) {
      _disconnectedAt[source] = now;
    }
    _disconnectedAt.removeWhere((source, _) => connected.contains(source));
    _ready = ready;
    _isLink = isLink;
    _connected = Set.unmodifiable(connected);
    _changed();
  }

  /// Off shows every device's songs, connected or not (the owner's
  /// `linkHideDisconnectedSongs` setting).
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _changed();
  }

  /// The app went to the background, where a phone may drop the link on
  /// purpose: songs keep their state until [resume].
  void pause() {
    _paused = true;
    _timer?.cancel();
  }

  /// Back in the foreground: disconnected devices get a fresh [grace].
  void resume() {
    if (!_paused) return;
    _paused = false;
    _since = _now();
    _changed();
  }

  void dispose() => _timer?.cancel();

  void _changed() {
    _timer?.cancel();
    if (_ready && !_paused) {
      // Decides the devices that are still disconnected once [grace] ends.
      _timer = Timer(grace + const Duration(milliseconds: 50), _onChanged);
    }
    _onChanged();
  }
}

/// Keeps the Library's network source availability in step with Mornye
/// Link. Read for the app's lifetime on phones and on the desktop.
final linkSourcePresenceProvider = Provider<LinkSourcePresence>((ref) {
  late final LinkSourcePresence presence;
  void pushAvailability() {
    // Not inside a provider build, which must not change other providers.
    unawaited(
      Future(() {
        // Avoid eagerly instantiating LocalLibraryNotifier on Frame 1 before
        // its deferred warmup or first Library tab visit.
        if (!ref.mounted || !ref.read(localLibraryProvider.exists)) return null;
        return ref
            .read(localLibraryProvider.notifier)
            .setNetworkSourceAvailability(presence.availability);
      }),
    );
  }

  presence = LinkSourcePresence(onChanged: pushAvailability);
  ref.onDispose(presence.dispose);
  ref.listen(localLibraryProvider.exists, (_, exists) {
    if (exists) pushAvailability();
  });
  ref.listen(
    settingsProvider.select((settings) => settings.linkHideDisconnectedSongs),
    (_, hide) => presence.enabled = hide,
    fireImmediately: true,
  );
  if (isDesktopPlatform) {
    ref.listen(
      linkDesktopHostProvider.select((state) => state.clients),
      (_, clients) => presence.update(
        ready: true,
        isLink: isLinkPhoneSourceId,
        connected: {
          for (final client in clients) linkPhoneSourceId(client.deviceId),
        },
      ),
      fireImmediately: true,
    );
    return presence;
  }
  ref.listen(
    linkClientControllerProvider.select(
      (state) => (
        loaded: state.loaded,
        servers: state.servers,
        active: state.activeServer,
        connection: state.connection,
      ),
    ),
    (_, state) {
      final sources = {for (final server in state.servers) server.connectionId};
      final active = state.active;
      presence.update(
        ready: state.loaded,
        isLink: sources.contains,
        connected: {
          if (active != null &&
              state.connection == LinkConnectionState.connected)
            active.connectionId,
        },
      );
    },
    fireImmediately: true,
  );
  final lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      // Inactive covers the iOS control centre and app switcher.
      if (state == AppLifecycleState.resumed) {
        presence.resume();
      } else if (state != AppLifecycleState.inactive) {
        presence.pause();
      }
    },
  );
  ref.onDispose(lifecycle.dispose);
  return presence;
});
