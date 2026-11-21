import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_recommendations_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/home_recommendations.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

const _cacheKey = 'home_recommendations_v1';

const _extension = Extension(
  id: 'example.related',
  name: 'example.related',
  displayName: 'Example Music',
  version: '1.0.0',
  description: 'Related songs',
  enabled: true,
  status: 'loaded',
  capabilities: {'relatedTracks': true},
);

Track _track(String name, [String artist = 'Artist']) => Track(
  id: name,
  name: name,
  artistName: artist,
  albumName: 'Album',
  duration: 200,
);

Map<String, dynamic> _result(String name) => {
  'id': name,
  'name': name,
  'artists': 'Someone',
  'album_name': 'Album',
  'duration_ms': 200000,
  'provider_id': _extension.id,
};

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() =>
      const ExtensionState(extensions: [_extension], isInitialized: true);
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<List<dynamic>> requests;
  late List<Map<String, dynamic>> answer;
  late bool fail;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    answer = [_result('New one'), _result('New two'), _result('Owned')];
    fail = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getExtensionRelatedTracks') return null;
      if (fail) throw PlatformException(code: 'offline');
      requests.add(
        jsonDecode((call.arguments as Map)['seeds'] as String) as List,
      );
      return jsonEncode(answer);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  ProviderContainer container({
    AppSettings settings = const AppSettings(),
    List<Track>? seeds,
  }) {
    final result = ProviderContainer(
      // A failed read is not asked again by itself in a test.
      retry: (_, _) => null,
      overrides: [
        settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
        extensionProvider.overrideWith(_Extensions.new),
        downloadHistoryProvider.overrideWith(_History.new),
        homeRecommendationSeedsProvider.overrideWithValue(
          () async => seeds ?? [_track('Mine one', 'A'), _track('Mine two')],
        ),
        homeRecommendationFilterProvider.overrideWithValue(
          (tracks) async => [
            for (final track in tracks)
              if (track.name != 'Owned') track,
          ],
        ),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  test('the pool takes each kind in turn, each song once, artists only', () {
    final pool = homeRecommendationPool(
      mostPlayed: [_track('Played'), _track('Both')],
      added: [_track('Added'), _track('No artist', ' ')],
      loved: [_track('Both'), _track('Loved')],
    );
    expect(
      [for (final track in pool) track.name],
      ['Played', 'Added', 'Both', 'Loved'],
    );
  });

  test('each day starts from the next songs of the pool', () {
    expect(
      homeRecommendationRound('2026-11-23') -
          homeRecommendationRound('2026-11-22'),
      1,
    );
    expect(homeRecommendationRound('not a day'), 0);
  });

  test('a stored day reads back, and broken data reads as none', () {
    final stored = HomeRecommendationCache(
      day: '2026-11-22',
      extensionId: _extension.id,
      tracks: [_track('Song')],
    ).encode();
    final read = HomeRecommendationCache.decode(stored)!;
    expect(read.day, '2026-11-22');
    expect(read.extensionId, _extension.id);
    expect(read.tracks.single.name, 'Song');
    expect(HomeRecommendationCache.decode('{"day": 1}'), isNull);
    expect(HomeRecommendationCache.decode('nonsense'), isNull);
    expect(HomeRecommendationCache.decode(null), isNull);
  });

  test('a loader asked for more returns more', () async {
    final suggestions = await loadCollectionSuggestions(
      tracks: [_track('Mine')],
      source: const CollectionSuggestionSource(
        extensionId: 'example.related',
        related: true,
      ),
      round: 0,
      limit: 14,
      related: (_, _, limit) async => [
        for (var i = 0; i < limit; i++) _result('Song $i'),
      ],
      search: (_, _) async => const [],
    );
    expect(suggestions.tracks, hasLength(14));
  });

  test('songs outside the Library are asked once a day', () async {
    final first = await container().read(homeRecommendationsProvider.future);
    expect([for (final track in first) track.name], ['New one', 'New two']);
    expect(requests, hasLength(1));
    expect([
      for (final seed in requests.single) (seed as Map)['name'],
    ], containsAll(['Mine one', 'Mine two']));

    answer = [_result('Another')];
    final again = await container().read(homeRecommendationsProvider.future);
    expect([for (final track in again) track.name], ['New one', 'New two']);
    expect(requests, hasLength(1));
  });

  test('another day asks again', () async {
    SharedPreferences.setMockInitialValues({
      _cacheKey: HomeRecommendationCache(
        day: '2020-01-01',
        extensionId: _extension.id,
        tracks: [_track('Old')],
      ).encode(),
    });
    final tracks = await container().read(homeRecommendationsProvider.future);
    expect([for (final track in tracks) track.name], ['New one', 'New two']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      HomeRecommendationCache.decode(prefs.getString(_cacheKey))!.day,
      listeningDay(DateTime.now()),
    );
  });

  test('a failed request falls back on the last day', () async {
    SharedPreferences.setMockInitialValues({
      _cacheKey: HomeRecommendationCache(
        day: '2020-01-01',
        extensionId: _extension.id,
        tracks: [_track('Old'), _track('Owned')],
      ).encode(),
    });
    fail = true;
    final tracks = await container().read(homeRecommendationsProvider.future);
    expect([for (final track in tracks) track.name], ['Old']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      HomeRecommendationCache.decode(prefs.getString(_cacheKey))!.day,
      '2020-01-01',
    );
  });

  test('a failed first request stores nothing', () async {
    fail = true;
    await expectLater(
      container().read(homeRecommendationsProvider.future),
      throwsException,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(_cacheKey), isFalse);
  });

  test('songs from an extension that left are not shown', () async {
    SharedPreferences.setMockInitialValues({
      _cacheKey: HomeRecommendationCache(
        day: listeningDay(DateTime.now()),
        extensionId: 'example.removed',
        tracks: [_track('Old')],
      ).encode(),
    });
    final tracks = await container().read(homeRecommendationsProvider.future);
    expect([for (final track in tracks) track.name], ['New one', 'New two']);
  });

  test('nothing is asked with the switch off or without songs', () async {
    expect(
      await container(
        settings: const AppSettings(homeRecommendations: false),
      ).read(homeRecommendationsProvider.future),
      isEmpty,
    );
    expect(
      await container(seeds: []).read(homeRecommendationsProvider.future),
      isEmpty,
    );
    expect(requests, isEmpty);
  });

  test('the shelf holds at most its count', () async {
    answer = [for (var i = 0; i < 40; i++) _result('Song $i')];
    final tracks = await container().read(homeRecommendationsProvider.future);
    expect(tracks, hasLength(homeRecommendationCount));
    final prefs = await SharedPreferences.getInstance();
    expect(
      HomeRecommendationCache.decode(prefs.getString(_cacheKey))!.tracks,
      hasLength(homeRecommendationKept),
    );
  });
}
