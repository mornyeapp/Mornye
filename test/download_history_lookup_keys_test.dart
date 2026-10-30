import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  void publish(DownloadHistoryState Function(DownloadHistoryState) update) =>
      state = update(state);
}

class _CountingLookup extends HistoryLookupRequest {
  _CountingLookup({
    required super.spotifyId,
    required super.trackName,
    required super.artistName,
  });

  static int reads = 0;

  @override
  String get spotifyId {
    reads++;
    return super.spotifyId;
  }

  @override
  String get trackName {
    reads++;
    return super.trackName;
  }
}

/// Shares one lookup list across instances, as `copyWith` does for count and
/// revision updates, and counts the index reads of the matching pass.
class _CountingState extends DownloadHistoryState {
  _CountingState(this._lookup, {super.totalCount})
    : super(lookupItems: _lookup);

  final List<DownloadHistoryItem> _lookup;
  static int indexReads = 0;

  @override
  List<DownloadHistoryItem> get lookupItems => _lookup;

  @override
  DownloadHistoryItem? getBySpotifyId(String spotifyId) {
    indexReads++;
    return super.getBySpotifyId(spotifyId);
  }

  @override
  DownloadHistoryItem? findByTrackArtistKey(String key) {
    indexReads++;
    return super.findByTrackArtistKey(key);
  }
}

String _oldTrackArtistKey(String trackName, String artistName) {
  final normalizedTrack = trackName.trim().toLowerCase();
  if (normalizedTrack.isEmpty) return '';
  return '$normalizedTrack|${artistName.trim().toLowerCase()}';
}

/// The per-track matching from before the keys were precomputed, scanning
/// the lookup items instead of the state's indexes.
Set<String> _referenceKeys(
  DownloadHistoryState state,
  List<HistoryLookupRequest> tracks,
  Set<String> persistedKeys,
) {
  bool holdsSpotifyId(String id) =>
      state.lookupItems.any((item) => item.spotifyId == id);
  bool holdsIsrc(String isrc) =>
      state.lookupItems.any((item) => item.isrc == isrc);
  bool holdsTrackArtist(String key) =>
      key.isNotEmpty &&
      state.lookupItems.any(
        (item) => _oldTrackArtistKey(item.trackName, item.artistName) == key,
      );

  final keys = <String>{...persistedKeys};
  for (final track in tracks) {
    final isrc = track.isrc?.trim();
    final found =
        HistoryDatabase.spotifyLookupCandidates(
          track.spotifyId,
        ).any(holdsSpotifyId) ||
        (isrc != null && isrc.isNotEmpty && holdsIsrc(isrc)) ||
        holdsTrackArtist(_oldTrackArtistKey(track.trackName, track.artistName));
    if (found) {
      keys.add(
        '${track.spotifyId.trim()}|${HistoryDatabase.normalizeIsrc(track.isrc)}|'
        '${HistoryDatabase.matchKeyFor(track.trackName, track.artistName)}',
      );
    }
  }
  return keys;
}

DownloadHistoryItem _item(
  int index, {
  String? spotifyId,
  String? isrc,
  String trackName = 'Stored song',
  String artistName = 'Stored artist',
}) => DownloadHistoryItem(
  id: 'item-$index',
  spotifyId: spotifyId,
  isrc: isrc,
  trackName: trackName,
  artistName: artistName,
  albumName: 'Example album',
  filePath: '/music/item-$index.flac',
  service: 'example-provider',
  downloadedAt: DateTime.utc(2026),
);

const _tricky = [
  HistoryLookupRequest(
    spotifyId: 'spotify:track:compact1',
    trackName: 'A',
    artistName: 'B',
  ),
  HistoryLookupRequest(spotifyId: 'prefixed2', trackName: 'C', artistName: 'D'),
  HistoryLookupRequest(
    spotifyId: 'https://open.spotify.com/track/url3?si=x',
    trackName: 'E',
    artistName: 'F',
  ),
  HistoryLookupRequest(
    spotifyId: '  spaced4  ',
    trackName: 'G',
    artistName: 'H',
  ),
  HistoryLookupRequest(
    spotifyId: 'example:release:5',
    isrc: '  USEX12600005 ',
    trackName: 'I',
    artistName: 'J',
  ),
  HistoryLookupRequest(
    spotifyId: 'none6',
    isrc: 'usex12600006',
    trackName: '  Mixed CASE Song ',
    artistName: ' Some ARTIST ',
  ),
  HistoryLookupRequest(
    spotifyId: 'none7',
    trackName: '',
    artistName: 'Stored artist',
  ),
  HistoryLookupRequest(
    spotifyId: 'none8',
    trackName: 'İstanbul',
    artistName: 'Ünlü',
  ),
  HistoryLookupRequest(
    spotifyId: 'none9',
    trackName: 'Nowhere',
    artistName: 'Nobody',
  ),
  HistoryLookupRequest(
    spotifyId: 'spotify:track:compact1',
    trackName: 'A',
    artistName: 'B',
  ),
];

final _trickyItems = [
  _item(1, spotifyId: 'compact1'),
  _item(2, spotifyId: 'spotify:track:prefixed2'),
  _item(3, spotifyId: 'url3'),
  _item(4, spotifyId: 'spaced4'),
  _item(5, isrc: 'USEX12600005'),
  // ISRCs match case-sensitively in memory, so only the title matches here.
  _item(
    6,
    isrc: 'USEX12600006',
    trackName: 'mixed case song',
    artistName: 'some artist',
  ),
  _item(7, trackName: '', artistName: 'Stored artist'),
  _item(8, trackName: 'İSTANBUL', artistName: 'ÜNLÜ'),
];

void main() {
  test('precomputed lookup keys equal each track lookupKey', () {
    final expected = [for (final track in _tricky) track.lookupKey];
    const plain = HistoryBatchLookupRequest(_tricky);
    final snapshot = HistoryBatchLookupRequest.snapshot(_tricky);
    expect(plain.lookupKeys, expected);
    expect(snapshot.lookupKeys, expected);
    expect(identical(snapshot.lookupKeys, snapshot.lookupKeys), isTrue);
    expect(() => snapshot.lookupKeys.clear(), throwsUnsupportedError);

    final tracks = [
      for (final lookup in _tricky)
        Track(
          id: lookup.spotifyId,
          name: lookup.trackName,
          artistName: lookup.artistName,
          albumName: 'Album',
          isrc: lookup.isrc,
          duration: 1,
        ),
    ];
    final page = TrackHistorySnapshot()..update(tracks);
    expect(page.lookupKeys, expected);
    expect(identical(page.lookupKeys, page.request.lookupKeys), isTrue);
  });

  test('visible membership matches the per-track reference', () {
    final container = ProviderContainer(
      overrides: [
        downloadHistoryBatchExistsProvider.overrideWith(
          (ref, request) => <String>{},
        ),
      ],
    );
    addTearDown(container.dispose);
    final request = HistoryBatchLookupRequest.snapshot(_tricky);
    final states = [
      DownloadHistoryState(),
      DownloadHistoryState(items: _trickyItems.sublist(0, 4)),
      DownloadHistoryState(items: _trickyItems),
      DownloadHistoryState(
        items: _trickyItems.sublist(4),
      ).copyWithPrependedLookup(_trickyItems.first, items: [], totalCount: 5),
    ];
    for (final state in states) {
      final expected = _referenceKeys(state, _tricky, const {});
      expect(
        mergeVisibleHistoryLookupKeys(
          state: state,
          request: request,
          persistedKeys: const {},
        ),
        expected,
      );
    }
    // An empty title never matches by title; the last lookup repeats the first.
    expect(_referenceKeys(states[2], _tricky, const {}), {
      for (final index in [0, 1, 2, 3, 4, 5, 7]) _tricky[index].lookupKey,
    });

    final history = _History();
    final scoped = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(() => history),
        downloadHistoryBatchExistsProvider(
          request,
        ).overrideWith((ref) => {_tricky.last.lookupKey, 'persisted-only'}),
      ],
    );
    addTearDown(scoped.dispose);
    final provider = downloadHistoryVisibleBatchExistsProvider(request);
    final subscription = scoped.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    for (final state in states) {
      history.publish((_) => state);
      expect(
        scoped.read(provider),
        _referenceKeys(state, _tricky, {
          _tricky.last.lookupKey,
          'persisted-only',
        }),
      );
    }
  });

  test('random lookups match the per-track reference', () {
    final random = Random(7);
    T pick<T>(List<T> values) => values[random.nextInt(values.length)];
    const ids = [
      'a1',
      ' a1 ',
      'spotify:track:a1',
      'https://open.spotify.com/track/a1',
      'example:album:a1',
      'B2',
      'b2',
      'spotify:track:b2',
      '',
    ];
    const isrcs = [null, '', 'USX1', ' USX1 ', 'usx1', 'USX2'];
    const titles = ['Song', ' song ', 'SONG', '', 'Other', 'İ'];
    const artists = ['Artist', 'artist ', '', 'Else'];
    var matchedInMemory = 0;
    for (var round = 0; round < 300; round++) {
      final lookups = [
        for (var i = 0; i < 12; i++)
          HistoryLookupRequest(
            spotifyId: pick(ids),
            isrc: pick(isrcs),
            trackName: pick(titles),
            artistName: pick(artists),
          ),
      ];
      final itemCount = random.nextInt(6);
      final items = [
        for (var i = 0; i < itemCount; i++)
          _item(
            i,
            spotifyId: pick([null, 'a1', 'b2', 'spotify:track:B2', '']),
            isrc: pick(isrcs),
            trackName: pick(titles),
            artistName: pick(artists),
          ),
      ];
      final state = DownloadHistoryState(items: items);
      final persisted = {if (random.nextBool()) lookups.first.lookupKey};
      final expected = _referenceKeys(state, lookups, persisted);
      if (expected.difference(persisted).isNotEmpty) matchedInMemory++;
      expect(
        mergeVisibleHistoryLookupKeys(
          state: state,
          request: HistoryBatchLookupRequest.snapshot(lookups),
          persistedKeys: persisted,
        ),
        expected,
        reason: 'round $round',
      );
    }
    expect(matchedInMemory, greaterThan(150));
  });

  test('history changes never re-derive the page lookup keys', () async {
    final lookups = [
      for (var i = 0; i < 200; i++)
        _CountingLookup(
          spotifyId: 'page-$i',
          trackName: 'Page song $i',
          artistName: 'Example artist',
        ),
    ];
    final request = HistoryBatchLookupRequest.snapshot(lookups);
    final matchKey = lookups[7].lookupKey;
    final history = _History();
    var queries = 0;
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(() => history),
        downloadHistoryBatchExistsProvider(request).overrideWith((ref) {
          ref.watch(
            downloadHistoryProvider.select((s) => s.loadedIndexVersion),
          );
          queries++;
          // A stable result, so a revision bump changes no merge input.
          return const <String>{};
        }),
      ],
    );
    addTearDown(container.dispose);
    final provider = downloadHistoryVisibleBatchExistsProvider(request);
    final notifications = <Set<String>>[];
    final subscription = container.listen(
      provider,
      (_, next) => notifications.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    _CountingLookup.reads = 0;

    for (var i = 0; i < 10; i++) {
      final unrelated = _item(100 + i, spotifyId: 'elsewhere-$i');
      history.publish(
        (s) => s.copyWithPrependedLookup(
          unrelated,
          items: [unrelated, ...s.items],
          totalCount: s.totalCount + 1,
        ),
      );
      await container.pump();
      final merged = container.read(provider);
      history.publish((s) => s.copyWith(totalCount: s.totalCount + 1));
      await container.pump();
      expect(container.read(provider), same(merged));
      history.publish(
        (s) => s.copyWith(loadedIndexVersion: s.loadedIndexVersion + 1),
      );
      await container.pump();
      expect(container.read(provider), same(merged));
    }
    expect(queries, 11);
    expect(notifications, [<String>{}]);

    final match = _item(1, spotifyId: 'page-7');
    history.publish(
      (s) => s.copyWithPrependedLookup(
        match,
        items: [match, ...s.items],
        totalCount: s.totalCount + 1,
      ),
    );
    await container.pump();
    expect(container.read(provider), {matchKey});
    expect(notifications, [
      <String>{},
      {matchKey},
    ]);
    expect(_CountingLookup.reads, 0);
  });

  test('a change that keeps the lookup items skips the matching', () async {
    final request = HistoryBatchLookupRequest.snapshot([
      for (var i = 0; i < 200; i++)
        HistoryLookupRequest(
          spotifyId: 'page-$i',
          trackName: 'Page song $i',
          artistName: 'Example artist',
        ),
    ]);
    final lookup = List<DownloadHistoryItem>.unmodifiable([
      _item(1, spotifyId: 'page-3'),
    ]);
    final history = _History();
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(() => history),
        downloadHistoryBatchExistsProvider(
          request,
        ).overrideWith((ref) => const <String>{}),
      ],
    );
    addTearDown(container.dispose);
    final provider = downloadHistoryVisibleBatchExistsProvider(request);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    history.publish((_) => _CountingState(lookup, totalCount: 1));
    await container.pump();
    final merged = container.read(provider);
    expect(merged, {request.lookupKeys[3]});
    expect(_CountingState.indexReads, greaterThan(200));

    _CountingState.indexReads = 0;
    for (var count = 2; count < 12; count++) {
      history.publish((_) => _CountingState(lookup, totalCount: count));
      await container.pump();
      expect(container.read(provider), same(merged));
    }
    expect(_CountingState.indexReads, 0);
  });
}
