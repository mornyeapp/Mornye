import 'dart:async';

import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/network_library_scanner.dart'
    show networkLibraryRow;
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/file_access.dart' show fileExists;
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkMetadata');

/// A tag a Link Library row carries, which a saved copy can take from it.
enum LinkMetadataField {
  title('title'),
  artist('artist'),
  album('album'),
  albumArtist('album_artist'),
  genre('genre'),
  year('date'),
  trackNumber('track_number'),
  discNumber('disc_number'),
  isrc('isrc');

  const LinkMetadataField(this.editorKey);

  /// The metadata editor's key for this tag.
  final String editorKey;
}

/// One tag that differs between a saved copy and the computer's song.
class LinkMetadataDifference {
  const LinkMetadataDifference(
    this.field, {
    required this.phone,
    required this.computer,
  });

  final LinkMetadataField field;

  /// The copy's value, empty when it has none.
  final String phone;

  /// The computer's value, written as it is.
  final String computer;

  @override
  bool operator ==(Object other) =>
      other is LinkMetadataDifference &&
      other.field == field &&
      other.phone == phone &&
      other.computer == computer;

  @override
  int get hashCode => Object.hash(field, phone, computer);

  @override
  String toString() => '${field.name}: "$phone" -> "$computer"';
}

// The placeholders a Link host and the Library scanner put in empty tags.
const _unknownArtist = 'Unknown Artist';
const _unknownAlbum = 'Unknown Album';
const _variousArtists = 'Various Artists';

String? _text(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

String? _computerText(String? value, String placeholder) {
  final text = _text(value);
  return text == placeholder ? null : text;
}

String? _year(String? date) =>
    RegExp(r'^\s*(\d{4})').firstMatch(date ?? '')?.group(1);

int? _positive(int? value) => value != null && value > 0 ? value : null;

String? _isrc(String? value) {
  final code = (value ?? '').toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  return code.isEmpty ? null : code;
}

/// The tags in which [copy] differs from [computer], the computer's Library
/// row of the song it was saved from. Only a tag the computer has counts,
/// since a Link row cannot tell an empty tag from one it does not send:
/// text is trimmed, a year matches a full date of that year, ISRCs ignore
/// case and hyphens, and an empty disc number matches disc 1.
List<LinkMetadataDifference> linkMetadataDifferences(
  DownloadHistoryItem copy,
  LocalLibraryItem computer,
) {
  final differences = <LinkMetadataDifference>[];
  void text(LinkMetadataField field, String? phone, String? value) {
    final current = _text(phone);
    if (value == null || current == value) return;
    differences.add(
      LinkMetadataDifference(field, phone: current ?? '', computer: value),
    );
  }

  void number(LinkMetadataField field, int? phone, int? value) {
    final current = _positive(phone);
    if (value == null || current == value) return;
    if (field == LinkMetadataField.discNumber &&
        current == null &&
        value == 1) {
      return;
    }
    differences.add(
      LinkMetadataDifference(
        field,
        phone: current?.toString() ?? '',
        computer: '$value',
      ),
    );
  }

  final artist = _computerText(computer.artistName, _unknownArtist);
  text(LinkMetadataField.title, copy.trackName, _text(computer.trackName));
  text(LinkMetadataField.artist, copy.artistName, artist);
  text(
    LinkMetadataField.album,
    copy.albumName,
    _computerText(computer.albumName, _unknownAlbum),
  );
  // A host names an album artist for every song, the song artist or
  // Various Artists when the tag is empty; those fill no empty tag.
  final albumArtist = _computerText(computer.albumArtist, _unknownArtist);
  if (_text(copy.albumArtist) != null ||
      (albumArtist != artist && albumArtist != _variousArtists)) {
    text(LinkMetadataField.albumArtist, copy.albumArtist, albumArtist);
  }
  text(LinkMetadataField.genre, copy.genre, _text(computer.genre));
  final year = _year(computer.releaseDate);
  if (year != null && _year(copy.releaseDate) != year) {
    differences.add(
      LinkMetadataDifference(
        LinkMetadataField.year,
        phone: _text(copy.releaseDate) ?? '',
        computer: year,
      ),
    );
  }
  number(
    LinkMetadataField.trackNumber,
    copy.trackNumber,
    _positive(computer.trackNumber),
  );
  number(
    LinkMetadataField.discNumber,
    copy.discNumber,
    _positive(computer.discNumber),
  );
  final isrc = _isrc(computer.isrc);
  if (isrc != null && _isrc(copy.isrc) != isrc) {
    differences.add(
      LinkMetadataDifference(
        LinkMetadataField.isrc,
        phone: _text(copy.isrc) ?? '',
        computer: isrc,
      ),
    );
  }
  return differences;
}

/// [copy]'s history record with [changes] taken from the computer.
DownloadHistoryItem linkMetadataApplied(
  DownloadHistoryItem copy,
  Iterable<LinkMetadataDifference> changes,
) {
  var item = copy;
  for (final change in changes) {
    final value = change.computer;
    item = switch (change.field) {
      LinkMetadataField.title => item.copyWith(trackName: value),
      LinkMetadataField.artist => item.copyWith(artistName: value),
      LinkMetadataField.album => item.copyWith(albumName: value),
      LinkMetadataField.albumArtist => item.copyWith(albumArtist: value),
      LinkMetadataField.genre => item.copyWith(genre: value),
      LinkMetadataField.year => item.copyWith(releaseDate: value),
      LinkMetadataField.trackNumber => item.copyWith(
        trackNumber: int.tryParse(value),
      ),
      LinkMetadataField.discNumber => item.copyWith(
        discNumber: int.tryParse(value),
      ),
      LinkMetadataField.isrc => item.copyWith(isrc: value),
    };
  }
  return item;
}

/// The editor tags that write [changes] into [copy]'s file. A number goes
/// with the copy's total, which a write of the number alone would drop.
Map<String, String> linkMetadataTags(
  DownloadHistoryItem copy,
  Iterable<LinkMetadataDifference> changes,
) {
  final tags = <String, String>{};
  void total(String key, int? value) {
    if (value != null && value > 0) tags[key] = '$value';
  }

  for (final change in changes) {
    tags[change.field.editorKey] = change.computer;
    if (change.field == LinkMetadataField.trackNumber) {
      total('track_total', copy.totalTracks);
    } else if (change.field == LinkMetadataField.discNumber) {
      total('disc_total', copy.totalDiscs);
    }
  }
  return tags;
}

/// A saved copy whose tags differ from its song on the computer.
class LinkMetadataCandidate {
  const LinkMetadataCandidate({required this.copy, required this.differences});

  final DownloadHistoryItem copy;
  final List<LinkMetadataDifference> differences;
}

/// Finds the copies this phone saved from [server] whose tags differ from
/// the computer's songs they came from.
class LinkMetadataCollector {
  LinkMetadataCollector({
    required this.server,
    required this.copies,
    required this.computerSongs,
    this.exists = fileExists,
  });

  final LinkServerRecord server;

  /// Every download history record of this phone.
  final Future<List<DownloadHistoryItem>> Function() copies;

  /// The computer's songs as Library rows, read fresh from it.
  final Stream<LocalLibraryItem> Function() computerSongs;

  /// Whether a copy's file is still on this phone.
  final Future<bool> Function(String path) exists;

  /// The copies to review, in history order. A copy whose song the computer
  /// no longer has, or whose file is gone, is left out. [cancelled] stops
  /// the walk and answers no copies.
  Future<List<LinkMetadataCandidate>> collect({
    bool Function()? cancelled,
  }) async {
    final saved = [
      for (final copy in await copies())
        if (copy.service == LinkOfflineSaver.service) copy,
    ];
    // A copy names its song through its origin; an older record only
    // through its id, which hashes the song id.
    final byOrigin = <String, List<DownloadHistoryItem>>{};
    final byId = <String, DownloadHistoryItem>{};
    for (final copy in saved) {
      final origin = copy.originFilePath;
      if (origin == null) {
        byId[copy.id] = copy;
      } else if (linkDesktopSongId(origin, server) case final songId?) {
        (byOrigin[songId] ??= []).add(copy);
      }
    }
    if (byOrigin.isEmpty && byId.isEmpty) return const [];
    final matched = <String, LocalLibraryItem>{};
    final walked = Completer<bool>();
    late final StreamSubscription<LocalLibraryItem> subscription;
    // Ends without waiting for the cancel, which a stream may never answer.
    void finish(bool complete) {
      if (walked.isCompleted) return;
      walked.complete(complete);
      unawaited(subscription.cancel());
    }

    subscription = computerSongs().listen(
      (song) {
        if (cancelled?.call() ?? false) return finish(false);
        final songId = linkDesktopSongId(song.filePath, server);
        if (songId == null) return;
        for (final copy
            in byOrigin.remove(songId) ?? const <DownloadHistoryItem>[]) {
          matched[copy.id] = song;
        }
        final id = linkOfflineHistoryId(server.serverId, songId);
        if (byId.remove(id) case final copy?) matched[copy.id] = song;
        // The rest of the catalog holds none of the saved songs.
        if (byOrigin.isEmpty && byId.isEmpty) finish(true);
      },
      onError: (Object error, StackTrace stack) {
        if (!walked.isCompleted) walked.completeError(error, stack);
      },
      onDone: () => finish(true),
      cancelOnError: true,
    );
    if (!await walked.future) return const [];
    final candidates = <LinkMetadataCandidate>[];
    for (final copy in saved) {
      final song = matched[copy.id];
      if (song == null) continue;
      final differences = linkMetadataDifferences(copy, song);
      if (differences.isEmpty) continue;
      if (cancelled?.call() ?? false) return const [];
      if (!await _exists(copy.filePath)) continue;
      candidates.add(
        LinkMetadataCandidate(copy: copy, differences: differences),
      );
    }
    return candidates;
  }

  Future<bool> _exists(String path) async {
    try {
      return await exists(path);
    } on Object {
      return false;
    }
  }
}

/// The computer's songs, read through [server]'s Subsonic connection and
/// mapped as a Library scan maps them.
Stream<LocalLibraryItem> linkComputerCatalog(
  LinkServerRecord server, {
  NetworkStorageService? storage,
}) async* {
  final network = storage ?? NetworkStorageService.instance;
  final client = network.openSubsonic(
    await network.connection(server.connectionId),
  );
  try {
    await for (final song in client.catalog(checkpoint: () async {})) {
      final source = NetworkStorageService.source(
        server.connectionId,
        song.path,
      );
      yield LocalLibraryItem.fromJson({
        ...networkLibraryRow(source, song.entry, song.metadata),
        'id': source,
      });
    }
  } finally {
    client.close();
  }
}

/// The tags to write into one copy.
class LinkMetadataUpdate {
  const LinkMetadataUpdate({required this.copy, required this.changes});

  final DownloadHistoryItem copy;
  final List<LinkMetadataDifference> changes;
}

class LinkMetadataApplyResult {
  const LinkMetadataApplyResult({required this.updated, required this.failed});

  /// The copies written, each with its record as it is now.
  final List<DownloadHistoryItem> updated;
  final int failed;
}

/// Writes the chosen computer tags into the copies' files, then their
/// history records, as the metadata editor saves a partial edit.
class LinkMetadataApplier {
  LinkMetadataApplier({
    required this.record,
    required this.artistTagMode,
    Future<MetadataSaveResult> Function(MetadataSaveRequest request)? save,
    Future<void> Function(String path)? publish,
  }) : save = save ?? _saveWithEditor,
       publish = publish ?? SourceMetadataEvents.instance.publish;

  /// Saves a copy's new history record, updating the Library.
  final Future<void> Function(DownloadHistoryItem item) record;
  final String Function() artistTagMode;
  final Future<MetadataSaveResult> Function(MetadataSaveRequest request) save;

  /// Tells the player and open pages a file's tags changed.
  final Future<void> Function(String path) publish;

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

  /// Updates [updates] one by one; a copy that fails is counted and the
  /// rest go on.
  Future<LinkMetadataApplyResult> apply(
    List<LinkMetadataUpdate> updates, {
    void Function(int done, int total)? onProgress,
  }) async {
    final updated = <DownloadHistoryItem>[];
    var failed = 0;
    final mode = artistTagMode();
    for (final (index, update) in updates.indexed) {
      onProgress?.call(index, updates.length);
      if (update.changes.isEmpty) continue;
      try {
        final saved = await save(
          MetadataSaveRequest(
            filePath: update.copy.filePath,
            metadata: linkMetadataTags(update.copy, update.changes),
            artistTagMode: mode,
            preserveUnspecifiedTags: true,
          ),
        );
        if (saved.failure != null) {
          _log.w('Tags not written: ${saved.failure!.name} ${saved.error}');
          failed++;
          continue;
        }
        final item = linkMetadataApplied(update.copy, update.changes);
        await record(item);
        updated.add(item);
      } on Object catch (error) {
        _log.w('Tags not updated: $error');
        failed++;
        continue;
      }
      try {
        await publish(update.copy.filePath);
      } on Object catch (error) {
        _log.w('Could not announce changed tags: $error');
      }
    }
    onProgress?.call(updates.length, updates.length);
    return LinkMetadataApplyResult(updated: updated, failed: failed);
  }
}

/// Compares and updates the copies saved from one Link host.
class LinkMetadataUpdater {
  const LinkMetadataUpdater({
    required this.name,
    required this.collector,
    required this.applier,
  });

  /// The host's name for labels.
  final String name;
  final LinkMetadataCollector collector;
  final LinkMetadataApplier applier;
}
