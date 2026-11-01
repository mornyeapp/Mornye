import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/weekly_releases.dart';

CollectionArtistEntry _artist(String id) => CollectionArtistEntry(
  key: 'provider-a:$id',
  artistId: id,
  providerId: 'provider-a',
  name: id,
  addedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('weekly feed rejects incomplete/invalid dates and future releases', () {
    WeeklyRelease? parse(String date) => WeeklyRelease.fromMetadata(
      {'id': date, 'name': 'Release', 'release_date': date},
      providerId: 'provider-a',
      artist: 'Artist',
    );
    expect(parse('2026'), isNull);
    expect(parse('2026-10'), isNull);
    expect(parse('2026-02-31'), isNull);
    final feed = WeeklyReleaseFeed([
      parse('2026-09-26')!,
      parse('2026-10-02')!,
      parse('2026-09-25')!,
      parse('2026-10-03')!,
    ]);
    expect(feed.inPeriod(DateTime(2026, 10, 2), 7).length, 2);
  });

  test(
    'catalog is deduplicated, cached daily and retained on refresh failure',
    () async {
      var calls = 0;
      var fail = false;
      final service = WeeklyReleaseService(
        preferences: SharedPreferences.getInstance(),
        loadArtist: (artist) async {
          calls++;
          if (fail) throw StateError('provider unavailable');
          final album = {
            'id': 'release',
            'name': 'Release',
            'release_date': '2026-10-02',
          };
          return (
            providerId: 'provider-a',
            metadata: <String, dynamic>{
              'albums': [album],
              'releases': [album],
            },
          );
        },
      );
      final artists = [_artist('Artist')];
      final date = DateTime(2026, 10, 2);
      expect((await service.load(artists, now: date)).releases.length, 1);
      expect((await service.load(artists, now: date)).releases.length, 1);
      expect(calls, 1);
      fail = true;
      final offline = await service.load(artists, now: date, refresh: true);
      expect(offline.releases.length, 1);
      expect(offline.unavailableArtists, ['Artist']);
      expect(calls, 2);
    },
  );

  test('unsupported artist catalogs do not erase saved releases', () async {
    var unsupported = false;
    final service = WeeklyReleaseService(
      preferences: SharedPreferences.getInstance(),
      loadArtist: (_) async => (
        providerId: 'provider-a',
        metadata: <String, dynamic>{
          if (!unsupported)
            'albums': [
              {
                'id': 'release',
                'name': 'Release',
                'release_date': '2026-10-02',
              },
            ],
        },
      ),
    );
    await service.load([_artist('Artist')]);
    unsupported = true;
    final result = await service.load([_artist('Artist')], refresh: true);
    expect(result.releases.length, 1);
    expect(result.unavailableArtists, ['Artist']);
  });

  test('limits concurrent requests for a large favorites list', () async {
    var running = 0;
    var peak = 0;
    final service = WeeklyReleaseService(
      preferences: SharedPreferences.getInstance(),
      loadArtist: (_) async {
        running++;
        if (running > peak) peak = running;
        await Future<void>.delayed(Duration.zero);
        running--;
        return (
          providerId: 'provider-a',
          metadata: <String, dynamic>{'albums': <Object>[]},
        );
      },
    );
    await service.load([for (var i = 0; i < 10; i++) _artist('artist-$i')]);
    expect(peak, 2);
  });

  test(
    'abandoned feed stops starting requests and does not cache late results',
    () async {
      var cancelled = false;
      final started = Completer<void>();
      final complete = Completer<void>();
      var calls = 0;
      final preferences = await SharedPreferences.getInstance();
      final service = WeeklyReleaseService(
        preferences: Future.value(preferences),
        loadArtist: (_) async {
          if (++calls == 2) started.complete();
          await complete.future;
          return (
            providerId: 'provider-a',
            metadata: <String, dynamic>{'albums': <Object>[]},
          );
        },
      );
      final loading = service.load([
        for (var i = 0; i < 10; i++) _artist('artist-$i'),
      ], isCancelled: () => cancelled);
      await started.future;
      cancelled = true;
      complete.complete();
      await loading;
      expect(calls, 2);
      expect(preferences.getKeys(), isEmpty);
    },
  );
}
