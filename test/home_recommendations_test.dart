import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_recommendations_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/home_recommendations.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/suggestion_outcomes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

Future<Database> _outcomesDatabase() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('home-outcomes-');
  addTearDown(() => directory.delete(recursive: true));
  final db = await SuggestionOutcomes.openWithFactory(
    databaseFactoryFfi,
    '${directory.path}/outcomes.db',
  );
  addTearDown(db.close);
  return db;
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

  // [fit] stands for what learning knows of the songs, nothing unless a
  // test says so; [learns] reads it from the real provider instead.
  ProviderContainer container({
    AppSettings settings = const AppSettings(),
    List<Track>? seeds,
    FutureOr<HomeRecommendationFit?> Function(Ref ref)? fit,
    bool learns = false,
    bool byFit = true,
    List<Override> overrides = const [],
  }) {
    final result = ProviderContainer(
      // A failed read is not asked again by itself in a test.
      retry: (_, _) => null,
      overrides: [
        ...overrides,
        if (!learns)
          homeRecommendationFitProvider.overrideWith(fit ?? (ref) => null),
        homeRecommendationOrdersByFitProvider.overrideWith((ref) => byFit),
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

  test('a reload that finds the same songs keeps the shelf\'s list', () async {
    final read = container();
    final first = await read.read(homeRecommendationsProvider.future);
    expect(first, isNotEmpty);
    // A finished download reads the candidates again.
    read.invalidate(homeRecommendationCandidatesProvider);
    final again = await read.read(homeRecommendationsProvider.future);
    expect(again, same(first));
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

  test('a fit orders the shelf, while the day keeps the extension\'s '
      'order', () async {
    answer = [for (var i = 0; i < 15; i++) _result('Song $i')];
    final db = await _outcomesDatabase();
    final outcomes = SuggestionOutcomes(open: () async => db)..enabled = true;
    final runtime = MusicPlayerRuntime(
      dependencies: PlaybackDependencies(
        createSuggestionOutcomes: () => outcomes,
      ),
    );
    addTearDown(runtime.dispose);
    final read = container(
      fit: (ref) =>
          (Track track) => double.parse(track.name.split(' ').last),
      overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
    );
    final shown = await read.read(homeRecommendationsProvider.future);
    final byFit = [for (var i = 14; i >= 3; i--) 'Song $i'];
    expect([for (final track in shown) track.name], byFit);
    // The outcome log learns where the extension put a song, and its fit.
    outcomes.recommendationShown(artist: 'Someone', title: 'Song 14', rank: 0);
    expect(
      [
        for (final row in await outcomes.readImpressions())
          (row.rank, row.sourceRank, row.fit),
      ],
      [(0, 14, 14.0)],
    );
    // The order is stored: the next launch shows it before any fit is read.
    final again = container(fit: (ref) => Completer<Never>().future);
    expect([
      for (final track in await again.read(homeRecommendationsProvider.future))
        track.name,
    ], byFit);
    final extension = [for (var i = 0; i < 15; i++) 'Song $i'];
    expect([
      for (final track in await read.read(
        homeRecommendationCandidatesProvider.future,
      ))
        track.name,
    ], extension);
    final prefs = await SharedPreferences.getInstance();
    expect([
      for (final track in HomeRecommendationCache.decode(
        prefs.getString(_cacheKey),
      )!.tracks)
        track.name,
    ], extension);
  });

  test('new songs wait for their fit and show once, in its order', () async {
    answer = [_result('Low'), _result('High')];
    final fit = Completer<HomeRecommendationFit?>();
    final read = container(fit: (ref) => fit.future);
    final shelf = read.listen(homeRecommendationsProvider, (_, _) {});
    addTearDown(shelf.close);
    await pumpEventQueue();
    expect(shelf.read().hasValue, isFalse);
    fit.complete((Track track) => track.name == 'High' ? 1.0 : 0.0);
    expect(
      [
        for (final track in await read.read(homeRecommendationsProvider.future))
          track.name,
      ],
      ['High', 'Low'],
    );
    expect(requests, hasLength(1));
  });

  test('a control day, or a fit that tells nothing, keeps the extension\'s '
      'order and the fits', () async {
    answer = [_result('Low'), _result('High')];
    final read = container(
      byFit: false,
      fit: (ref) =>
          (Track track) => track.name == 'High' ? 1.0 : 0.0,
    );
    expect(
      [
        for (final track in await read.read(homeRecommendationsProvider.future))
          track.name,
      ],
      ['Low', 'High'],
    );
    final prefs = await SharedPreferences.getInstance();
    final order = HomeRecommendationOrder.decode(
      prefs.getString(homeRecommendationOrderKey),
    )!;
    expect(order.fits.values, unorderedEquals([0.0, 1.0]));
  });

  test('songs without a fit keep the extension\'s order without waiting '
      'again', () async {
    answer = [_result('One'), _result('Two')];
    expect(
      [
        for (final track in await container().read(
          homeRecommendationsProvider.future,
        ))
          track.name,
      ],
      ['One', 'Two'],
    );
    final again = container(fit: (ref) => Completer<Never>().future);
    expect(
      [
        for (final track in await again.read(
          homeRecommendationsProvider.future,
        ))
          track.name,
      ],
      ['One', 'Two'],
    );
  });

  test('the fit is read once startup has settled, and with learning off the '
      'extension\'s order shows at once', () async {
    answer = [for (var i = 0; i < 15; i++) _result('Song $i')];
    final unsettled = container(learns: true);
    final fit = unsettled.listen(homeRecommendationFitProvider, (_, _) {});
    addTearDown(fit.close);
    await pumpEventQueue();
    expect(fit.read().isLoading, isTrue);
    final off = container(
      settings: const AppSettings(autoplayPersonalization: false),
      learns: true,
    );
    expect(await off.read(homeRecommendationFitProvider.future), isNull);
    expect(
      [
        for (final track in await off.read(homeRecommendationsProvider.future))
          track.name,
      ],
      [for (var i = 0; i < homeRecommendationCount; i++) 'Song $i'],
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(homeRecommendationOrderKey), isNull);
  });

  test('once learning knows the listener, songs of their artists have a '
      'fit and others none', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('home-fit-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await AutoplayTaste.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/taste.db',
    );
    addTearDown(db.close);
    final taste = AutoplayTaste(
      open: () async => db,
      train: (plays) async => trainAutoplayTaste(plays),
    );
    var elapsed = Duration.zero;
    final learning = AutoplayPersonalization(
      load: () async => null,
      save: (_) async {},
      elapsed: () => elapsed,
      now: () => DateTime(2026, 11, 23, 20),
    );
    final runtime = MusicPlayerRuntime(
      dependencies: PlaybackDependencies(
        createPersonalization: () => learning,
        createTaste: () => taste,
      ),
    );
    addTearDown(runtime.dispose);
    learning.setEnabled(true);
    await learning.ensureLoaded();
    for (var i = 0; i < 60; i++) {
      final track = AutoplayLearningTrack(
        source: '/played/$i.flac',
        title: 'Track ${i % 5}',
        artist: i.isEven ? 'Someone' : 'Another',
        duration: const Duration(seconds: 100),
      );
      runtime.personalization.begin(track);
      runtime.personalization.updatePlayback(
        source: track.source,
        playing: true,
      );
      elapsed += const Duration(seconds: 100);
    }
    runtime.personalization.finish();
    await pumpEventQueue();
    await taste.train();

    final read = container(
      learns: true,
      overrides: [
        libraryMixesStartupProvider.overrideWithBuild((ref, notifier) => true),
        musicPlayerRuntimeProvider.overrideWithValue(runtime),
      ],
    );
    final fit = (await read.read(homeRecommendationFitProvider.future))!;
    expect(fit(_track('New', 'Someone')), isNotNull);
    expect(fit(_track('New', 'Guest feat. Another')), isNotNull);
    expect(fit(_track('New', 'Nobody')), isNull);
  });

  group('genre recommendations', () {
    const genreCacheKey = 'home_genre_recommendations_v1';

    LibraryMixView mix(String genre, List<String> songs) => LibraryMixView(
      mix: LibraryMix(
        kind: LibraryMixKind.genre,
        key: genre,
        label: genre,
        artists: const ['Artist'],
        songIds: songs,
      ),
      items: [
        for (final song in songs)
          UnifiedLibraryItem(
            id: song,
            trackName: song,
            artistName: 'Artist',
            albumName: 'Album',
            filePath: '/music/$song.flac',
            addedAt: DateTime(2026),
            source: LibraryItemSource.local,
          ),
      ],
    );

    ProviderContainer genres() => container(
      overrides: [
        libraryMixesProvider.overrideWith(
          (ref) async => [
            mix('rock', ['Rock one', 'Rock two']),
            mix('jazz', ['Jazz one']),
          ],
        ),
      ],
    );

    Future<List<String>> read(ProviderContainer from, String genre) async {
      final provider = homeGenreRecommendationsProvider(genre);
      from.listen(provider, (_, _) {});
      return [for (final track in await from.read(provider.future)) track.name];
    }

    test('start from the genre\'s songs and are asked once a day', () async {
      expect(await read(genres(), 'rock'), ['New one', 'New two']);
      expect(requests, hasLength(1));
      expect([
        for (final seed in requests.single) (seed as Map)['name'],
      ], containsAll(['Rock one', 'Rock two']));

      answer = [_result('Another')];
      expect(await read(genres(), 'rock'), ['New one', 'New two']);
      expect(requests, hasLength(1));
    });

    test('genres asked together are all kept', () async {
      final from = genres();
      await Future.wait([read(from, 'rock'), read(from, 'jazz')]);
      expect(requests, hasLength(2));
      final prefs = await SharedPreferences.getInstance();
      final stored = HomeGenreRecommendationCache.decode(
        prefs.getString(genreCacheKey),
      )!;
      expect(stored.genres.keys, unorderedEquals(['rock', 'jazz']));
      expect(stored.day, listeningDay(DateTime.now()));
    });

    test('a failed request falls back on the last day of that genre', () async {
      SharedPreferences.setMockInitialValues({
        genreCacheKey: HomeGenreRecommendationCache(
          day: '2020-01-01',
          extensionId: _extension.id,
          genres: {
            'rock': [_track('Old'), _track('Owned')],
          },
        ).encode(),
      });
      fail = true;
      expect(await read(genres(), 'rock'), ['Old']);
      expect(await read(genres(), 'jazz'), isEmpty);
    });

    test('an empty answer is asked again on the next read', () async {
      answer = [];
      expect(await read(genres(), 'rock'), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(genreCacheKey), isFalse);

      answer = [_result('Later one')];
      expect(await read(genres(), 'rock'), ['Later one']);
      expect(requests, hasLength(2));
    });

    test(
      'a genre without a mix, or with the switch off, asks nothing',
      () async {
        expect(await read(genres(), 'pop'), isEmpty);
        final off = container(
          settings: const AppSettings(homeRecommendations: false),
          overrides: [
            libraryMixesProvider.overrideWith(
              (ref) async => [
                mix('rock', ['Rock one']),
              ],
            ),
          ],
        );
        expect(await read(off, 'rock'), isEmpty);
        expect(requests, isEmpty);
      },
    );

    test('a genre\'s pool keeps each song once, with an artist', () {
      final pool = homeGenreRecommendationPool([
        _track('One'),
        _track('One'),
        _track('No artist', ' '),
        for (var i = 0; i < 40; i++) _track('Song $i'),
      ]);
      expect(pool, hasLength(homeGenreRecommendationPoolSize));
      expect([for (final track in pool.take(2)) track.name], ['One', 'Song 0']);
    });

    test('a song shows on its first shelf only, and empty shelves go', () {
      final apart = homeRecommendationShelvesApart(
        [
          ('rock', [_track('Daily'), _track('Rock'), _track('Both')]),
          ('jazz', [_track('Both')]),
          ('pop', [_track('Pop'), _track('Rock')]),
        ],
        shown: [_track('Daily')],
      );
      expect(
        {
          for (final (genre, tracks) in apart)
            genre: [for (final track in tracks) track.name],
        },
        {
          'rock': ['Rock', 'Both'],
          'pop': ['Pop'],
        },
      );
      expect([for (final (genre, _) in apart) genre], ['rock', 'pop']);
    });

    test('a stored day reads back and another day starts over', () {
      final stored = HomeGenreRecommendationCache(
        day: '2026-11-23',
        extensionId: _extension.id,
        genres: {
          'rock': [_track('Rock')],
        },
      );
      final read = HomeGenreRecommendationCache.decode(stored.encode())!;
      expect(read.genres['rock']!.single.name, 'Rock');
      final sameDay = read.put(
        day: '2026-11-23',
        extensionId: _extension.id,
        genre: 'jazz',
        tracks: [_track('Jazz')],
      );
      expect(sameDay.genres.keys, unorderedEquals(['rock', 'jazz']));
      final nextDay = sameDay.put(
        day: '2026-11-24',
        extensionId: _extension.id,
        genre: 'pop',
        tracks: [_track('Pop')],
      );
      expect(nextDay.genres.keys, ['pop']);
      expect(HomeGenreRecommendationCache.decode('{"day": 1}'), isNull);
      expect(HomeGenreRecommendationCache.decode('nonsense'), isNull);
    });
  });
}
