import 'dart:io';

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/file_access.dart' as files;
import 'package:mornye/utils/playback_artwork.dart';

final _log = AppLogger('MusicPlayer');

typedef PlaybackResumePreview = ({PlayableMedia media, Duration position});

Future<PlaybackResumePreview?> loadPlaybackResumePreview(
  MusicPlayerRuntime runtime,
) async {
  try {
    final preview = await runtime.dependencies.sessionDatabase
        .getPlaybackResumePreview();
    if (preview == null || preview['media'] is! Map) return null;
    final documents = runtime.dependencies.isIOS
        ? (await getApplicationDocumentsDirectory()).path
        : null;
    final media = PlayableMedia.fromJson(
      Map<String, dynamic>.from(preview['media'] as Map),
      iosDocumentsPath: documents,
    );
    if (media == null ||
        (!media.isNetwork && !await files.fileExists(media.source))) {
      return null;
    }
    return (
      media: media,
      position: Duration(
        milliseconds: (preview['positionMs'] as num?)?.toInt() ?? 0,
      ),
    );
  } catch (error) {
    _log.w('Failed to load playback resume preview: $error');
    return null;
  }
}

/// Resolve a saved queue in bounded groups, retaining its original order even
/// when later file checks finish first. File existence is shared across tracks
/// with the same artwork for this restore only, with a bounded LRU cache.
Future<
  ({
    List<PlayableMedia> items,
    List<int> keptOriginalIndices,
    bool artworkRelocated,
  })
>
prepareRestoredPlaybackMedia(
  List<Object?> rawMedia, {
  String? iosDocumentsPath,
  required Future<String?> Function(PlayableMedia) loadLibraryCoverPath,
  Future<bool> Function(String)? fileExists,
}) async {
  const batchSize = 8;
  final checks = <String, Future<bool>>{};
  Future<bool> exists(String path) {
    final pending =
        checks.remove(path) ?? (fileExists?.call(path) ?? File(path).exists());
    checks[path] = pending;
    if (checks.length > 256) checks.remove(checks.keys.first);
    return pending;
  }

  Future<(PlayableMedia, int, bool)?> resolve(int index) async {
    final entry = rawMedia[index];
    if (entry is! Map) return null;
    final media = PlayableMedia.fromJson(
      Map<String, dynamic>.from(entry),
      iosDocumentsPath: iosDocumentsPath,
    );
    if (media == null) return null;
    if (!media.isContentUri &&
        !media.isNetwork &&
        !await exists(media.source)) {
      return null;
    }
    final artwork = await resolveRestoredArtworkUri(
      media.artUri,
      fileExists: exists,
      loadLibraryCoverPath: () => loadLibraryCoverPath(media),
    );
    return (
      artwork == media.artUri
          ? media
          : PlayableMedia.fromJson({...media.toJson(), 'artUri': artwork})!,
      index,
      artwork != entry['artUri'],
    );
  }

  final items = <PlayableMedia>[];
  final keptOriginalIndices = <int>[];
  var artworkRelocated = false;
  for (var start = 0; start < rawMedia.length; start += batchSize) {
    final end = (start + batchSize).clamp(0, rawMedia.length);
    final batch = await Future.wait([
      for (var index = start; index < end; index++) resolve(index),
    ]);
    for (final result in batch) {
      if (result == null) continue;
      items.add(result.$1);
      keptOriginalIndices.add(result.$2);
      artworkRelocated |= result.$3;
    }
    // Cached covers and remote tracks can otherwise complete entirely through
    // microtasks and starve rendering while a very large queue is restored.
    if (end % 64 == 0) await Future<void>.delayed(Duration.zero);
  }
  return (
    items: items,
    keptOriginalIndices: keptOriginalIndices,
    artworkRelocated: artworkRelocated,
  );
}

Future<bool> restorePlaybackSession(
  MusicPlayerRuntime runtime, {
  bool fromResume = false,
  int? expectedPlaybackGeneration,
}) async {
  try {
    final database = runtime.dependencies.sessionDatabase;
    final session = fromResume
        ? await database.getPlaybackResumeSession()
        : await database.getPlaybackSession();
    if (session == null) return false;

    Future<void> clear() => fromResume
        ? database.clearPlaybackResume()
        : database.clearPlaybackSession();

    final rawMedia = session['media'];
    if (rawMedia is! List) {
      await clear();
      return false;
    }

    final iosDocumentsPath = runtime.dependencies.isIOS
        ? (await getApplicationDocumentsDirectory()).path
        : null;
    final prepared = await prepareRestoredPlaybackMedia(
      rawMedia,
      iosDocumentsPath: iosDocumentsPath,
      loadLibraryCoverPath: (media) async {
        final database = runtime.dependencies.libraryDatabase;
        final row = await database.getById(media.id);
        if (row != null) return row['coverPath'] as String?;
        final matches = await database.findByTrackAndArtist(
          media.title,
          media.artist,
        );
        for (final row in matches) {
          if (row['filePath'] == media.source) {
            return row['coverPath'] as String?;
          }
        }
        return null;
      },
    );
    final (:items, :keptOriginalIndices, :artworkRelocated) = prepared;
    if (items.isEmpty) {
      await clear();
      return false;
    }

    // Remap the saved index onto the surviving list; if the current track
    // itself was dropped, land on the nearest earlier survivor at 0:00.
    final savedIndex = (session['index'] as num?)?.toInt() ?? 0;
    var index = 0;
    for (var i = 0; i < keptOriginalIndices.length; i++) {
      if (keptOriginalIndices[i] <= savedIndex) index = i;
    }
    var position = Duration(
      milliseconds: (session['positionMs'] as num?)?.toInt() ?? 0,
    );
    if (keptOriginalIndices[index] != savedIndex) {
      position = Duration.zero;
    }

    final handler = await runtime.initialize();
    if (expectedPlaybackGeneration != null &&
        handler.playbackRequestGeneration != expectedPlaybackGeneration) {
      return false;
    }
    await handler.restoreSession(
      items: items,
      index: index,
      position: position,
      shuffle: session['shuffle'] == true,
      originalOrder: [
        for (final i in keptOriginalIndices)
          ((rawMedia[i] as Map)['queueOriginalIndex'] as num?)?.toInt() ?? i,
      ],
      queueNeedsRewrite: items.length != rawMedia.length || artworkRelocated,
      replaceStoppedQueue: fromResume,
      repeatMode: AudioServiceRepeatMode.values.firstWhere(
        (mode) => mode.name == session['repeat'],
        orElse: () => AudioServiceRepeatMode.none,
      ),
    );
    _log.i(
      'Restored playback session: ${items.length} track(s), paused at '
      '${position.inSeconds}s',
    );
    return handler.mediaItem.value != null;
  } catch (e) {
    _log.w('Failed to restore playback session: $e');
    return false;
  }
}
