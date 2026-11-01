import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_queue_provider.dart';

DownloadHistoryItem _historyItem({
  required String id,
  required String filePath,
  required DateTime downloadedAt,
  String albumName = 'Album',
}) {
  return DownloadHistoryItem(
    id: id,
    trackName: 'Same Song',
    artistName: 'Same Artist',
    albumName: albumName,
    filePath: filePath,
    service: 'test',
    downloadedAt: downloadedAt,
    spotifyId: 'source-track-same',
    isrc: 'SAMEISRC',
  );
}

class _CountingHistoryItem extends Fake implements DownloadHistoryItem {
  _CountingHistoryItem(this.item);

  final DownloadHistoryItem item;
  int keyReads = 0;

  @override
  String? get spotifyId {
    keyReads++;
    return item.spotifyId;
  }

  @override
  String? get isrc {
    keyReads++;
    return item.isrc;
  }

  @override
  String get trackName {
    keyReads++;
    return item.trackName;
  }

  @override
  String get artistName {
    keyReads++;
    return item.artistName;
  }
}

void main() {
  group('download history identity', () {
    test('serializes download timestamps with an explicit UTC offset', () {
      final item = _historyItem(
        id: 'utc',
        filePath: '/music/Album/Same Song.flac',
        downloadedAt: DateTime(2026, 7, 22, 12, 30),
      );

      expect(item.toJson()['downloadedAt'], endsWith('Z'));
    });

    test('same track metadata does not merge files from different albums', () {
      final first = _historyItem(
        id: 'first',
        filePath: '/music/First Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 22),
        albumName: 'First Album',
      );
      final second = _historyItem(
        id: 'second',
        filePath: '/music/Second Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
        albumName: 'Second Album',
      );

      expect(historyItemsReferToSameStoredFile(first, second), isFalse);
    });

    test('equivalent paths still update one stored file record', () {
      final original = _historyItem(
        id: 'original',
        filePath: '/music/Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 22),
      );
      final converted = _historyItem(
        id: 'converted',
        filePath: '/music/Album/Same Song.opus',
        downloadedAt: DateTime.utc(2026, 7, 23),
      );

      expect(historyItemsReferToSameStoredFile(original, converted), isTrue);
    });

    test('duplicate track identities keep the first lookup item', () {
      final newest = _historyItem(
        id: 'newest',
        filePath: '/music/New Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
        albumName: 'New Album',
      );
      final older = _historyItem(
        id: 'older',
        filePath: '/music/Old Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 22),
        albumName: 'Old Album',
      );

      final state = DownloadHistoryState(
        items: [newest, older],
        lookupItems: [newest, older],
        totalCount: 2,
      );

      for (final current in [state, state.copyWith(loadedIndexVersion: 1)]) {
        expect(current.getBySpotifyId('source-track-same'), same(newest));
        expect(current.getByIsrc('SAMEISRC'), same(newest));
        expect(
          current.findByTrackAndArtist('  SAME SONG ', ' same artist  '),
          same(newest),
        );
      }
      final reordered = state.copyWith(lookupItems: [older, newest]);
      expect(reordered.getBySpotifyId('source-track-same'), same(older));
      expect(reordered.getByIsrc('SAMEISRC'), same(older));
      expect(
        reordered.findByTrackAndArtist('Same Song', 'Same Artist'),
        same(older),
      );
      expect(state.items, hasLength(2));
    });

    test('recent in-memory completion is visible during batch reload', () {
      final completed = _historyItem(
        id: 'completed',
        filePath: '/music/Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 8, 27),
      );
      final state = DownloadHistoryState(
        items: [completed],
        lookupItems: [completed],
        totalCount: 1,
      );
      const completedLookup = HistoryLookupRequest(
        spotifyId: 'same',
        isrc: 'SAME-ISRC',
        trackName: 'Same Song',
        artistName: 'Same Artist',
      );
      const olderLookup = HistoryLookupRequest(
        spotifyId: 'older',
        trackName: 'Older Song',
        artistName: 'Same Artist',
      );

      final visible = mergeVisibleHistoryLookupKeys(
        state: state,
        request: const HistoryBatchLookupRequest([
          completedLookup,
          olderLookup,
        ]),
        persistedKeys: {olderLookup.lookupKey},
      );

      expect(visible, {completedLookup.lookupKey, olderLookup.lookupKey});
    });

    test('actual audio quality survives history serialization', () {
      final item =
          _historyItem(
            id: 'quality',
            filePath: '/music/Album/Hi-Res Song.flac',
            downloadedAt: DateTime.utc(2026, 7, 23),
          ).copyWith(
            quality: '24-bit/96kHz',
            bitDepth: 24,
            sampleRate: 96000,
            format: 'flac',
          );

      final restored = DownloadHistoryItem.fromJson(item.toJson());

      expect(restored.quality, '24-bit/96kHz');
      expect(restored.bitDepth, 24);
      expect(restored.sampleRate, 96000);
      expect(restored.format, 'flac');
    });

    test('explicit metadata survives history serialization', () {
      final item = _historyItem(
        id: 'explicit',
        filePath: '/music/Album/Explicit Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
      ).copyWith(explicit: true);

      expect(DownloadHistoryItem.fromJson(item.toJson()).explicit, isTrue);
    });

    test('placeholder refresh cannot erase an existing measured quality', () {
      expect(
        resolvePersistedHistoryQuality(
          incoming: 'HI_RES_LOSSLESS',
          existing: '24-bit/96kHz',
        ),
        '24-bit/96kHz',
      );
      expect(
        resolvePersistedHistoryQuality(
          incoming: '24-bit/192kHz',
          existing: '24-bit/96kHz',
        ),
        '24-bit/192kHz',
      );
    });
  });

  group('download history state copies', () {
    test('unchanged lookup snapshots do not reread index keys', () {
      final item = _CountingHistoryItem(
        _historyItem(
          id: 'indexed',
          filePath: '/music/Same Song.flac',
          downloadedAt: DateTime.utc(2026, 7, 23),
        ),
      );
      final state = DownloadHistoryState(items: [item], totalCount: 1);
      final initialReads = item.keyReads;
      expect(initialReads, greaterThan(0));

      final revisionOnly = state.copyWith(loadedIndexVersion: 2);
      final countOnly = revisionOnly.copyWith(totalCount: 10);
      final visibleItems = <DownloadHistoryItem>[];
      final itemsOnly = countOnly.copyWith(items: visibleItems);
      final sameLookup = itemsOnly.copyWith(lookupItems: state.lookupItems);

      for (final current in [revisionOnly, countOnly, itemsOnly, sameLookup]) {
        expect(current.lookupItems, same(state.lookupItems));
        expect(current.isDownloaded('source-track-same'), isTrue);
        expect(current.getBySpotifyId('source-track-same'), same(item));
        expect(current.getByIsrc('SAMEISRC'), same(item));
        expect(
          current.findByTrackAndArtist(' Same Song ', 'SAME ARTIST'),
          same(item),
        );
      }
      expect(item.keyReads, initialReads);
      expect(revisionOnly.totalCount, 1);
      expect(revisionOnly.items, same(state.items));
      expect(countOnly.loadedIndexVersion, 2);
      expect(countOnly.items, same(state.items));
      expect(itemsOnly.totalCount, 10);
      expect(itemsOnly.loadedIndexVersion, 2);
      expect(itemsOnly.items, same(visibleItems));
      expect(state.totalCount, 1);
      expect(state.loadedIndexVersion, 0);

      visibleItems.add(item);
      expect(itemsOnly.items, [item]);
      expect(item.keyReads, initialReads);
    });

    test('constructor lookup snapshots survive mutable input changes', () {
      final original = _historyItem(
        id: 'original',
        filePath: '/music/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
      );
      final replacement = original.copyWith(
        spotifyId: 'replacement',
        isrc: 'REPLACEMENT',
        trackName: 'Replacement',
      );

      for (final explicitLookup in [false, true]) {
        final input = [original];
        final state = DownloadHistoryState(
          items: input,
          lookupItems: explicitLookup ? input : null,
        );
        input[0] = replacement;

        expect(state.items, same(input));
        expect(state.items, [replacement]);
        expect(state.lookupItems, [original]);
        expect(() => state.lookupItems.clear(), throwsUnsupportedError);
        final copied = state.copyWith(totalCount: 2);
        expect(copied.lookupItems, same(state.lookupItems));
        expect(copied.getBySpotifyId('source-track-same'), same(original));
        expect(copied.getBySpotifyId('replacement'), isNull);
        expect(copied.getByIsrc('SAMEISRC'), same(original));
        expect(copied.getByIsrc('REPLACEMENT'), isNull);
        expect(
          copied.findByTrackAndArtist('Same Song', 'Same Artist'),
          same(original),
        );
        expect(
          copied.findByTrackAndArtist('Replacement', 'Same Artist'),
          isNull,
        );
      }
    });

    test('replacement lookup rebuilds all indexes from a new snapshot', () {
      final original = _historyItem(
        id: 'original',
        filePath: '/music/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
      );
      final replacement = original.copyWith(
        spotifyId: 'replacement',
        isrc: 'REPLACEMENT',
        trackName: '  Replacement  ',
        artistName: ' NEW ARTIST ',
      );
      final state = DownloadHistoryState(items: [original], totalCount: 1);
      final input = [replacement];
      final copied = state.copyWith(
        lookupItems: input,
        totalCount: 2,
        loadedIndexVersion: 3,
      );
      input.clear();

      expect(copied.items, same(state.items));
      expect(copied.totalCount, 2);
      expect(copied.loadedIndexVersion, 3);
      expect(copied.lookupItems, [replacement]);
      expect(() => copied.lookupItems.clear(), throwsUnsupportedError);
      expect(copied.isDownloaded('source-track-same'), isFalse);
      expect(copied.isDownloaded('replacement'), isTrue);
      expect(copied.getBySpotifyId('replacement'), same(replacement));
      expect(copied.getByIsrc('SAMEISRC'), isNull);
      expect(copied.getByIsrc('REPLACEMENT'), same(replacement));
      expect(copied.findByTrackAndArtist('Same Song', 'Same Artist'), isNull);
      expect(
        copied.findByTrackAndArtist('replacement', 'new artist'),
        same(replacement),
      );
      expect(state.lookupItems, [original]);
      expect(state.getBySpotifyId('source-track-same'), same(original));
      expect(state.getByIsrc('SAMEISRC'), same(original));
      expect(
        state.findByTrackAndArtist('Same Song', 'Same Artist'),
        same(original),
      );

      final cleared = copied.copyWith(lookupItems: []);
      expect(cleared.items, same(state.items));
      expect(cleared.lookupItems, isEmpty);
      expect(cleared.isDownloaded('replacement'), isFalse);
      expect(cleared.getByIsrc('REPLACEMENT'), isNull);
      expect(cleared.findByTrackAndArtist('replacement', 'new artist'), isNull);
    });

    test('prepended lookup keeps existing keys without rereading them', () {
      final existing = _CountingHistoryItem(
        _historyItem(
          id: 'existing',
          filePath: '/music/Same Song.flac',
          downloadedAt: DateTime.utc(2026, 7, 22),
        ),
      );
      final state = DownloadHistoryState(items: [existing], totalCount: 1);
      final initialReads = existing.keyReads;
      final added = _historyItem(
        id: 'added',
        filePath: '/music/Other/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
      ).copyWith(isrc: 'OTHERISRC');

      final prepended = state.copyWithPrependedLookup(
        added,
        items: [added, ...state.items],
        totalCount: 2,
      );

      expect(existing.keyReads, initialReads);
      expect(prepended.lookupItems, [added, existing]);
      expect(() => prepended.lookupItems.clear(), throwsUnsupportedError);
      expect(prepended.items, [added, existing]);
      expect(prepended.totalCount, 2);
      expect(prepended.loadedIndexVersion, state.loadedIndexVersion);
      expect(prepended.getBySpotifyId('source-track-same'), same(added));
      expect(prepended.getByIsrc('OTHERISRC'), same(added));
      expect(prepended.getByIsrc('SAMEISRC'), same(existing));
      expect(
        prepended.findByTrackAndArtist('Same Song', 'Same Artist'),
        same(added),
      );
      expect(state.lookupItems, [existing]);
      expect(state.getBySpotifyId('source-track-same'), same(existing));
      expect(state.getByIsrc('OTHERISRC'), isNull);
    });

    test('incremental lookups match a full rebuild after mixed edits', () {
      final random = Random(20261023);
      const spotifyIds = [null, '', 'sp-a', 'sp-b', 'sp-c'];
      const isrcs = [null, '', 'ISRC-A', 'ISRC-B'];
      const tracks = ['', ' ', 'Song A', ' song a ', 'SONG B'];
      const artists = ['', 'Artist', ' ARTIST ', 'Other'];
      T pick<T>(List<T> values) => values[random.nextInt(values.length)];

      var state = DownloadHistoryState();
      var nextId = 0;
      for (var step = 0; step < 600; step++) {
        final lookup = state.lookupItems;
        final operation = lookup.isEmpty ? 0 : random.nextInt(4);
        if (operation <= 1) {
          final item = DownloadHistoryItem(
            id: 'item-${nextId++}',
            trackName: pick(tracks),
            artistName: pick(artists),
            albumName: 'Album',
            filePath: '/music/$nextId.flac',
            service: 'test',
            downloadedAt: DateTime.utc(2026, 7, 23),
            spotifyId: pick(spotifyIds),
            isrc: pick(isrcs),
          );
          state = state.copyWithPrependedLookup(
            item,
            items: [item, ...state.items],
            totalCount: state.totalCount + 1,
          );
        } else if (operation == 2) {
          final target = lookup[random.nextInt(lookup.length)];
          final updated = target.copyWith(
            spotifyId: pick(spotifyIds),
            isrc: pick(isrcs),
            trackName: pick(tracks),
          );
          state = state.copyWith(
            lookupItems: [
              updated,
              ...lookup.where((item) => item.id != target.id),
            ],
          );
        } else {
          final removedId = lookup[random.nextInt(lookup.length)].id;
          state = state.copyWith(
            lookupItems: [
              for (final item in lookup)
                if (item.id != removedId) item,
            ],
          );
        }

        final rebuilt = DownloadHistoryState(
          items: state.items,
          lookupItems: List.of(state.lookupItems),
        );
        expect(state.lookupItems, rebuilt.lookupItems);
        for (final id in spotifyIds.whereType<String>()) {
          expect(state.isDownloaded(id), rebuilt.isDownloaded(id));
          expect(state.getBySpotifyId(id), same(rebuilt.getBySpotifyId(id)));
        }
        for (final isrc in isrcs.whereType<String>()) {
          expect(state.getByIsrc(isrc), same(rebuilt.getByIsrc(isrc)));
        }
        for (final track in tracks) {
          for (final artist in artists) {
            expect(
              state.findByTrackAndArtist(track, artist),
              same(rebuilt.findByTrackAndArtist(track, artist)),
            );
          }
        }
      }
    });
  });

  group('startup orphan reconciliation', () {
    test('requires consecutive missing checks before confirmation', () {
      final firstMissing = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {'track'},
        previousSuspectIds: {},
      );
      expect(firstMissing.confirmedIds, isEmpty);
      expect(firstMissing.pendingIds, {'track'});

      final recovered = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {},
        previousSuspectIds: firstMissing.pendingIds,
      );
      expect(recovered.confirmedIds, isEmpty);
      expect(recovered.pendingIds, isEmpty);

      final missingAgain = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {'track'},
        previousSuspectIds: recovered.pendingIds,
      );
      expect(missingAgain.confirmedIds, isEmpty);
      expect(missingAgain.pendingIds, {'track'});

      final consecutiveMissing = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {'track'},
        previousSuspectIds: missingAgain.pendingIds,
      );
      expect(consecutiveMissing.confirmedIds, {'track'});
      expect(consecutiveMissing.pendingIds, isEmpty);
    });

    test('ignores unchecked stale suspects', () {
      final decision = reconcileStartupOrphanSuspects(
        checkedIds: {'checked'},
        missingIds: {'unchecked'},
        previousSuspectIds: {'unchecked'},
      );

      expect(decision.confirmedIds, isEmpty);
      expect(decision.pendingIds, isEmpty);
    });
  });

  group('download completion persistence', () {
    test('publishes completion only after history persistence', () async {
      final events = <String>[];

      await persistBeforePublishingDownloadCompletion(
        persist: () async {
          events.add('persist');
        },
        publish: () => events.add('publish'),
      );

      expect(events, ['persist', 'publish']);
    });

    test(
      'does not publish completion when history persistence fails',
      () async {
        var published = false;

        await expectLater(
          persistBeforePublishingDownloadCompletion(
            persist: () =>
                Future<void>.error(StateError('database unavailable')),
            publish: () => published = true,
          ),
          throwsStateError,
        );

        expect(published, isFalse);
      },
    );
  });
}
