import 'dart:convert';

import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';

/// Mornye Link sound settings sync: the sound a user saved travels between
/// the phone and the paired computer when the phone's "Sync sound settings"
/// switch is on. The desktop answers any phone that asks.
///
/// Synced items:
///   `eqPreset`, key = the preset name: one of the user's own equalizer
///   presets, `data` = `{"settings": EqualizerSettings JSON}` (the same
///   model and band counts on every platform, so it converts without loss).
///   `setting`, key = one of [LinkSoundSettingKeys.all], `data` =
///   `{"value": ...}`: volume normalization level and mode, and the shape of
///   AutoMix transitions.
///   `songLyricOffset`, key = the song's title and artist as
///   `songLyricsOffsetKey` makes it (`"title|artist"`, trimmed and
///   lowercased), `data` = `{"offsetMs": int}` (-2000 to 2000, never 0):
///   one song's own lyric timing offset. A song put back in sync is a
///   tombstone, so an older offset does not return. Both devices keep every
///   song's offset, whether or not they have the song.
///
/// Not synced, on purpose: the curve playing now and the equalizer switch,
/// the switches that turn normalization, gapless and AutoMix on (a device
/// can have its own reasons, such as bit-perfect USB, exclusive output or a
/// slow phone), the one that lets normalization raise quiet songs (only some
/// outputs have a limiter), volume, speed and pitch, the loud volume warning, the
/// app-wide lyric timing offset (it makes up for this device's own output
/// delay, such as Bluetooth), output devices, direct USB, spatial audio and
/// skip silence.
///
/// `POST /mornye/v1/preferences`, body `{"device": sync id, "items": [Item]}`
/// with every item the phone holds, tombstones included. The desktop merges
/// them and replies `{"device": its sync id, "items": [Item]}` with every
/// item it holds after the merge; the phone merges the reply. One exchange
/// leaves both sides equal.
///
/// Item: `{"kind", "key", "updatedMs": int, "origin": author sync id,
///   "deleted": bool, "data": {...} (absent when deleted)}`.
///
/// Conflicts: last writer wins per (kind, key) by `updatedMs`, ties broken
/// by the greater `origin`, as collections sync does. A deleted preset or
/// song offset stays as a tombstone so an older copy never brings it back.
/// A song offset is dated by when it was set, not when a sync noticed it.
///
/// The desktop sends `{"type": "preferences.changed"}` over the WebSocket
/// when its side changed (a local edit, or a phone's items it applied); a
/// phone with the switch on syncs again.
abstract final class LinkSoundSyncOps {
  static const preferences = 'preferences';
}

abstract final class LinkSoundSyncMessages {
  static const preferencesChanged = 'preferences.changed';
}

abstract final class LinkSoundKinds {
  static const eqPreset = 'eqPreset';
  static const setting = 'setting';
  static const songLyricOffset = 'songLyricOffset';
}

/// The longest song key kept, in characters.
const linkSoundMaxSongKeyLength = 512;

/// The settings that travel, by their [AppSettings] field names.
abstract final class LinkSoundSettingKeys {
  static const normalizationPreamp = 'playbackNormalizationPreamp';
  static const normalizationMode = 'playbackNormalizationMode';
  static const autoMixDuration = 'autoMixDuration';
  static const autoMixEffect = 'autoMixEffect';
  static const autoMixSpeed = 'autoMixSpeed';
  static const autoMixPitch = 'autoMixPitch';
  static const autoMixEcho = 'autoMixEcho';
  static const autoMixLowPass = 'autoMixLowPass';
  static const autoMixMatching = 'autoMixMatching';

  static const all = {
    normalizationPreamp,
    normalizationMode,
    autoMixDuration,
    autoMixEffect,
    autoMixSpeed,
    autoMixPitch,
    autoMixEcho,
    autoMixLowPass,
    autoMixMatching,
  };
}

/// Most items one request may carry: 100 presets, the settings and up to
/// 500 song offsets (`kMaxSongLyricsOffsets`), plus room for tombstones.
const linkSoundMaxItems = 1000;

/// Tombstones kept per device; the oldest go first.
const linkSoundMaxTombstones = 300;

typedef LinkSoundId = (String kind, String key);

/// The synced settings values of [settings], normalized as the setters
/// store them.
Map<String, Object> linkSoundSettingValues(AppSettings settings) => {
  LinkSoundSettingKeys.normalizationPreamp:
      settings.playbackNormalizationPreamp,
  LinkSoundSettingKeys.normalizationMode: settings.playbackNormalizationMode,
  LinkSoundSettingKeys.autoMixDuration: settings.autoMixDuration,
  LinkSoundSettingKeys.autoMixEffect: settings.autoMixEffect.name,
  LinkSoundSettingKeys.autoMixSpeed: settings.autoMixSpeed,
  LinkSoundSettingKeys.autoMixPitch: settings.autoMixPitch,
  LinkSoundSettingKeys.autoMixEcho: settings.autoMixEcho,
  LinkSoundSettingKeys.autoMixLowPass: settings.autoMixLowPass,
  LinkSoundSettingKeys.autoMixMatching: settings.autoMixMatching.name,
};

/// [value] for setting [key] as this app stores it, or null when it is not
/// one.
Object? linkSoundSettingValue(String key, Object? value) => switch (key) {
  LinkSoundSettingKeys.normalizationPreamp when value is num =>
    playbackNormalizationPreampFromJson(value),
  LinkSoundSettingKeys.normalizationMode when value is String =>
    playbackNormalizationModeFromJson(value),
  LinkSoundSettingKeys.autoMixDuration when value is num =>
    autoMixDurationFromJson(value),
  LinkSoundSettingKeys.autoMixEffect when value is String =>
    AutoMixEffect.values.any((effect) => effect.name == value) ? value : null,
  LinkSoundSettingKeys.autoMixSpeed when value is num => autoMixSpeedFromJson(
    value,
  ),
  LinkSoundSettingKeys.autoMixPitch when value is num => autoMixPitchFromJson(
    value,
  ),
  LinkSoundSettingKeys.autoMixEcho ||
  LinkSoundSettingKeys.autoMixLowPass when value is bool => value,
  LinkSoundSettingKeys.autoMixMatching when value is String =>
    AutoMixMatching.values.any((level) => level.name == value) ? value : null,
  _ => null,
};

/// A stable text form of a JSON value for comparing two devices' copies:
/// map keys sorted and every number as a double, so `6` and `6.0` agree.
String linkSoundCanonical(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? value) => switch (value) {
  final Map<dynamic, dynamic> map => {
    for (final key in map.keys.map((key) => '$key').toList()..sort())
      key: _canonical(map[key]),
  },
  final List<dynamic> list => [for (final item in list) _canonical(item)],
  final num number => number.toDouble(),
  _ => value,
};

int? _int(Object? value) => switch (value) {
  final num number when number.isFinite => number.toInt(),
  _ => null,
};

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// One author's version of one synced value.
class LinkSoundItem {
  const LinkSoundItem({
    required this.kind,
    required this.key,
    required this.updatedMs,
    required this.origin,
    this.deleted = false,
    this.data,
  });

  final String kind;
  final String key;
  final int updatedMs;
  final String origin;
  final bool deleted;

  /// Absent when [deleted].
  final Map<String, dynamic>? data;

  LinkSoundId get id => (kind, key);

  /// Whether this version replaces [other] under last writer wins.
  bool winsOver(LinkSoundItem other) =>
      updatedMs > other.updatedMs ||
      (updatedMs == other.updatedMs && origin.compareTo(other.origin) > 0);

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'key': key,
    'updatedMs': updatedMs,
    'origin': origin,
    'deleted': deleted,
    if (!deleted && data != null) 'data': data,
  };

  /// Parses and normalizes an item. Returns null for an unknown kind or
  /// setting, or for data this app cannot use, so nothing malformed is kept
  /// or passed on.
  static LinkSoundItem? fromJson(Object? json, {String? fallbackOrigin}) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final origin = _string(json['origin']) ?? fallbackOrigin;
    final updatedMs = _int(json['updatedMs']);
    if (origin == null || updatedMs == null || updatedMs < 0) return null;
    final deleted = json['deleted'] == true;
    final raw = json['data'];
    switch (kind) {
      case LinkSoundKinds.eqPreset:
        final name = json['key'];
        if (name is! String) return null;
        final key = name.trim();
        if (key.isEmpty || key.length > 80) return null;
        Map<String, dynamic>? data;
        if (!deleted) {
          if (raw is! Map || raw['settings'] is! Map) return null;
          try {
            data = {
              'settings': EqualizerSettings.fromJson(
                Map<String, dynamic>.from(raw['settings'] as Map),
              ).toJson(),
            };
          } on FormatException {
            return null;
          }
        }
        return LinkSoundItem(
          kind: LinkSoundKinds.eqPreset,
          key: key,
          updatedMs: updatedMs,
          origin: origin,
          deleted: deleted,
          data: data,
        );
      case LinkSoundKinds.setting:
        final key = json['key'];
        if (key is! String || !LinkSoundSettingKeys.all.contains(key)) {
          return null;
        }
        // A setting always has a value; it is never deleted.
        if (deleted || raw is! Map) return null;
        final value = linkSoundSettingValue(key, raw['value']);
        if (value == null) return null;
        return LinkSoundItem(
          kind: LinkSoundKinds.setting,
          key: key,
          updatedMs: updatedMs,
          origin: origin,
          data: {'value': value},
        );
      case LinkSoundKinds.songLyricOffset:
        final name = json['key'];
        if (name is! String) return null;
        // Lowercasing a key made by this app changes nothing; it only lines
        // up a differently cased one with the songs here.
        final key = name.trim().toLowerCase();
        // A title, then `|` and the artist (which may be empty).
        if (key.indexOf('|') <= 0 || key.length > linkSoundMaxSongKeyLength) {
          return null;
        }
        Map<String, dynamic>? data;
        if (!deleted) {
          final offset = raw is Map ? raw['offsetMs'] : null;
          if (offset is! num || !offset.isFinite) return null;
          final offsetMs = normalizeLyricsOffsetMs(offset);
          // In sync is a deletion, never a live value.
          if (offsetMs == 0) return null;
          data = {'offsetMs': offsetMs};
        }
        return LinkSoundItem(
          kind: LinkSoundKinds.songLyricOffset,
          key: key,
          updatedMs: updatedMs,
          origin: origin,
          deleted: deleted,
          data: data,
        );
      default:
        return null;
    }
  }

  static List<LinkSoundItem> listFromJson(
    Object? json, {
    String? fallbackOrigin,
  }) => json is List
      ? [
          for (final item in json.take(linkSoundMaxItems))
            ?LinkSoundItem.fromJson(item, fallbackOrigin: fallbackOrigin),
        ]
      : const [];
}
