import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_sound_sync_protocol.dart';
import 'package:mornye/services/link/sync/link_sound_sync_store.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkSoundSync');

/// Sound sync timing. Tests override it with short delays.
class LinkSoundSyncSettings {
  const LinkSoundSyncSettings({
    this.localDebounce = const Duration(seconds: 3),
    this.messageDebounce = const Duration(milliseconds: 500),
  });

  /// Quiet time after a local edit (a slider being dragged, a preset being
  /// saved) before it is sent.
  final Duration localDebounce;

  /// Coalesces bursts of `preferences.changed` messages.
  final Duration messageDebounce;
}

final linkSoundSyncSettingsProvider = Provider<LinkSoundSyncSettings>(
  (ref) => const LinkSoundSyncSettings(),
);

/// The phone's "Sync sound settings" choice, off until turned on.
@immutable
class LinkSoundSyncOption {
  const LinkSoundSyncOption({this.loaded = false, this.enabled = false});

  /// The saved choice was read.
  final bool loaded;
  final bool enabled;
}

/// Keeps [LinkSoundSyncOption] in shared preferences. Tests pass [initial],
/// which skips reading it.
class LinkSoundSyncOptionNotifier extends Notifier<LinkSoundSyncOption> {
  LinkSoundSyncOptionNotifier({this.initial});

  static const enabledKey = 'link_phone_sync_sound';

  final LinkSoundSyncOption? initial;

  @override
  LinkSoundSyncOption build() {
    if (initial case final option?) return option;
    unawaited(_restore());
    return const LinkSoundSyncOption();
  }

  Future<void> _restore() async {
    var enabled = false;
    try {
      enabled =
          (await SharedPreferences.getInstance()).getBool(enabledKey) ?? false;
    } on Object catch (error) {
      _log.w('Could not read the sound sync choice: $error');
    }
    // A choice made meanwhile stands.
    if (ref.mounted && !state.loaded) {
      state = LinkSoundSyncOption(loaded: true, enabled: enabled);
    }
  }

  /// Turning it off only stops syncing; nothing synced is removed.
  void setEnabled(bool enabled) {
    state = LinkSoundSyncOption(loaded: true, enabled: enabled);
    unawaited(() async {
      try {
        await (await SharedPreferences.getInstance()).setBool(
          enabledKey,
          enabled,
        );
      } on Object catch (error) {
        _log.w('Could not save the sound sync choice: $error');
      }
    }());
  }
}

final linkSoundSyncOptionProvider =
    NotifierProvider<LinkSoundSyncOptionNotifier, LinkSoundSyncOption>(
      LinkSoundSyncOptionNotifier.new,
    );

/// Keeps the phone's saved sound settings equal to the linked computer's
/// while "Sync sound settings" is on: when the switch turns on, on connect,
/// when the computer sends `preferences.changed`, and after a local edit
/// (debounced). Each run is one `POST preferences` exchange (see
/// link_sound_sync_protocol.dart). A computer without the operation is left
/// alone until the next connection.
///
/// App-lifetime on phones: the app root keeps it alive.
class LinkSoundSyncRunner extends Notifier<void> {
  LinkClientApi? _client;
  StreamSubscription<LinkConnectionState>? _states;
  StreamSubscription<Map<String, dynamic>>? _messages;
  Timer? _debounce;
  bool _debouncedForce = false;
  Future<void>? _running;
  bool? _pendingForce;
  bool _unsupported = false;

  bool get _enabled => ref.read(linkSoundSyncOptionProvider).enabled;

  @override
  void build() {
    ref.onDispose(_detach);
    ref.listen(linkActiveClientProvider, (_, client) => _attach(client));
    ref.listen(linkSoundSyncOptionProvider.select((option) => option.enabled), (
      _,
      enabled,
    ) {
      if (enabled) {
        unawaited(_run(force: true));
      } else {
        _debounce?.cancel();
        _debouncedForce = false;
      }
    });
    ref.listen(
      equalizerProvider.select((state) => state.presets),
      (_, _) => _localChanged(),
    );
    ref.listen(
      settingsProvider.select(
        (settings) => linkSoundCanonical(linkSoundSettingValues(settings)),
      ),
      (_, _) => _localChanged(),
    );
    ref.listen(songLyricsOffsetsProvider, (_, _) => _localChanged());
    _attach(ref.read(linkActiveClientProvider));
  }

  /// Syncs now; completes when done. Does nothing while the switch is off.
  Future<void> syncNow() => _run(force: true);

  void _attach(LinkClientApi? client) {
    if (identical(client, _client)) return;
    _detach();
    _client = client;
    if (client == null) return;
    _states = client.connectionStates.listen((connection) {
      if (connection == LinkConnectionState.connected) {
        _unsupported = false;
        unawaited(_run(force: true));
      } else {
        _debounce?.cancel();
      }
    });
    _messages = client.messages.listen((message) {
      if (message['type'] == LinkSoundSyncMessages.preferencesChanged) {
        _schedule(
          ref.read(linkSoundSyncSettingsProvider).messageDebounce,
          force: true,
        );
      }
    });
    if (client.connectionState == LinkConnectionState.connected) {
      // Never start work while building; start after build returns.
      scheduleMicrotask(() {
        if (ref.mounted && identical(client, _client)) {
          unawaited(_run(force: true));
        }
      });
    }
  }

  void _detach() {
    _debounce?.cancel();
    _debouncedForce = false;
    unawaited(_states?.cancel());
    unawaited(_messages?.cancel());
    _states = null;
    _messages = null;
    _client = null;
    _unsupported = false;
  }

  void _localChanged() {
    if (!_enabled) return;
    _schedule(ref.read(linkSoundSyncSettingsProvider).localDebounce);
  }

  void _schedule(Duration delay, {bool force = false}) {
    if (_client == null || !_enabled) return;
    _debouncedForce = _debouncedForce || force;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      final next = _debouncedForce;
      _debouncedForce = false;
      unawaited(_run(force: next));
    });
  }

  /// Runs after the sync in progress, merging requests that arrive
  /// meanwhile. [force] exchanges even without a local edit.
  Future<void> _run({bool force = false}) {
    final running = _running;
    if (running != null) {
      _pendingForce = (_pendingForce ?? false) || force;
      return running;
    }
    final done = () async {
      // The caller's synchronous code (and build) finishes first.
      await Future<void>.value();
      var next = force;
      try {
        while (true) {
          final client = _client;
          if (client != null) await _syncOnce(client, force: next);
          final pending = _pendingForce;
          _pendingForce = null;
          if (pending == null) break;
          next = pending;
        }
      } finally {
        _running = null;
      }
    }();
    _running = done;
    return done;
  }

  Future<void> _syncOnce(LinkClientApi client, {required bool force}) async {
    if (!ref.mounted ||
        !_enabled ||
        _unsupported ||
        client.connectionState != LinkConnectionState.connected) {
      return;
    }
    final sync = ref.read(linkSoundSyncProvider);
    try {
      final mine = await sync.exchange(const []);
      if (!force && mine.captured == 0) return;
      final reply = await client.post(LinkSoundSyncOps.preferences, {
        'device': mine.device,
        'items': [for (final item in mine.items) item.toJson()],
      });
      if (reply is! Map || reply['items'] is! List) {
        throw const LinkException('invalid', 'Malformed preferences reply');
      }
      final peer = reply['device'];
      final applied = await sync.exchange(
        LinkSoundItem.listFromJson(
          reply['items'],
          fallbackOrigin: peer is String ? peer : null,
        ),
      );
      if (applied.applied > 0) {
        _log.i('Applied ${applied.applied} sound settings from the computer');
      }
    } on LinkException catch (error) {
      if (error.code == 'not_found') {
        // An older computer: try again after the next connection.
        _unsupported = true;
        return;
      }
      _log.w('Sound settings sync failed: $error');
    } on Object catch (error) {
      _log.w('Sound settings sync failed: $error');
    }
  }
}

final linkSoundSyncRunnerProvider = NotifierProvider<LinkSoundSyncRunner, void>(
  LinkSoundSyncRunner.new,
);
