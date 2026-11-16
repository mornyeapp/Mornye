import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_sound_sync_protocol.dart';
import 'package:mornye/services/link/sync/link_sound_sync_runner.dart';
import 'package:mornye/services/link/sync/link_sound_sync_store.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkSoundSyncHandlers');

final _watching = Expando<bool>('linkSoundSyncHandlers');
final _notifiers = Expando<void Function()>('linkSoundSyncNotify');

/// Registers `preferences` (sound settings sync) on the desktop's [router]
/// and watches this desktop's own sound edits. [notifyPhones] sends
/// `preferences.changed` to the connected phones; it runs after a phone's
/// items changed something here and after a local edit (debounced). Safe to
/// call again on server restart.
void registerLinkSoundSyncHandlers(
  LinkHostRouter router,
  Ref ref, {
  required void Function() notifyPhones,
}) {
  _notifiers[ref] = notifyPhones;
  router.register(LinkSoundSyncOps.preferences, (request) async {
    if (request.method != 'POST') {
      throw const LinkException('invalid', 'preferences takes POST');
    }
    final raw = request.args['items'];
    if (raw is! List) {
      throw const LinkException('invalid', 'items must be a list');
    }
    if (raw.length > linkSoundMaxItems) {
      throw const LinkException('invalid', 'Too many items in one request');
    }
    final device = request.args['device'];
    final result = await ref
        .read(linkSoundSyncProvider)
        .exchange(
          LinkSoundItem.listFromJson(
            raw,
            fallbackOrigin: device is String ? device : null,
          ),
        );
    // Other phones catch up; the asking phone's extra exchange is a no-op.
    if (result.applied > 0 || result.captured > 0) _notifiers[ref]?.call();
    return {
      'device': result.device,
      'items': [for (final item in result.items) item.toJson()],
    };
  });
  if (_watching[ref] != true) {
    _watching[ref] = true;
    _watchLocalChanges(ref);
  }
}

void _watchLocalChanges(Ref ref) {
  Timer? timer;
  void changed() {
    timer?.cancel();
    timer = Timer(
      ref.read(linkSoundSyncSettingsProvider).localDebounce,
      () async {
        if (!ref.mounted) return;
        try {
          final captured = await ref.read(linkSoundSyncProvider).captureLocal();
          if (captured > 0 && ref.mounted) _notifiers[ref]?.call();
        } on Object catch (error) {
          _log.w('Could not check local sound settings: $error');
        }
      },
    );
  }

  final presets = ref.listen(
    equalizerProvider.select((state) => state.presets),
    (_, _) => changed(),
  );
  final settings = ref.listen(
    settingsProvider.select(
      (settings) => linkSoundCanonical(linkSoundSettingValues(settings)),
    ),
    (_, _) => changed(),
  );
  final songs = ref.listen(songLyricsOffsetsProvider, (_, _) => changed());
  ref.onDispose(() {
    timer?.cancel();
    presets.close();
    settings.close();
    songs.close();
    // A rebuilt host registers again and watches anew.
    _watching[ref] = null;
  });
}
