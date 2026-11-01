import 'package:flutter/foundation.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/history_database.dart';

/// Collection providers replace their track list when its contents change.
/// Keep derived data across selection/layout rebuilds of the same snapshot.
class LibraryTracksFolderData {
  List<CollectionTrackEntry>? _entries;
  Set<String> keys = const {};
  List<Track> tracks = const [];
  final _history = TrackHistorySnapshot();
  HistoryBatchLookupRequest get historyRequest => _history.request;
  List<String> get historyLookupKeys => _history.lookupKeys;
  List<Track>? _newestFirstTracks;
  Set<String>? _inHistoryKeys;
  List<bool> _inHistory = const [];

  /// The tracks by `addedAt`, newest first.
  List<Track> get newestFirstTracks => _newestFirstTracks ??= [
    for (final entry in [
      ...?_entries,
    ]..sort((a, b) => b.addedAt.compareTo(a.addedAt)))
      entry.track,
  ];

  /// Whether each track's lookup key is in [existingKeys].
  List<bool> inHistory(Set<String> existingKeys) {
    if (!setEquals(existingKeys, _inHistoryKeys)) {
      _inHistoryKeys = Set.of(existingKeys);
      _inHistory = [
        for (final key in historyLookupKeys) existingKeys.contains(key),
      ];
    }
    return _inHistory;
  }

  void update(List<CollectionTrackEntry> entries) {
    if (identical(entries, _entries)) return;
    _entries = entries;
    keys = Set.unmodifiable(entries.map((entry) => entry.key));
    tracks = List.unmodifiable(entries.map((entry) => entry.track));
    _history.update(tracks);
    _newestFirstTracks = null;
    _inHistoryKeys = null;
  }
}
