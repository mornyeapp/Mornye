import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/automix_status.dart';
import 'package:mornye/services/autoplay_sound_signal.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/song_analysis.dart';
import 'package:mornye/services/song_analysis_store.dart';
import 'package:mornye/services/song_feature_analyzer.dart';
import 'package:mornye/services/song_features.dart';

const _timeout = Duration(seconds: 10);

/// Analyzes each song as [results] says, and reports each request.
class _FakeAnalyzer implements SongFeatureAnalyzer {
  final results = <String, SongAnalysisResult>{};
  final calls = <String>[];
  final _called = StreamController<String>.broadcast();

  /// Holds the analysis of this song until it is cancelled.
  String? hold;
  Completer<void>? _held;

  Future<String> next() => _called.stream.first.timeout(_timeout);

  @override
  Future<SongAnalysisResult> analyze(String path, {Duration? duration}) async {
    calls.add(path);
    _called.add(path);
    if (path == hold) {
      await (_held = Completer<void>()).future;
      return const SongAnalysisResult.unavailable();
    }
    return results[path] ??
        SongAnalysisResult.described(
          Float32List(SongFeatures.length)..[0] = path.length.toDouble(),
        );
  }

  @override
  void cancel() {
    final held = _held;
    _held = null;
    if (held != null && !held.isCompleted) held.complete();
  }

  @override
  void dispose() => cancel();
}

/// Short waits pass at once; longer ones wait for the test to release them.
class _Waits {
  final _held = StreamController<(Duration, Completer<void>)>();
  late final _queue = StreamIterator(_held.stream);

  Future<void> call(Duration delay) {
    if (delay < const Duration(minutes: 1)) return Future<void>.value();
    final done = Completer<void>();
    _held.add((delay, done));
    return done.future;
  }

  /// The next long wait the analysis started, which [release] ends.
  Future<Duration> next() async {
    if (!await _queue.moveNext().timeout(_timeout)) {
      throw StateError('No more waits');
    }
    return _queue.current.$1;
  }

  void release() => _queue.current.$2.complete();
}

PlayableMedia _media(String source) =>
    PlayableMedia(id: source, source: source, title: source, artist: 'A');

bool _idle() => false;

MediaItem _playing(String source) => MediaItem(
  id: source,
  title: source,
  duration: const Duration(minutes: 3),
  extras: {'source': source},
);

void main() {
  late String databasePath;
  late _FakeAnalyzer analyzer;
  late _Waits waits;
  late StreamController<MediaItem?> playing;
  late List<String> library;
  late Map<String, SongFileStamp> files;
  var charging = false;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('song-analysis-');
    addTearDown(() => directory.delete(recursive: true));
    databasePath = '${directory.path}/song_analysis.db';
    analyzer = _FakeAnalyzer();
    waits = _Waits();
    playing = StreamController<MediaItem?>.broadcast();
    addTearDown(playing.close);
    library = ['/a.flac', '/b.flac'];
    files = {
      for (final path in ['/a.flac', '/b.flac', '/c.flac', '/d.flac'])
        path: (size: 1, modified: 1),
    };
    charging = false;
  });

  SongAnalysisStore openStore() {
    Database? db;
    addTearDown(() => db?.close());
    return SongAnalysisStore(
      open: () async => db = await SongAnalysisStore.openWithFactory(
        databaseFactoryFfi,
        databasePath,
      ),
    );
  }

  /// [busy] null keeps the analysis's own check of AutoMix and song starts.
  (SongAnalysis, SongAnalysisStore) create({
    SongAnalysisSweep sweep = SongAnalysisSweep.whileCharging,
    bool isAndroid = true,
    AppSettings settings = const AppSettings(songAnalysis: true),
    bool Function()? busy = _idle,
    Future<void> Function(Duration)? wait,
  }) {
    final store = openStore();
    final analysis = SongAnalysis(
      store: store,
      analyzer: analyzer,
      librarySongs: () async => [
        for (final path in library)
          (path: path, duration: const Duration(minutes: 3), local: false),
      ],
      stamp: (path) async => files[path],
      isCharging: () async => charging,
      busy: busy,
      wait: wait ?? waits.call,
      sweep: sweep,
      isAndroid: isAndroid,
    )..configure(settings);
    addTearDown(analysis.dispose);
    return (analysis, store);
  }

  test('Android sweeps the Library only while charging and analyzes the '
      'song playing on battery', () async {
    final (analysis, store) = create();
    analysis.start(playing.stream);
    expect(await waits.next(), const Duration(seconds: 90));
    waits.release();
    // On battery the sweep checks again later.
    expect(await waits.next(), const Duration(minutes: 5));
    expect(analyzer.calls, isEmpty);

    final current = analyzer.next();
    playing.add(_playing('/c.flac'));
    expect(await current, '/c.flac');

    charging = true;
    waits.release();
    expect(await waits.next(), const Duration(minutes: 30));
    expect(analyzer.calls, ['/c.flac', '/a.flac', '/b.flac']);
    expect(analysis.progress.value?.analyzed, 2);
    expect(analysis.progress.value?.total, 2);
    // The song playing is kept although the Library does not have it.
    expect((await store.features(['/a.flac', '/b.flac', '/c.flac'])).length, 3);

    // A removed song is forgotten on the next pass.
    library = ['/a.flac'];
    playing.add(null);
    waits.release();
    expect(await waits.next(), const Duration(minutes: 30));
    expect((await store.records()).keys, ['/a.flac']);
    expect(analyzer.calls, hasLength(3));
  });

  test('analysis stays off until the listener turns it on', () async {
    expect(const AppSettings().songAnalysis, isFalse);
    expect(AppSettings.fromJson(const {}).songAnalysis, isFalse);
    final (analysis, store) = create(settings: const AppSettings());
    analysis.start(playing.stream);
    playing.add(_playing('/a.flac'));
    await pumpEventQueue();
    expect(analyzer.calls, isEmpty);
    expect(await store.records(), isEmpty);
    expect(await analysis.loadSignal(session: [], candidates: []), isNull);
  });

  test('without the charging rule Android sweeps on battery', () async {
    final (analysis, _) = create(
      settings: const AppSettings(
        songAnalysis: true,
        songAnalysisOnlyWhileCharging: false,
      ),
    );
    analysis.start(playing.stream);
    expect(await waits.next(), const Duration(seconds: 90));
    waits.release();
    expect(await waits.next(), const Duration(minutes: 30));
    expect(analyzer.calls, ['/a.flac', '/b.flac']);
  });

  test('turning analysis off stops the sweep and the song playing', () async {
    var settings = const AppSettings(
      songAnalysis: true,
      songAnalysisOnlyWhileCharging: false,
    );
    final (analysis, store) = create(settings: settings);
    analyzer.hold = '/a.flac';
    analysis.start(playing.stream);
    expect(await waits.next(), const Duration(seconds: 90));
    final started = analyzer.next();
    waits.release();
    expect(await started, '/a.flac');

    analysis.configure(settings = settings.copyWith(songAnalysis: false));
    await pumpEventQueue();
    playing.add(_playing('/c.flac'));
    await pumpEventQueue();
    expect(analyzer.calls, ['/a.flac']);
    expect(await store.records(), isEmpty);
    expect(await analysis.loadSignal(session: [], candidates: []), isNull);

    // Turning it on again resumes from the start, without the cancelled
    // attempt counting as one.
    analyzer.hold = null;
    analysis.configure(settings.copyWith(songAnalysis: true));
    expect(await waits.next(), const Duration(minutes: 30));
    expect(analyzer.calls, ['/a.flac', '/a.flac', '/b.flac']);
  });

  group('while AutoMix prepares a mix', () {
    var rechecks = 0;

    /// Busy rechecks pass after an event-loop turn; the second one finds
    /// AutoMix done.
    Future<void> wait(Duration delay) {
      if (delay != const Duration(seconds: 15)) return waits.call(delay);
      if (++rechecks == 2) autoMixPreparing.value = false;
      return Future<void>.delayed(Duration.zero);
    }

    setUp(() {
      rechecks = 0;
      autoMixPreparing.value = true;
      addTearDown(() => autoMixPreparing.value = false);
    });

    test('the Library sweep waits', () async {
      final (analysis, _) = create(
        settings: const AppSettings(
          songAnalysis: true,
          songAnalysisOnlyWhileCharging: false,
        ),
        busy: null,
        wait: wait,
      );
      analysis.start(playing.stream);
      expect(await waits.next(), const Duration(seconds: 90));
      final first = analyzer.next();
      waits.release();
      expect(await first, '/a.flac');
      expect(rechecks, 2);
    });

    test('the song playing waits', () async {
      final (analysis, _) = create(busy: null, wait: wait);
      analysis.start(playing.stream);
      expect(await waits.next(), const Duration(seconds: 90));
      final current = analyzer.next();
      playing.add(_playing('/c.flac'));
      expect(await current, '/c.flac');
      expect(rechecks, 2);
      expect(analyzer.calls, ['/c.flac']);
    });
  });

  test('failures are recorded and tried again only once the file changes; '
      'unavailable analysis is not recorded', () async {
    library = ['/a.flac', '/b.flac', '/c.flac'];
    analyzer.results['/a.flac'] = const SongAnalysisResult.failed();
    analyzer.results['/b.flac'] = const SongAnalysisResult.unavailable();
    final (analysis, store) = create(sweep: SongAnalysisSweep.always);
    analysis.start(playing.stream);
    expect(await waits.next(), const Duration(seconds: 90));
    waits.release();
    expect(await waits.next(), const Duration(minutes: 30));
    final records = await store.records();
    expect(records.keys, unorderedEquals(['/a.flac', '/c.flac']));
    expect(records['/a.flac']!.failed, isTrue);
    expect(analysis.progress.value?.analyzed, 1);

    analyzer.results.remove('/b.flac');
    waits.release();
    expect(await waits.next(), const Duration(minutes: 30));
    expect(analyzer.calls, ['/a.flac', '/b.flac', '/c.flac', '/b.flac']);

    files['/a.flac'] = (size: 2, modified: 2);
    analyzer.results.remove('/a.flac');
    waits.release();
    expect(await waits.next(), const Duration(minutes: 30));
    expect(analyzer.calls.last, '/a.flac');
    expect(analysis.progress.value?.analyzed, 3);

    // A missing file loses its row instead of being analyzed.
    files.remove('/c.flac');
    playing.add(_playing('/c.flac'));
    await pumpEventQueue(times: 50);
    expect((await store.records()).keys, isNot(contains('/c.flac')));
  });

  test('repeated unavailable analysis backs off', () async {
    library = ['/a.flac', '/b.flac', '/c.flac', '/d.flac'];
    for (final path in library) {
      analyzer.results[path] = const SongAnalysisResult.unavailable();
    }
    final (analysis, _) = create(sweep: SongAnalysisSweep.always);
    analysis.start(playing.stream);
    expect(await waits.next(), const Duration(seconds: 90));
    waits.release();
    expect(await waits.next(), const Duration(hours: 1));
    expect(analyzer.calls, ['/a.flac', '/b.flac', '/c.flac']);
  });

  test('iOS analyzes only the song playing, never documents', () async {
    library = ['/a.flac', 'content://media/b'];
    final (analysis, store) = create(
      sweep: SongAnalysisSweep.never,
      isAndroid: false,
    );
    analysis.start(playing.stream);
    expect(await waits.next(), const Duration(seconds: 90));
    waits.release();
    await analysis.refreshProgress();
    expect(analysis.progress.value?.total, 1);

    playing.add(_playing('content://media/b'));
    final current = analyzer.next();
    playing.add(_playing('/b.flac'));
    expect(await current, '/b.flac');
    await pumpEventQueue(times: 50);
    expect(analyzer.calls, ['/b.flac']);
    expect((await store.records()).keys, ['/b.flac']);
  });

  test('windows skip intros and stay inside the song', () {
    List<double> offsets(int seconds) =>
        SongFeatureAnalyzer.windowOffsets(Duration(seconds: seconds));
    expect(offsets(200), [60, 120]);
    // Near the end, a window still fits before it.
    expect(offsets(60), [18, 36]);
    // A short song gets one window from its middle, or all of it.
    expect(offsets(40), [8]);
    expect(offsets(10), [0]);
    expect(SongFeatureAnalyzer.windowOffsets(null), [30, 90]);
  });

  test('Autoplay gets a sound signal once two songs are known', () async {
    final (analysis, store) = create();
    final a = _media('/a.flac'), b = _media('/b.flac'), c = _media('/c.flac');
    final features = Float32List(SongFeatures.length);
    await store.save(a.source, (size: 1, modified: 1), features);
    expect(await analysis.loadSignal(session: [a], candidates: [c]), isNull);

    await store.save(b.source, (size: 1, modified: 1), features);
    final signal = await analysis.loadSignal(session: [a], candidates: [b, c]);
    expect(signal, isA<SoundAutoplaySignal>());
    expect(
      (signal! as SoundAutoplaySignal).features.keys,
      unorderedEquals([a.source, b.source]),
    );

    await analysis.clear();
    expect(await store.records(), isEmpty);
  });
}
