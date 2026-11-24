import 'dart:io';

import 'package:mornye/models/settings.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/re_enrich_undo_store.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AppLogger('ReEnrichUndo');

/// The metadata editor keys a re-enrich change writes. A track or disc
/// number is written with its total, so both go back together.
const _editorKeys = <String, List<String>>{
  'track_name': ['title'],
  'artist_name': ['artist'],
  'album_name': ['album'],
  'album_artist': ['album_artist'],
  'release_date': ['date'],
  'isrc': ['isrc'],
  'genre': ['genre'],
  'label': ['label'],
  'copyright': ['copyright'],
  'composer': ['composer'],
  'track_number': ['track_number', 'track_total'],
  'total_tracks': ['track_number', 'track_total'],
  'disc_number': ['disc_number', 'disc_total'],
  'total_discs': ['disc_number', 'disc_total'],
};

/// The key of an editor tag in a file metadata read.
String _readKey(String editorKey) => switch (editorKey) {
  'track_total' => 'total_tracks',
  'disc_total' => 'total_discs',
  _ => editorKey,
};

String _tagText(Object? value) {
  if (value == null || (value is num && value == 0)) return '';
  final text = value.toString();
  return text.trim() == '0' ? '' : text;
}

Object? _itemValue(LocalLibraryItem item, String editorKey) =>
    switch (editorKey) {
      'title' => item.trackName,
      'artist' => item.artistName,
      'album' => item.albumName,
      'album_artist' => item.albumArtist,
      'date' => item.releaseDate,
      'isrc' => item.isrc,
      'genre' => item.genre,
      'label' => item.label,
      'copyright' => item.copyright,
      'composer' => item.composer,
      'track_number' => item.trackNumber,
      'track_total' => item.totalTracks,
      'disc_number' => item.discNumber,
      'disc_total' => item.totalDiscs,
      _ => null,
    };

/// What a re-enrich is about to replace, read from the file just before
/// the write. Its cover copy is temporary until [ReEnrichUndo.commit].
class ReEnrichUndoDraft {
  ReEnrichUndoDraft._({
    required this.tags,
    required this.coverChanges,
    this.coverFile,
    String? coverDirectory,
    this.lyrics,
    this.lrc,
  }) : _coverDirectory = coverDirectory;

  /// Editor keys with the values the song has now.
  final Map<String, String> tags;

  /// The write replaces the embedded cover.
  final bool coverChanges;

  /// A copy of the embedded cover, or null when the song has none.
  final String? coverFile;
  final String? _coverDirectory;

  /// The embedded lyrics, or null when the write cannot change them or they
  /// could not be read.
  final String? lyrics;

  /// The `.lrc` text next to the song, empty when it has none, or null when
  /// undo would leave the sidecar as it is.
  final String? lrc;

  Future<void> discard() async {
    final directory = _coverDirectory;
    if (directory == null) return;
    try {
      await Directory(directory).delete(recursive: true);
    } catch (_) {}
  }
}

enum ReEnrichUndoOutcome {
  /// The previous metadata is back.
  restored,

  /// The previous tags and lyrics are back, but the cover re-enrich added
  /// to a song without one stays.
  coverKept,

  /// No state is saved for the song, or a later re-enrich replaced it.
  missing,

  /// Writing the previous metadata failed; the state is kept.
  failed,
}

class ReEnrichUndoResult {
  const ReEnrichUndoResult(this.outcome, [this.error]);

  final ReEnrichUndoOutcome outcome;
  final Object? error;

  bool get restored =>
      outcome == ReEnrichUndoOutcome.restored ||
      outcome == ReEnrichUndoOutcome.coverKept;
}

/// Saves what a re-enrich replaces and writes it back on request, through
/// the metadata editor's write path: unlike the re-enrich write it can
/// clear a tag and embed a cover file, and it serves the same storage
/// (device paths, Android documents and network storage).
class ReEnrichUndo {
  ReEnrichUndo({
    ReEnrichUndoStore? store,
    Future<Map<String, dynamic>> Function(String path)? readTags,
    Future<bool> Function(String audioPath, String outputPath)? extractCover,
    this.sidecars = const LyricsSidecarStore(extension: 'lrc'),
    Future<MetadataSaveResult> Function(MetadataSaveRequest request)? save,
    DateTime Function()? clock,
  }) : store = store ?? ReEnrichUndoStore.instance,
       _readTags = readTags ?? PlatformBridge.readFileMetadata,
       _extractCover = extractCover ?? _extractEmbeddedCover,
       _save = save ?? _saveWithEditor,
       _clock = clock ?? DateTime.now;

  static final instance = ReEnrichUndo();

  final ReEnrichUndoStore store;
  final LyricsSidecarStore sidecars;
  final Future<Map<String, dynamic>> Function(String path) _readTags;
  final Future<bool> Function(String audioPath, String outputPath)
  _extractCover;
  final Future<MetadataSaveResult> Function(MetadataSaveRequest request) _save;
  final DateTime Function() _clock;

  static Future<bool> _extractEmbeddedCover(String audio, String output) async {
    final result = await PlatformBridge.extractCoverToFile(audio, output);
    return result['error'] == null && result['success'] != false;
  }

  static Future<MetadataSaveResult> _saveWithEditor(
    MetadataSaveRequest request,
  ) async {
    final covers = MetadataCoverResources();
    try {
      return await MetadataPersistenceService(covers: covers).save(request);
    } finally {
      await covers.dispose();
    }
  }

  /// Reads what writing [preview] to the file at [path] would replace. The
  /// song's own source is [BatchReEnrichPreview.item]; [path] differs from
  /// it for a network song, which is written through a local copy.
  Future<ReEnrichUndoDraft?> capture(
    BatchReEnrichPreview preview,
    String path,
    AppSettings settings,
  ) async {
    final fields = {for (final change in preview.changes) change.field};
    final editorKeys = {for (final field in fields) ...?_editorKeys[field]};
    final coverChanges =
        fields.contains('cover_url') &&
        preview.updateFields.contains(ReEnrichFields.cover);
    final lyricsChange = fields.contains('lyrics');
    if (editorKeys.isEmpty && !coverChanges && !lyricsChange) return null;

    Map<String, dynamic>? current;
    try {
      final read = await _readTags(path);
      if (read['error'] == null) current = read;
    } catch (error) {
      _log.w('Using Library values for undo: ${error.runtimeType}');
    }
    final mode = settings.lyricsMode.trim().toLowerCase();
    final source = preview.item.filePath;
    String? coverDirectory;
    String? coverFile;
    if (coverChanges) {
      try {
        coverDirectory = (await Directory.systemTemp.createTemp(
          'reenrich_undo_',
        )).path;
        final output = p.join(coverDirectory, 'cover.jpg');
        if (await _extractCover(path, output) &&
            await File(output).exists() &&
            await File(output).length() > 0) {
          coverFile = output;
        }
      } catch (_) {
        // A song without a readable cover has none to restore.
      }
    }
    return ReEnrichUndoDraft._(
      tags: {
        for (final key in editorKeys)
          key: _tagText(
            current == null
                ? _itemValue(preview.item, key)
                : current[_readKey(key)],
          ),
      },
      coverChanges: coverChanges,
      coverFile: coverFile,
      coverDirectory: coverDirectory,
      lyrics: lyricsChange && mode != 'external' && current != null
          ? current['lyrics']?.toString() ?? ''
          : null,
      lrc:
          lyricsChange &&
              settings.embedLyrics &&
              (mode == 'external' || mode == 'both') &&
              !source.startsWith('network://')
          ? await _previousLrc(source)
          : null,
    );
  }

  /// The sidecar text, empty when there is none, or null when undo cannot
  /// put it back as it was: one too large to read, or an Android document
  /// that undo could not delete again.
  Future<String?> _previousLrc(String source) async {
    if (!sidecars.canWrite(source)) return null;
    try {
      final text = await sidecars.read(source);
      if (text != null) return text;
      if (isContentUri(source)) return null;
      final file = File(sidecarPathFor(source, sidecars.extension));
      return await file.exists() ? null : '';
    } catch (_) {
      return null;
    }
  }

  /// Saves [draft] as the previous state of [source] after its re-enrich
  /// wrote [result], keeping only what the write changed. Returns whether a
  /// state was saved.
  Future<bool> commit(
    ReEnrichUndoDraft draft,
    String source,
    Map<String, dynamic> result, {
    String? batch,
  }) async {
    final status = result['lyrics_status'];
    final lyricsChanged = status == 'updated' || status == 'instrumental';
    // An FFmpeg plan without a new cover file embeds the current one again.
    final coverWritten =
        draft.coverChanges &&
        (result['method'] != 'ffmpeg' ||
            (result['cover_path']?.toString().trim().isNotEmpty ?? false));
    final tags = {
      ...draft.tags,
      if (lyricsChanged && draft.lyrics != null) 'lyrics': draft.lyrics!,
    };
    final lrc = result['write_external_lrc'] == true ? draft.lrc : null;
    if (tags.isEmpty && !coverWritten && lrc == null) return false;
    try {
      await store.save(
        ReEnrichUndoState(
          source: source,
          savedAt: _clock(),
          tags: tags,
          coverAdded: coverWritten && draft.coverFile == null,
          lrc: lrc,
          batch: batch,
        ),
        coverFile: coverWritten ? draft.coverFile : null,
      );
      return true;
    } catch (error) {
      _log.w('Could not save the state before re-enrich: $error');
      return false;
    }
  }

  /// Whether [source] has a state to restore, saved by [batch] if given.
  Future<bool> canUndo(String source, {String? batch}) async {
    final state = await store.read(source);
    return state != null && (batch == null || state.batch == batch);
  }

  /// Writes back the state saved for [source], then forgets it. With
  /// [batch], only a state that run saved is restored.
  Future<ReEnrichUndoResult> restore(
    String source, {
    required String artistTagMode,
    String? batch,
  }) async {
    final state = await store.read(source);
    if (state == null || (batch != null && state.batch != batch)) {
      return const ReEnrichUndoResult(ReEnrichUndoOutcome.missing);
    }
    final cover = await store.coverPath(state);
    if (state.tags.isNotEmpty || cover != null) {
      final saved = await _save(
        MetadataSaveRequest(
          filePath: source,
          metadata: state.tags,
          artistTagMode: artistTagMode,
          selectedCoverPath: cover,
          preserveUnspecifiedTags: true,
        ),
      );
      if (saved.failure != null) {
        return ReEnrichUndoResult(
          ReEnrichUndoOutcome.failed,
          saved.error ?? saved.failure,
        );
      }
    }
    if (state.lrc case final lrc?) {
      try {
        if (lrc.isNotEmpty) {
          await sidecars.write(source, lrc);
        } else if (!isContentUri(source)) {
          await deleteFileQuietly(
            File(sidecarPathFor(source, sidecars.extension)),
          );
        }
      } catch (error) {
        _log.w('Could not restore the lyrics file: $error');
      }
    }
    await store.remove(source);
    return ReEnrichUndoResult(
      state.coverAdded
          ? ReEnrichUndoOutcome.coverKept
          : ReEnrichUndoOutcome.restored,
    );
  }
}
