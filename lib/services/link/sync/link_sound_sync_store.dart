import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/link/sync/link_sound_sync_protocol.dart';

/// The synced values one device holds now, by item id.
typedef LinkSoundValues = Map<LinkSoundId, Map<String, dynamic>>;

/// Reads and writes the sound values that sync on this device.
abstract interface class LinkSoundSettingsAccess {
  /// The values this device holds now, or null when they cannot be trusted
  /// yet (still loading, or reading them failed), which skips this round:
  /// a list read as empty would otherwise delete every preset elsewhere.
  Future<LinkSoundValues?> read();

  /// Values this app starts with. A value still at its default when first
  /// seen counts as never set, so a value chosen on the other device wins.
  LinkSoundValues get defaults;

  /// When the value under [id] was set or removed on this device, if the
  /// device knows (a song offset does). A local edit is then dated by it, so
  /// an edit made while the devices were apart still loses to a newer one
  /// from the other device. Null dates the edit when a sync notices it.
  int? editedMs(LinkSoundId id);

  /// Applies [winners]: a live item sets its value, a deleted one removes
  /// it. Presets past the app's limit are left out.
  Future<void> apply(List<LinkSoundItem> winners);
}

/// Where the sync state is kept. Tests keep it in memory.
abstract interface class LinkSoundSyncStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class LinkSoundPreferencesStorage implements LinkSoundSyncStorage {
  const LinkSoundPreferencesStorage();

  static const key = 'link_sound_sync_v1';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw StateError('Could not save the sound sync state');
    }
  }
}

class LinkSoundMemoryStorage implements LinkSoundSyncStorage {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

/// The result of one [LinkSoundSync.exchange].
class LinkSoundExchange {
  const LinkSoundExchange({
    required this.device,
    required this.captured,
    required this.applied,
    required this.items,
  });

  /// This device's sync id.
  final String device;

  /// Local edits found and stamped before merging.
  final int captured;

  /// Peer items that won and were applied here.
  final int applied;

  /// Every item this device holds after the merge, tombstones included.
  final List<LinkSoundItem> items;
}

/// Sound settings sync state of one device, the same on phone and desktop.
///
/// Keeps every item's newest known version and which ids this device held
/// when it last looked (`here`). A local edit is found by comparing what the
/// device holds with the stored version: a new or different value gets a
/// new stamp from this device, and a value that was here and is gone becomes
/// a tombstone. A value never held here (a preset past the app's limit) is
/// kept for the peer but never turned into a deletion.
///
/// Stamps are at least one millisecond later than the version they replace,
/// so clock skew between devices cannot hide a local edit. Calls run one at
/// a time.
class LinkSoundSync {
  LinkSoundSync({
    required this.access,
    LinkSoundSyncStorage? storage,
    int Function()? clock,
    Random? random,
  }) : _storage = storage ?? const LinkSoundPreferencesStorage(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final LinkSoundSettingsAccess access;
  final LinkSoundSyncStorage _storage;
  final int Function() _clock;
  final Random _random;

  String? _device;
  final _items = <LinkSoundId, LinkSoundItem>{};
  final _here = <LinkSoundId>{};
  Future<void>? _loading;
  Future<void> _queue = Future.value();

  /// This device's sync id (the `origin` of its own edits).
  Future<String> deviceId() => _locked(() async => _device!);

  /// Records local edits and returns how many were found.
  Future<int> captureLocal() => _locked(() async {
    final captured = await _capture();
    if (captured > 0) await _save();
    return captured;
  });

  /// Records local edits, merges [incoming] by last writer wins, applies the
  /// winners here and returns every item for the peer.
  Future<LinkSoundExchange> exchange(Iterable<LinkSoundItem> incoming) =>
      _locked(() async {
        final captured = await _capture();
        final winners = <LinkSoundItem>[];
        for (final item in incoming) {
          final current = _items[item.id];
          if (current != null && !item.winsOver(current)) continue;
          _items[item.id] = item;
          // A tombstone for something this device never had changes nothing.
          if (item.deleted && current == null) continue;
          winners.add(item);
        }
        if (winners.isNotEmpty) {
          await access.apply(winners);
          await _adopt(winners);
        }
        _pruneTombstones();
        if (captured > 0 || winners.isNotEmpty) await _save();
        return LinkSoundExchange(
          device: _device!,
          captured: captured,
          applied: winners.length,
          items: _items.values.toList(growable: false),
        );
      });

  Future<T> _locked<T>(Future<T> Function() run) {
    final result = _queue.then((_) async {
      final loading = _loading ??= _load();
      try {
        await loading;
      } on Object {
        // Try again on the next call.
        _loading = null;
        rethrow;
      }
      return run();
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _load() async {
    final raw = await _storage.read();
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map && json['device'] is String) {
          _device = json['device'] as String;
          for (final entry in json['items'] as List? ?? const []) {
            final item = LinkSoundItem.fromJson(entry);
            if (item == null) continue;
            _items[item.id] = item;
            if (entry is Map && entry['here'] == true) _here.add(item.id);
          }
        }
      } on FormatException {
        // A damaged state starts over; the next exchange restores it.
      }
    }
    if (_device == null) {
      _device = [
        for (var i = 0; i < 16; i++)
          _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
      await _save();
    }
  }

  Future<void> _save() => _storage.write(
    jsonEncode({
      'device': _device,
      'items': [
        for (final item in _items.values)
          {...item.toJson(), if (_here.contains(item.id)) 'here': true},
      ],
    }),
  );

  int _stamp(LinkSoundItem? previous, LinkSoundId id) =>
      max(access.editedMs(id) ?? _clock(), (previous?.updatedMs ?? -1) + 1);

  Future<int> _capture() async {
    final local = await access.read();
    if (local == null) return 0;
    final defaults = access.defaults;
    var captured = 0;
    for (final MapEntry(key: id, value: data) in local.entries) {
      final current = _items[id];
      if (current != null &&
          !current.deleted &&
          linkSoundCanonical(current.data) == linkSoundCanonical(data)) {
        _here.add(id);
        continue;
      }
      final untouched =
          current == null &&
          defaults[id] != null &&
          linkSoundCanonical(defaults[id]) == linkSoundCanonical(data);
      _items[id] = LinkSoundItem(
        kind: id.$1,
        key: id.$2,
        updatedMs: untouched ? 0 : _stamp(current, id),
        origin: _device!,
        data: data,
      );
      _here.add(id);
      captured++;
    }
    for (final id in _here.toList()) {
      if (local.containsKey(id)) continue;
      _here.remove(id);
      final current = _items[id];
      if (current == null || current.deleted) continue;
      _items[id] = LinkSoundItem(
        kind: id.$1,
        key: id.$2,
        updatedMs: _stamp(current, id),
        origin: _device!,
        deleted: true,
      );
      captured++;
    }
    return captured;
  }

  /// Records what the winners left on this device without stamping it, so
  /// a value the app normalized or could not hold is not mistaken for a
  /// local edit.
  Future<void> _adopt(List<LinkSoundItem> winners) async {
    final local = await access.read();
    if (local == null) return;
    for (final winner in winners) {
      final id = winner.id;
      final data = local[id];
      if (data == null) {
        _here.remove(id);
        continue;
      }
      _here.add(id);
      final current = _items[id]!;
      if (current.deleted ||
          linkSoundCanonical(current.data) != linkSoundCanonical(data)) {
        _items[id] = LinkSoundItem(
          kind: current.kind,
          key: current.key,
          updatedMs: current.updatedMs,
          origin: current.origin,
          data: data,
        );
      }
    }
  }

  void _pruneTombstones() {
    final tombstones = [
      for (final item in _items.values)
        if (item.deleted) item,
    ];
    if (tombstones.length <= linkSoundMaxTombstones) return;
    tombstones.sort((a, b) => a.updatedMs.compareTo(b.updatedMs));
    for (final item in tombstones.take(
      tombstones.length - linkSoundMaxTombstones,
    )) {
      _items.remove(item.id);
    }
  }
}

/// The app's equalizer presets, sound settings and song lyric offsets,
/// through their providers.
class LinkSoundProviderAccess implements LinkSoundSettingsAccess {
  LinkSoundProviderAccess(this._ref);

  final Ref _ref;

  @override
  late final LinkSoundValues defaults = {
    for (final MapEntry(:key, :value) in linkSoundSettingValues(
      const AppSettings(),
    ).entries)
      (LinkSoundKinds.setting, key): {'value': value},
  };

  @override
  Future<LinkSoundValues?> read() async {
    await _ref.read(settingsProvider.notifier).ensureLoaded();
    await _ref.read(equalizerProvider.notifier).ensureLoaded();
    await _ref.read(songLyricsOffsetsProvider.notifier).ensureLoaded();
    final equalizer = _ref.read(equalizerProvider);
    // A failed read or write leaves the list in doubt.
    if (equalizer.error != null) return null;
    return {
      for (final preset in equalizer.presets)
        (LinkSoundKinds.eqPreset, preset.name): {
          'settings': preset.settings.toJson(),
        },
      for (final MapEntry(:key, :value) in linkSoundSettingValues(
        _ref.read(settingsProvider),
      ).entries)
        (LinkSoundKinds.setting, key): {'value': value},
      for (final MapEntry(:key, :value)
          in _ref.read(songLyricsOffsetsProvider).entries)
        (LinkSoundKinds.songLyricOffset, key): {'offsetMs': value.offsetMs},
    };
  }

  @override
  int? editedMs(LinkSoundId id) {
    if (id.$1 != LinkSoundKinds.songLyricOffset) return null;
    return _ref.read(songLyricsOffsetsProvider)[id.$2]?.editedMs ??
        _ref.read(songLyricsOffsetsProvider.notifier).resetAt(id.$2);
  }

  @override
  Future<void> apply(List<LinkSoundItem> winners) async {
    final presets = <String, LinkSoundItem>{};
    final settings = <String, Object?>{};
    final songs = <String, SongLyricsOffset>{};
    for (final item in winners) {
      switch (item.kind) {
        case LinkSoundKinds.eqPreset:
          presets[item.key] = item;
        case LinkSoundKinds.setting:
          settings[item.key] = item.data?['value'];
        case LinkSoundKinds.songLyricOffset:
          final offset = item.data?['offsetMs'];
          songs[item.key] = SongLyricsOffset(
            item.deleted || offset is! num ? 0 : offset.toInt(),
            item.updatedMs,
          );
      }
    }
    if (presets.isNotEmpty) _applyPresets(presets);
    if (settings.isNotEmpty) _applySettings(settings);
    if (songs.isNotEmpty) {
      await _ref.read(songLyricsOffsetsProvider.notifier).applySynced(songs);
    }
  }

  void _applyPresets(Map<String, LinkSoundItem> changed) {
    EqualizerSettings? settingsOf(LinkSoundItem item) {
      final json = item.data?['settings'];
      if (item.deleted || json is! Map) return null;
      try {
        return EqualizerSettings.fromJson(Map<String, dynamic>.from(json));
      } on FormatException {
        return null;
      }
    }

    final current = _ref.read(equalizerProvider).presets;
    // Local order stays; presets new here follow, oldest edit first.
    final next = <EqualizerPreset>[];
    for (final preset in current) {
      final item = changed[preset.name];
      if (item == null) {
        next.add(preset);
      } else if (settingsOf(item) case final settings?) {
        next.add(EqualizerPreset(preset.name, settings));
      }
    }
    final names = {for (final preset in current) preset.name};
    final added =
        [
          for (final item in changed.values)
            if (!names.contains(item.key) && settingsOf(item) != null) item,
        ]..sort((a, b) {
          final byTime = a.updatedMs.compareTo(b.updatedMs);
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });
    for (final item in added) {
      next.add(EqualizerPreset(item.key, settingsOf(item)!));
    }
    _ref
        .read(equalizerProvider.notifier)
        .replacePresets(next.take(EqualizerController.maxPresets).toList());
  }

  void _applySettings(Map<String, Object?> values) {
    final notifier = _ref.read(settingsProvider.notifier);
    T? value<T>(String key) {
      final raw = values[key];
      return raw is T ? raw : null;
    }

    if (value<num>(LinkSoundSettingKeys.normalizationPreamp) case final db?) {
      notifier.setPlaybackNormalizationPreamp(db.toDouble());
    }
    if (value<String>(LinkSoundSettingKeys.normalizationMode)
        case final mode?) {
      notifier.setPlaybackNormalizationMode(mode);
    }
    if (value<num>(LinkSoundSettingKeys.autoMixDuration) case final seconds?) {
      notifier.setAutoMixDuration(seconds.round());
    }
    // Choosing the pitch effect may also move the pitch, so the pitch is
    // set after it: the synced one, else the one this device had.
    final pitch =
        value<num>(LinkSoundSettingKeys.autoMixPitch)?.toDouble() ??
        _ref.read(settingsProvider).autoMixPitch;
    if (value<String>(LinkSoundSettingKeys.autoMixEffect) case final name?) {
      for (final effect in AutoMixEffect.values) {
        if (effect.name == name) notifier.setAutoMixEffect(effect);
      }
    }
    if (values.containsKey(LinkSoundSettingKeys.autoMixEffect) ||
        values.containsKey(LinkSoundSettingKeys.autoMixPitch)) {
      notifier.setAutoMixPitch(pitch);
    }
    if (value<num>(LinkSoundSettingKeys.autoMixSpeed) case final speed?) {
      notifier.setAutoMixSpeed(speed.toDouble());
    }
    if (value<bool>(LinkSoundSettingKeys.autoMixEcho) case final echo?) {
      notifier.setAutoMixEcho(echo);
    }
    if (value<bool>(LinkSoundSettingKeys.autoMixLowPass) case final low?) {
      notifier.setAutoMixLowPass(low);
    }
  }
}

/// The access this app's sound sync uses. Tests override it.
final linkSoundSettingsAccessProvider = Provider<LinkSoundSettingsAccess>(
  LinkSoundProviderAccess.new,
);

/// This device's sound sync state. Tests override it with memory storage.
final linkSoundSyncProvider = Provider<LinkSoundSync>(
  (ref) => LinkSoundSync(access: ref.watch(linkSoundSettingsAccessProvider)),
);
