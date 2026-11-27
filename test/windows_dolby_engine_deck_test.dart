import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/windows_media_playback_deck.dart';

class _Deck implements PlaybackDeck, QueuedPlaybackDeck {
  _Deck(this.name);

  final String name;
  final calls = <String>[];
  final states = StreamController<PlaybackDeckState>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final completions = StreamController<void>.broadcast();
  bool disposed = false;

  /// Thrown by [configureOutput] or by loading a source.
  Object? configureError;
  Object? loadError;

  @override
  bool get canQueueNextSource => name == 'mpv';

  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    calls.add('queue $source');
    return true;
  }

  @override
  Future<void> clearNextSource() async => calls.add('clear next');

  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  @override
  bool get isDirect => false;
  @override
  PlaybackTempoSupport get tempoSupport =>
      name == 'mpv' ? PlaybackTempoSupport.full : PlaybackTempoSupport.none;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => states.stream;
  @override
  Stream<Duration> get onDurationChanged => durations.stream;
  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<void> get onPlayerComplete => completions.stream;

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {}

  @override
  Future<void> configureOutput() async {
    calls.add('configure');
    final error = configureError;
    if (error != null) throw error;
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> setPlaybackRate(double rate) async {}
  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {
    calls.add('url $url');
    final error = loadError;
    if (error != null) throw error;
  }

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
    int usbMaxSampleRate = 0,
    bool usbDitherHighPass = false,
  }) async {
    calls.add('file $path');
    final error = loadError;
    if (error != null) throw error;
  }

  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> resume() async {
    calls.add('resume');
    state = PlaybackDeckState.playing;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    state = PlaybackDeckState.paused;
  }

  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {
    calls.add('stop');
    state = PlaybackDeckState.stopped;
  }

  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async => false;
  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;
  @override
  Future<Duration?> getDuration() async => const Duration(minutes: 3);
  @override
  Future<void> dispose() async {
    disposed = true;
    await states.close();
    await durations.close();
    await positions.close();
    await completions.close();
  }
}

/// An MP4 box: big-endian size, type, body.
List<int> _box(String type, List<int> body) {
  final size = 8 + body.length;
  return [
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...body,
  ];
}

/// An MP4 file whose audio track uses [sampleEntry], with the media data
/// ahead of the index as many encoders write it.
List<int> _mp4(String sampleEntry) => [
  ..._box('ftyp', 'M4A \u0000\u0000\u0000\u0000'.codeUnits),
  ..._box('mdat', List.filled(4096, 0)),
  ..._box(
    'moov',
    _box('trak', [...List.filled(32, 0), ...sampleEntry.codeUnits]),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isDolbyAudioFile', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('dolby'));
    tearDown(() => directory.deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final file = File('${directory.path}/$name')..writeAsBytesSync(bytes);
      return file.path;
    }

    test('finds E-AC-3 and AC-4 tracks in MP4 files', () async {
      expect(await isDolbyAudioFile(write('atmos.m4a', _mp4('ec-3'))), isTrue);
      expect(await isDolbyAudioFile(write('atmos.mp4', _mp4('ac-4'))), isTrue);
      expect(
        await isDolbyAudioFile(write('stereo.m4a', _mp4('mp4a'))),
        isFalse,
      );
      expect(
        await isDolbyAudioFile(write('lossless.m4a', _mp4('alac'))),
        isFalse,
      );
    });

    test('finds Dolby codec IDs in Matroska files', () async {
      final header = [0x1a, 0x45, 0xdf, 0xa3, ...List.filled(64, 0)];
      expect(
        await isDolbyAudioFile(
          write('atmos.mka', [...header, ...'A_EAC3'.codeUnits]),
        ),
        isTrue,
      );
      expect(
        await isDolbyAudioFile(
          write('ac4.mkv', [...header, ...'A_AC4'.codeUnits]),
        ),
        isTrue,
      );
      expect(
        await isDolbyAudioFile(
          write('flac.mka', [...header, ...'A_FLAC'.codeUnits]),
        ),
        isFalse,
      );
    });

    test('trusts raw Dolby extensions and refuses everything else', () async {
      for (final name in ['song.ec3', 'song.EAC3', 'song.ac4']) {
        expect(await isDolbyAudioFile('${directory.path}/$name'), isTrue);
      }
      expect(await isDolbyAudioFile(write('song.flac', _mp4('ec-3'))), isFalse);
      // A file that cannot be read stays on libmpv.
      expect(await isDolbyAudioFile('${directory.path}/missing.m4a'), isFalse);
    });
  });

  group('WindowsDolbyEngineDeck', () {
    late _Deck mpv;
    late List<_Deck> windows;
    late WindowsDolbyEngineDeck deck;
    Object? windowsConfigureError;
    Object? windowsLoadError;

    Future<bool> dolby(String path) async =>
        path.endsWith('.m4a') || path.endsWith('.ac4');

    setUp(() {
      mpv = _Deck('mpv');
      windows = [];
      windowsConfigureError = null;
      windowsLoadError = null;
      deck = WindowsDolbyEngineDeck(
        mpv: mpv,
        isDolby: dolby,
        createWindowsMedia: () {
          final created = _Deck('windows')
            ..configureError = windowsConfigureError
            ..loadError = windowsLoadError;
          windows.add(created);
          return created;
        },
      );
    });

    tearDown(() async {
      await deck.dispose();
      playbackWindowsDolbyEngine.value = true;
      playbackExclusiveOutput.value = false;
      WindowsMediaPlaybackDeck.debugResetAvailability();
    });

    test(
      'Dolby songs play through Windows and the rest through libmpv',
      () async {
        await deck.setVolume(0.5);
        await deck.configureOutput();
        await deck.setFileSource('/atmos.m4a');
        await deck.resume();
        expect(deck.activeDeck, same(windows.single));
        expect(windows.single.calls, [
          'volume 0.5',
          'configure',
          'file /atmos.m4a',
          'resume',
        ]);
        expect(deck.tempoSupport, PlaybackTempoSupport.none);

        await deck.setFileSource('/song.flac');
        expect(deck.activeDeck, same(mpv));
        expect(mpv.calls.last, 'file /song.flac');
        // Leaving the Windows engine releases its player.
        expect(windows.single.disposed, isTrue);
        expect(deck.tempoSupport, PlaybackTempoSupport.full);
      },
    );

    test(
      'the setting and exclusive output keep Dolby songs on libmpv',
      () async {
        playbackWindowsDolbyEngine.value = false;
        await deck.setFileSource('/atmos.m4a');
        expect(deck.activeDeck, same(mpv));

        playbackWindowsDolbyEngine.value = true;
        playbackExclusiveOutput.value = true;
        await deck.setFileSource('/atmos.m4a');
        expect(deck.activeDeck, same(mpv));
        expect(windows, isEmpty);
        expect(
          mpv.calls.where((call) => call == 'file /atmos.m4a'),
          hasLength(2),
        );
      },
    );

    test('a song Windows cannot open plays through libmpv', () async {
      windowsLoadError = PlatformException(code: 'unsupported');
      await deck.setFileSource('/atmos.m4a');
      expect(deck.activeDeck, same(mpv));
      expect(mpv.calls.last, 'file /atmos.m4a');
      expect(windows.single.disposed, isTrue);

      // The song is not offered to Windows again.
      await deck.setFileSource('/atmos.m4a');
      expect(windows, hasLength(1));
      expect(deck.activeDeck, same(mpv));
    });

    test('a missing Windows engine is not tried again', () async {
      windowsConfigureError = MissingPluginException();
      await deck.setFileSource('/atmos.m4a');
      expect(deck.activeDeck, same(mpv));
      expect(WindowsMediaPlaybackDeck.isAvailable, isFalse);

      await deck.setFileSource('/other.ac4');
      expect(windows, hasLength(1));
      expect(mpv.calls.last, 'file /other.ac4');
    });

    test('Dolby songs are not queued on libmpv', () async {
      await deck.setFileSource('/song.flac');
      var started = 0;
      expect(
        await deck.queueNextSource(
          '/atmos.m4a',
          volume: 1,
          onStarted: () => started++,
        ),
        isFalse,
      );
      expect(
        await deck.queueNextSource(
          '/next.flac',
          volume: 1,
          onStarted: () => started++,
        ),
        isTrue,
      );
      expect(mpv.calls.where((call) => call.startsWith('queue')), [
        'queue /next.flac',
      ]);
      expect(started, 0);
    });
  });
}
