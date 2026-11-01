import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';

/// Retains derived lookups while the immutable source list is unchanged.
/// Callers replace their list for metadata, order, or filter changes.
class TrackHistorySnapshot {
  List<Track>? _source;
  HistoryBatchLookupRequest request = HistoryBatchLookupRequest.snapshot([]);

  List<HistoryLookupRequest> get lookups => request.tracks;

  List<String> get lookupKeys => request.lookupKeys;

  void update(List<Track> tracks) {
    if (identical(tracks, _source)) return;
    _source = tracks;
    request = HistoryBatchLookupRequest.snapshot(
      tracks.map(historyLookupForTrack),
    );
  }
}
