import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/recognized_song.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/music_recognition_provider.dart';
import 'package:mornye/screens/music_recognition_screen.dart';
import 'package:mornye/services/music_recognition.dart';
import 'package:mornye/services/music_recognition_library.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

RecognizedSong song({
  String key = '1',
  String title = 'Song',
  String artist = 'Artist',
  String? isrc,
  int minute = 0,
}) => RecognizedSong(
  key: key,
  title: title,
  artist: artist,
  isrc: isrc,
  recognizedAt: DateTime.utc(2026, 1, 1, 0, minute),
);

class FakeMicrophone implements RecognitionMicrophone {
  FakeMicrophone({this.access = MicrophoneAccess.granted});

  MicrophoneAccess access;
  bool failStart = false;
  StreamController<Uint8List>? audio;
  int stops = 0;
  bool settingsOpened = false;

  /// Sends [seconds] of a loud 16 kHz mono signal.
  void feed(int seconds) {
    // A stopped recorder hears nothing more.
    if (audio!.isClosed) return;
    for (var i = 0; i < seconds; i++) {
      final chunk = Uint8List(recognitionBytesPerSecond);
      for (var byte = 1; byte < chunk.length; byte += 2) {
        chunk[byte] = byte % 4 == 1 ? 0x40 : 0xC0;
      }
      audio!.add(chunk);
    }
  }

  @override
  Future<MicrophoneAccess> requestAccess() async => access;

  @override
  Future<Stream<Uint8List>> start() async {
    if (failStart) throw StateError('busy');
    audio = StreamController<Uint8List>();
    return audio!.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    unawaited(audio?.close());
  }

  @override
  bool get canOpenSettings => true;

  @override
  Future<void> openSettings() async => settingsOpened = true;

  @override
  Future<void> dispose() async {}
}

class FakeRecognizer implements MusicRecognizer {
  final requests = <(int, String, Completer<RecognitionResponse>)>[];
  final cancelled = <String>[];

  void reply(RecognitionResponse response) {
    final pending = requests.lastWhere((request) => !request.$3.isCompleted);
    pending.$3.complete(response);
  }

  List<int> get sentSeconds => [
    for (final request in requests) request.$1 ~/ recognitionBytesPerSecond,
  ];

  @override
  Future<RecognitionResponse> recognize(
    Uint8List pcm, {
    required String requestId,
  }) {
    final reply = Completer<RecognitionResponse>();
    requests.add((pcm.length, requestId, reply));
    return reply.future;
  }

  @override
  Future<void> cancel(String requestId) async => cancelled.add(requestId);
}

class FakeLibrary implements RecognitionLibrary {
  FakeLibrary({this.isrcs = const {}, this.songs = const {}});

  final Map<String, String> isrcs;
  final Map<String, String> songs;
  final lookups = <String>[];

  RecognitionLibraryMatch _match(String path) =>
      RecognitionLibraryMatch(path: path, title: 't', artist: 'a');

  @override
  Future<RecognitionLibraryMatch?> byIsrc(String isrc) async {
    lookups.add('isrc:$isrc');
    final path = isrcs[isrc];
    return path == null ? null : _match(path);
  }

  @override
  Future<RecognitionLibraryMatch?> byTitleArtist(
    String title,
    String artist,
  ) async {
    lookups.add('$title|$artist');
    final path = songs['${title.toLowerCase()}|${artist.toLowerCase()}'];
    return path == null ? null : _match(path);
  }
}

const miss = RecognitionMissed(RecognitionMiss.noMatch);
const quiet = RecognitionMissed(RecognitionMiss.quiet);

void main() {
  group('native response', () {
    test('maps every status and never trusts a malformed song', () {
      final now = DateTime.utc(2026, 10, 26);
      final matched = parseRecognitionResponse({
        'status': 'match',
        'song': {
          'key': '644597356',
          'title': ' Kill Bill ',
          'artist': 'SZA',
          'album': 'SOS',
          'cover_url': 'https://example.com/hq.jpg',
          'release': '2022',
          'genre': 'R&B/Soul',
          'label': 'Top Dawg',
          'isrc': 'USRC12204584',
          'web_url': 'javascript:alert(1)',
          'lyrics': 'never kept',
        },
      }, now: now);
      final found = (matched as RecognitionMatched).song;
      expect(found.title, 'Kill Bill');
      expect(found.album, 'SOS');
      expect(found.coverUrl, 'https://example.com/hq.jpg');
      expect(found.webUrl, isNull);
      expect(found.recognizedAt, now);
      expect(found.toJson().containsKey('lyrics'), isFalse);

      RecognitionResponse parse(Object? status) =>
          parseRecognitionResponse({'status': status});
      expect(
        (parse('no_match') as RecognitionMissed).miss,
        RecognitionMiss.noMatch,
      );
      expect((parse('quiet') as RecognitionMissed).miss, RecognitionMiss.quiet);
      expect(
        (parse('too_short') as RecognitionMissed).miss,
        RecognitionMiss.tooShort,
      );
      for (final (status, failure) in [
        ('rate_limited', RecognitionFailure.rateLimited),
        ('network', RecognitionFailure.network),
        ('unavailable', RecognitionFailure.unavailable),
        ('something new', RecognitionFailure.unavailable),
        (null, RecognitionFailure.unavailable),
      ]) {
        expect((parse(status) as RecognitionFailed).failure, failure);
      }
      expect(
        parseRecognitionResponse({
          'status': 'match',
          'song': {'title': 'No artist'},
        }),
        isA<RecognitionFailed>(),
      );
    });

    test('history entries survive a round trip', () {
      final original = RecognizedSong(
        key: '7',
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        coverUrl: 'https://example.com/c.jpg',
        release: '1997',
        genre: 'Rock',
        label: 'Label',
        isrc: 'GBAYE9702004',
        webUrl: 'https://www.shazam.com/track/7',
        recognizedAt: DateTime.utc(2026, 10, 26, 12),
      );
      final copy = RecognizedSong.fromJson(original.toJson())!;
      expect(copy.toJson(), original.toJson());
      expect(RecognizedSong.fromJson({'title': 'x'}), isNull);
      expect(RecognizedSong.fromJson('nope'), isNull);
    });
  });

  group('history', () {
    test('keeps the newest first, one entry per song, up to the limit', () {
      var history = <RecognizedSong>[];
      history = addToRecognitionHistory(history, song(key: 'a'));
      history = addToRecognitionHistory(history, song(key: 'b'));
      history = addToRecognitionHistory(history, song(key: 'a', minute: 5));
      expect(history.map((entry) => entry.key), ['a', 'b']);
      expect(history.first.recognizedAt.minute, 5);

      // Without a track key, title, artist and ISRC identify the song.
      history = addToRecognitionHistory(
        history,
        song(key: '', title: 'Song', artist: 'Band', isrc: 'X1'),
      );
      history = addToRecognitionHistory(
        history,
        song(key: '', title: 'SONG', artist: 'band', isrc: 'x1'),
      );
      history = addToRecognitionHistory(
        history,
        song(key: '', title: 'Song', artist: 'Band', isrc: 'X2'),
      );
      expect(history, hasLength(4));

      for (var i = 0; i < 150; i++) {
        history = addToRecognitionHistory(history, song(key: '$i'));
      }
      expect(history, hasLength(recognitionHistoryLimit));
      expect(history.first.key, '149');
      expect(history.last.key, '50');
    });

    test('persists across notifiers and clears', () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      addTearDown(first.dispose);
      first.read(recognitionHistoryProvider);
      await first.read(recognitionHistoryProvider.notifier).add(song(key: 'a'));
      await first.read(recognitionHistoryProvider.notifier).add(song(key: 'b'));

      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.read(recognitionHistoryProvider);
      await pumpEventQueue();
      expect(
        second.read(recognitionHistoryProvider).map((entry) => entry.key),
        ['b', 'a'],
      );
      await second.read(recognitionHistoryProvider.notifier).clear();
      expect(second.read(recognitionHistoryProvider), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'music_recognition_history',
        ),
        isNull,
      );
    });
  });

  group('request details', () {
    test('time zone names come from the system or the offset', () {
      String zone({
        String? tz,
        String? link,
        Duration offset = Duration.zero,
      }) => deviceTimeZoneName(
        environment: {'TZ': ?tz},
        localtimeTarget: () => link,
        offset: offset,
      );
      expect(zone(tz: 'Europe/Paris'), 'Europe/Paris');
      expect(zone(tz: ':America/New_York'), 'America/New_York');
      expect(
        zone(tz: 'garbage', link: '/var/db/timezone/zoneinfo/Asia/Jakarta'),
        'Asia/Jakarta',
      );
      expect(zone(link: '/usr/share/zoneinfo/Etc/UTC'), 'Etc/UTC');
      expect(zone(offset: const Duration(hours: 7)), 'Etc/GMT-7');
      expect(zone(offset: const Duration(hours: -5)), 'Etc/GMT+5');
      expect(zone(offset: const Duration(hours: 5, minutes: 30)), 'UTC');
      expect(zone(), 'UTC');
    });

    test('level follows the PCM loudness', () {
      expect(pcmLevel(Uint8List(0)), 0);
      expect(pcmLevel(Uint8List(3200)), 0);
      final full = Uint8List(3200);
      for (var i = 0; i < full.length; i += 2) {
        full[i] = 0x00;
        full[i + 1] = 0x80; // -32768
      }
      expect(pcmLevel(full), closeTo(1, 1e-6));
      // A tenth of full scale is -20 dBFS.
      final quieter = ByteData(3200);
      for (var i = 0; i < 1600; i++) {
        quieter.setInt16(i * 2, i.isEven ? 3277 : -3277, Endian.little);
      }
      expect(pcmLevel(quieter.buffer.asUint8List()), closeTo(2 / 3, 0.01));
    });
  });

  group('library match', () {
    test('lookup pairs loosen the title and artist', () {
      expect(
        recognitionLookupPairs(
          'Lies (feat. Lana Del Rey)',
          'Zach Bryan & Lana Del Rey',
        ),
        [
          ('Lies (feat. Lana Del Rey)', 'Zach Bryan & Lana Del Rey'),
          ('Lies', 'Zach Bryan & Lana Del Rey'),
          ('Lies (feat. Lana Del Rey)', 'Zach Bryan'),
          ('Lies', 'Zach Bryan'),
        ],
      );
      expect(recognitionLookupPairs('Song', 'Solo'), [('Song', 'Solo')]);
      expect(recognitionLookupPairs('Track ft. Guest', 'Main x Other'), [
        ('Track ft. Guest', 'Main x Other'),
        ('Track', 'Main x Other'),
        ('Track ft. Guest', 'Main'),
        ('Track', 'Main'),
      ]);
    });

    test('ISRC wins, then title and artist, else nothing', () async {
      final byIsrc = FakeLibrary(
        isrcs: {'USRC1': '/isrc.flac'},
        songs: {'song|artist': '/title.flac'},
      );
      expect(
        (await findRecognizedSong(song(isrc: 'usrc1'), byIsrc))?.path,
        '/isrc.flac',
      );
      expect(byIsrc.lookups, ['isrc:USRC1']);

      final byTitle = FakeLibrary(songs: {'lies|zach bryan': '/lies.flac'});
      final found = await findRecognizedSong(
        song(
          title: 'Lies (feat. Lana Del Rey)',
          artist: 'Zach Bryan & Lana Del Rey',
          isrc: 'USX',
        ),
        byTitle,
      );
      expect(found?.path, '/lies.flac');
      expect(byTitle.lookups.first, 'isrc:USX');

      expect(await findRecognizedSong(song(), FakeLibrary()), isNull);
    });
  });

  group('listening', () {
    late FakeMicrophone mic;
    late FakeRecognizer recognizer;
    late ProviderContainer container;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mic = FakeMicrophone();
      recognizer = FakeRecognizer();
      container = ProviderContainer(
        overrides: [
          recognitionMicrophoneProvider.overrideWithValue(mic),
          musicRecognizerProvider.overrideWithValue(recognizer),
        ],
      );
      container.listen(musicRecognitionProvider, (_, _) {});
    });

    tearDown(() => container.dispose());

    MusicRecognitionState state() => container.read(musicRecognitionProvider);
    MusicRecognitionController controller() =>
        container.read(musicRecognitionProvider.notifier);

    // Widget tests run in fake time, where only the tester flushes work.
    Future<void> Function() flush = pumpEventQueue;

    Future<void> listen() async {
      await controller().start();
      await flush();
    }

    Future<void> feed(int seconds) async {
      mic.feed(seconds);
      await flush();
    }

    Future<void> reply(RecognitionResponse response) async {
      recognizer.reply(response);
      await flush();
    }

    test('asks after 4, 8 and 12 seconds and stops at the match', () async {
      await listen();
      expect(state().phase, RecognitionPhase.listening);
      await feed(3);
      expect(recognizer.requests, isEmpty);
      expect(state().progress, closeTo(0.25, 1e-9));
      expect(state().level, greaterThan(0.5));
      await feed(1);
      expect(recognizer.sentSeconds, [4]);
      await reply(miss);
      await feed(4);
      expect(recognizer.sentSeconds, [4, 8]);
      await reply(miss);
      await feed(4);
      // Twelve seconds is the whole listen: the microphone turns off.
      expect(recognizer.sentSeconds, [4, 8, 12]);
      expect(mic.stops, 1);
      expect(state().phase, RecognitionPhase.processing);
      await reply(RecognitionMatched(song(key: 'found')));
      expect(state().phase, RecognitionPhase.result);
      expect(state().song?.key, 'found');
      await pumpEventQueue();
      expect(container.read(recognitionHistoryProvider).single.key, 'found');
    });

    test('an early match turns the microphone off at once', () async {
      await listen();
      await feed(4);
      await reply(RecognitionMatched(song()));
      expect(state().phase, RecognitionPhase.result);
      expect(mic.stops, 1);
      await feed(4);
      expect(recognizer.requests, hasLength(1));
    });

    test('audio heard during a request goes into the next one', () async {
      await listen();
      await feed(4);
      await feed(5);
      expect(recognizer.sentSeconds, [4]);
      await reply(miss);
      expect(recognizer.sentSeconds, [4, 9]);
    });

    test('no match after the whole listen', () async {
      await listen();
      for (var i = 0; i < 3; i++) {
        await feed(4);
        await reply(miss);
      }
      expect(state().phase, RecognitionPhase.noMatch);
      expect(mic.stops, 1);
    });

    test('a quiet room is not enough audio', () async {
      await listen();
      for (var i = 0; i < 3; i++) {
        await feed(4);
        await reply(quiet);
      }
      expect(state().phase, RecognitionPhase.failed);
      expect(state().failure, RecognitionFailure.notEnoughAudio);
    });

    test('a failed request ends with its kind', () async {
      await listen();
      await feed(4);
      await reply(const RecognitionFailed(RecognitionFailure.rateLimited));
      expect(state().phase, RecognitionPhase.failed);
      expect(state().failure, RecognitionFailure.rateLimited);
      expect(mic.stops, 1);
    });

    test('cancel stops the microphone and the request', () async {
      await listen();
      await feed(5);
      expect(recognizer.requests, hasLength(1));
      await controller().cancel();
      expect(state().phase, RecognitionPhase.idle);
      expect(mic.stops, 1);
      expect(recognizer.cancelled, [recognizer.requests.single.$2]);
      // A late answer changes nothing.
      await reply(RecognitionMatched(song()));
      expect(state().phase, RecognitionPhase.idle);
      expect(container.read(recognitionHistoryProvider), isEmpty);
    });

    test('closing the screen releases the microphone', () async {
      await listen();
      await feed(2);
      container.dispose();
      await pumpEventQueue();
      expect(mic.stops, 1);
    });

    test('denied access offers settings only when blocked', () async {
      mic.access = MicrophoneAccess.denied;
      await listen();
      expect(state().phase, RecognitionPhase.permissionDenied);
      expect(state().canOpenSettings, isFalse);
      expect(mic.audio, isNull);

      mic.access = MicrophoneAccess.blocked;
      await listen();
      expect(state().canOpenSettings, isTrue);
      await controller().openSettings();
      expect(mic.settingsOpened, isTrue);
    });

    test('a microphone that does not start is reported', () async {
      mic.failStart = true;
      await listen();
      expect(state().phase, RecognitionPhase.failed);
      expect(state().failure, RecognitionFailure.microphone);
    });

    test('history songs can be shown while idle', () async {
      controller().show(song(key: 'old'));
      expect(state().phase, RecognitionPhase.result);
      expect(state().song?.key, 'old');
    });

    testWidgets('a stalled microphone ends after the time limit', (
      tester,
    ) async {
      flush = () async {
        for (var i = 0; i < 20; i++) {
          await tester.pump();
        }
      };
      addTearDown(() => flush = pumpEventQueue);
      await listen();
      await feed(2);
      await tester.pump(MusicRecognitionController.listenTimeout);
      await flush();
      expect(mic.stops, 1);
      expect(recognizer.sentSeconds, [2]);
      await reply(const RecognitionMissed(RecognitionMiss.tooShort));
      expect(state().failure, RecognitionFailure.notEnoughAudio);

      mic.stops = 0;
      await listen();
      await tester.pump(MusicRecognitionController.listenTimeout);
      await flush();
      expect(mic.stops, 1);
      expect(state().failure, RecognitionFailure.microphone);
    });
  });

  group('screen', () {
    for (final (style, reduceMotion) in [
      ('material', false),
      ('mornye', false),
      ('material', true),
    ]) {
      final name = '$style${reduceMotion ? ', reduced motion' : ''}';

      Future<(FakeMicrophone, FakeRecognizer, List<String?>)> open(
        WidgetTester tester, {
        RecognitionLibrary? library,
      }) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(393, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final mic = FakeMicrophone();
        final recognizer = FakeRecognizer();
        final popped = <String?>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              recognitionMicrophoneProvider.overrideWithValue(mic),
              musicRecognizerProvider.overrideWithValue(recognizer),
              recognitionLibraryProvider.overrideWithValue(
                library ?? FakeLibrary(),
              ),
              playbackPlayingProvider.overrideWith((ref) => false),
            ],
            child: MaterialApp(
              theme: style == 'mornye'
                  ? MornyeTheme.build(Brightness.light)
                  : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(393, 1400),
                  disableAnimations: reduceMotion,
                ),
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async => popped.add(
                      await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          builder: (_) =>
                              const MusicRecognitionScreen(listenOnOpen: false),
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await settle(tester);
        return (mic, recognizer, popped);
      }

      testWidgets('listens, then searches for an unknown song ($name)', (
        tester,
      ) async {
        final (mic, recognizer, popped) = await open(tester);
        expect(find.text("What's playing?"), findsOneWidget);
        expect(find.bySemanticsLabel('Start listening'), findsOneWidget);

        await tester.tap(find.bySemanticsLabel('Start listening'));
        await settle(tester);
        expect(find.text('Listening…'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        mic.feed(4);
        await settle(tester);
        recognizer.reply(
          RecognitionMatched(
            RecognizedSong(
              key: '9',
              title: 'Found Song',
              artist: 'Found Artist',
              album: 'Found Album',
              isrc: 'USX1',
              recognizedAt: DateTime.utc(2026),
            ),
          ),
        );
        await settle(tester);
        expect(find.text('Found Song'), findsWidgets);
        expect(find.text('Found Album'), findsOneWidget);
        expect(find.text('Open in Shazam'), findsOneWidget);
        expect(find.text('Recently Identified'), findsOneWidget);
        expect(mic.stops, 1);

        await tester.tap(find.text('Search in Mornye'));
        await settle(tester);
        expect(popped, ['Found Song Found Artist']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('offers to play a song from the library ($name)', (
        tester,
      ) async {
        final (mic, recognizer, _) = await open(
          tester,
          library: FakeLibrary(isrcs: {'USX1': '/music/song.flac'}),
        );
        await tester.tap(find.bySemanticsLabel('Start listening'));
        await settle(tester);
        mic.feed(4);
        await settle(tester);
        recognizer.reply(RecognitionMatched(song(isrc: 'USX1')));
        await settle(tester);
        expect(find.text('Play in Mornye'), findsOneWidget);
        expect(find.text('Search in Mornye'), findsNothing);
      });

      testWidgets('shows no match, then cancel returns to idle ($name)', (
        tester,
      ) async {
        final (mic, recognizer, _) = await open(tester);
        await tester.tap(find.bySemanticsLabel('Start listening'));
        await settle(tester);
        for (var i = 0; i < 3; i++) {
          mic.feed(4);
          await settle(tester);
          recognizer.reply(miss);
          await settle(tester);
        }
        expect(find.text('No match found'), findsOneWidget);

        await tester.tap(find.text('Try Again'));
        await settle(tester);
        expect(find.text('Listening…'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await settle(tester);
        expect(find.text("What's playing?"), findsOneWidget);
      });

      testWidgets('blocked access points to settings ($name)', (tester) async {
        final (mic, _, _) = await open(tester);
        mic.access = MicrophoneAccess.blocked;
        await tester.tap(find.bySemanticsLabel('Start listening'));
        await settle(tester);
        expect(find.text('Microphone access is off'), findsOneWidget);
        await tester.tap(find.text('Open Settings'));
        await settle(tester);
        expect(mic.settingsOpened, isTrue);
      });
    }
  });
}

/// Pumps a fixed time; listening indicators animate without end.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
