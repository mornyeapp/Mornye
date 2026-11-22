import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_alignment.dart';
import 'package:mornye/services/lyrics_translation_sharing.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/romanization/text_romanizer.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/widgets/mornye_squircle_border.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/lastfm_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('MornyeSquircleBorder path cache returns independent mutable paths', () {
    const border = MornyeSquircleBorder(18);
    const originRect = Rect.fromLTWH(0, 0, 120, 48);
    final first = border.getOuterPath(originRect);
    expect(first.getBounds().width, closeTo(120, 0.5));
    expect(first.getBounds().height, closeTo(48, 0.5));

    // Mutating a returned Path must never corrupt subsequent cached lookups.
    first.reset();
    expect(first.getBounds(), Rect.zero);

    final second = border.getOuterPath(originRect);
    expect(second.getBounds().width, closeTo(120, 0.5));
    expect(second.getBounds().height, closeTo(48, 0.5));

    const shiftedRect = Rect.fromLTWH(16, 24, 120, 48);
    final shifted = border.getOuterPath(shiftedRect);
    expect(shifted.getBounds().left, closeTo(16, 0.5));
    expect(shifted.getBounds().top, closeTo(24, 0.5));
  });

  test(
    'WeeklyReleaseService.savedAsync matches saved across isolate decode',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final artists = [
        for (var i = 0; i < 8; i++)
          CollectionArtistEntry(
            key: 'provider-a:artist-$i',
            artistId: 'artist-$i',
            providerId: 'provider-a',
            name: 'Artist $i',
            addedAt: DateTime(2026),
          ),
      ];
      final service = WeeklyReleaseService(
        preferences: Future.value(prefs),
        loadArtist: (artist) async => (
          providerId: 'provider-a',
          metadata: <String, dynamic>{
            'albums': [
              {
                'id': 'rel-${artist.artistId}',
                'name': 'Release ${artist.name}',
                'release_date':
                    '2026-10-${(10 + int.parse(artist.artistId.split('-').last)).toString().padLeft(2, '0')}',
              },
            ],
          },
        ),
      );
      await service.load(artists, now: DateTime(2026, 10, 20));

      final syncFeed = WeeklyReleaseService.saved(prefs, artists);
      final asyncFeed = await WeeklyReleaseService.savedAsync(prefs, artists);
      expect(asyncFeed.releases.length, 8);
      expect(
        [for (final r in asyncFeed.releases) (r.id, r.name, r.date)],
        [for (final r in syncFeed.releases) (r.id, r.name, r.date)],
      );
    },
  );

  test('Scrobbler ignores steady 2 Hz position-only PlaybackState ticks', () {
    fakeAsync((async) {
      final start = DateTime.utc(2026, 11, 1, 12);
      final api = FakeLastfmApi();
      final store = MemoryLastfmStore();
      final service = LastfmService(
        api: api,
        store: store,
        now: () => start.add(async.elapsed),
        elapsed: () => async.elapsed,
      );
      service.initialize();
      async.flushMicrotasks();

      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(
        const MediaItem(
          id: 'file:///music/example.flac',
          title: 'Example Song',
          artist: 'Example Artist',
          duration: Duration(minutes: 4),
          extras: {'playbackInstance': 1},
        ),
      );
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          speed: 1,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration.zero,
        ),
      );
      async.flushMicrotasks();
      expect(api.announcements, hasLength(1));
      expect(async.pendingTimers, hasLength(1));
      final originalTimer = async.pendingTimers.single;

      // Emit 20 position-only 2 Hz ticks while playing steadily.
      for (var i = 1; i <= 20; i++) {
        async.elapse(const Duration(milliseconds: 500));
        handler.playbackState.add(
          PlaybackState(
            playing: true,
            speed: 1,
            processingState: AudioProcessingState.ready,
            updatePosition: Duration(milliseconds: i * 500),
          ),
        );
        async.flushMicrotasks();
      }
      expect(api.announcements, hasLength(1));
      expect(async.pendingTimers.single, same(originalTimer));

      // Advance the remaining 110 s to reach half of the 4-minute song.
      async.elapse(const Duration(seconds: 110));
      expect(api.batches, hasLength(1));

      service.close();
      async.flushMicrotasks();
    });
  });

  test('TextRomanizer.canRomanize fast path preserves script boundaries', () {
    final romanizer = TextRomanizer.forTexts(const [
      'Hello café naïve',
      '안녕하세요',
      'こんにちは',
      'Привет',
    ]);
    expect(romanizer.canRomanize('Hello world!'), isTrue);
    expect(romanizer.canRomanize('Café naïve résumé «100%» \u2026'), isTrue);
    expect(romanizer.canRomanize('안녕하세요！こんにちは「テスト」'), isTrue);
    expect(romanizer.canRomanize('Привет мир'), isTrue);
    expect(romanizer.canRomanize('Ελληνικά'), isFalse);
    expect(romanizer.canRomanize('العربية'), isFalse);
    expect(romanizer.canRomanize('ภาษาไทย'), isFalse);
    // Letters that sit among symbols and punctuation still count.
    expect(romanizer.canRomanize('5 µm'), isFalse);
    expect(romanizer.canRomanize('10 Ω'), isFalse);
    expect(romanizer.canRomanize('〆'), isFalse);
  });

  test('LyricsTranslationSharing.receive deduplicates via direct equality', () {
    final sharing = LyricsTranslationSharing();
    addTearDown(sharing.dispose);
    final hash = List.filled(64, 'a').join();
    SharedLyricsTranslation buildUpdate({
      String line = 'Hello',
      String romaji = 'konnichiwa',
      int source = 0,
      int updatedMs = 1000,
    }) => SharedLyricsTranslation(
      sourceHash: hash,
      language: 'en',
      updatedMs: updatedMs,
      result: LyricsTranslationResult(
        [line],
        romanizations: [romaji],
        alignments: [
          [LyricsTranslationChunk(line, source)],
        ],
        romanizationAlignments: [
          [LyricsTranslationChunk(romaji, source)],
        ],
      ),
    );

    expect(sharing.receive(buildUpdate()), isTrue);
    expect(sharing.receive(buildUpdate()), isFalse);
    expect(sharing.receive(buildUpdate(line: 'Hello!')), isTrue);
    expect(sharing.receive(buildUpdate(line: 'Hello!', source: 1)), isTrue);
  });

  test(
    'PlatformBridge.runNativeDataJob forwards operation hint cleanly',
    () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Map<Object?, Object?>? seenArgs;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seenArgs = call.arguments as Map<Object?, Object?>;
        return '{"ok":true}';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'palette',
        'max_colors': 8,
      }, bytes: Uint8List.fromList([1, 2, 3, 4]));
      expect(result, {'ok': true});
      expect(seenArgs?['operation'], 'palette');
      expect(seenArgs?['request_json'], isA<String>());
      expect(seenArgs?['bytes'], isA<Uint8List>());
    },
  );
}
