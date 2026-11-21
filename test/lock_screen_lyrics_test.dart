import 'dart:async';
import 'dart:convert';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/lock_screen_lyrics.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

Duration _seconds(num seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

LyricLine _line(num start, String text, {num? end, bool background = false}) =>
    LyricLine(
      time: _seconds(start),
      end: end == null ? null : _seconds(end),
      text: text,
      isBackground: background,
    );

/// The system's end of the session: each request in the order it arrived.
class _Os extends AudioServicePlatform {
  final requests = <Object>[];

  /// The titles the system was given, in order.
  List<String> get titles => [
    for (final request in requests)
      if (request case SetMediaItemRequest(:final mediaItem)) mediaItem.title,
  ];

  /// The artists the system was given, in order.
  List<String?> get artists => [
    for (final request in requests)
      if (request case SetMediaItemRequest(:final mediaItem)) mediaItem.artist,
  ];

  @override
  Future<void> setState(SetStateRequest request) async => requests.add(request);

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async =>
      requests.add(request);

  @override
  Future<void> stopService(StopServiceRequest request) async =>
      requests.add(request);
}

const _lyrics = {
  'music/a.flac':
      '[00:01.00]First line\n'
      '[00:04.00]Second line\n'
      '[00:20.00]\n'
      '[00:30.00]Third line',
  'music/b.flac': '[00:02.00]Another song',
  'content://library/c.flac': '[00:01.00]From a picked folder',
};

SetMediaItemRequest _item(String id, String title, {String? source}) =>
    SetMediaItemRequest(
      mediaItem: MediaItemMessage(
        id: id,
        title: title,
        artist: 'Artist',
        extras: {'source': source ?? 'music/$id.flac'},
      ),
    );

SetStateRequest _state(DateTime at, {bool playing = true, num position = 0}) =>
    SetStateRequest(
      state: PlaybackStateMessage(
        processingState: AudioProcessingStateMessage.ready,
        playing: playing,
        updatePosition: _seconds(position),
        updateTime: at,
      ),
    );

/// A session over [os] with lyrics for [_lyrics], at the test's fake time.
class _Harness {
  _Harness(this.tester, {this.restatePosition = false, this.storedOffsets});

  final WidgetTester tester;
  final bool restatePosition;

  /// True reads the offsets the app stores; otherwise lyrics are in sync.
  final bool? storedOffsets;
  final os = _Os();
  final _lockScreen = StreamController<bool>.broadcast(sync: true);

  late final session = LockScreenLyrics(
    os,
    lockScreen: () => _lockScreen.stream,
    metadata: () => PlayerMetadataController(
      readMetadata: (path) async => {'lyrics': _lyrics[path] ?? ''},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
    ),
    lyricsOffset: storedOffsets == true ? null : (_) async => Duration.zero,
    restatePosition: restatePosition,
    now: () => now,
  );

  DateTime get now => tester.binding.clock.now();

  Future<void> flush() => tester.pump();

  Future<void> elapse(num seconds) => tester.pump(_seconds(seconds));

  Future<void> lock(bool showing) {
    _lockScreen.add(showing);
    return flush();
  }

  /// Plays [id] from the start.
  Future<void> play(String id, String title, {String? source}) {
    session.setMediaItem(_item(id, title, source: source));
    session.setState(_state(now));
    return flush();
  }

  /// Turns the session off and lets its last change go out.
  Future<void> close() async {
    session.enabled = false;
    await elapse(1);
    await _lockScreen.close();
  }
}

void main() {
  group('LockScreenLyricTimeline', () {
    test('shows each lead line until the next one', () {
      final timeline = LockScreenLyricTimeline([
        _line(1, 'First'),
        _line(4, 'Second'),
        _line(4.5, 'Echo', background: true),
      ]);

      expect(timeline.at(_seconds(0.5)), (line: null, next: _seconds(1)));
      expect(timeline.at(_seconds(2)), (line: 'First', next: _seconds(4)));
      expect(timeline.at(_seconds(5)), (line: 'Second', next: null));
    });

    test('keeps the sung line over one timed with it', () {
      final timeline = LockScreenLyricTimeline(
        LyricsParser.parse(
          '[00:01.00]Sung line\n[00:01.00]Its translation\n'
          '[00:04.00]Next line\n[00:04.00]Next translation',
        ).lines,
      );

      expect(timeline.at(_seconds(2)), (line: 'Sung line', next: _seconds(4)));
      expect(timeline.at(_seconds(5)), (line: 'Next line', next: null));
    });

    test('shows no line in a break of three seconds or more', () {
      final timeline = LockScreenLyricTimeline([
        _line(1, 'First'),
        _line(5, ''),
        _line(6, 'Second'),
        _line(10, ''),
        _line(20, 'Third'),
      ]);

      // One second of silence keeps the line.
      expect(timeline.at(_seconds(5.5)).line, 'First');
      expect(timeline.at(_seconds(12)), (line: null, next: _seconds(20)));
      expect(timeline.at(_seconds(21)).line, 'Third');
    });

    test('ends a line at its known end, and after the last one', () {
      final timeline = LockScreenLyricTimeline([
        _line(1, 'First', end: 3),
        _line(10, 'Overlapping', end: 20),
        _line(12, 'Short', end: 13),
        _line(18, 'Last', end: 19),
      ]);

      expect(timeline.at(_seconds(5)), (line: null, next: _seconds(10)));
      // The longer line is still sung, so no break starts after the short.
      expect(timeline.at(_seconds(17)).line, 'Short');
      expect(timeline.at(_seconds(18.5)).line, 'Last');
      expect(timeline.at(_seconds(25)), (line: null, next: null));
    });

    test('follows the lyrics timing setting and tidies spacing', () {
      final timeline = LockScreenLyricTimeline([
        _line(1, '  Two\n words  '),
      ], offset: const Duration(milliseconds: 500));

      expect(timeline.at(_seconds(1.2)).line, isNull);
      expect(timeline.at(_seconds(1.6)).line, 'Two words');
    });

    const long = 'You got that long hair slicked back, white t-shirt';

    test('shows a long line in parts at a steady pace', () {
      final timeline = LockScreenLyricTimeline([
        _line(10, long, end: 16),
        _line(20, 'Next'),
      ]);

      // The second part starts 18 of 50 characters in, the third after the
      // comma, 37 characters in.
      expect(timeline.at(_seconds(11)), (
        line: 'You got that long',
        next: _seconds(12.16),
      ));
      expect(timeline.at(_seconds(13)).line, 'hair slicked back,');
      expect(timeline.at(_seconds(15)).line, 'white t-shirt');
      expect(timeline.at(_seconds(21)).line, 'Next');
    });

    test('starts each part with its first sung word', () {
      final words = long.split(' ');
      final timeline = LockScreenLyricTimeline([
        LyricLine(
          time: _seconds(10),
          end: _seconds(18),
          text: long,
          words: [
            for (final (index, word) in words.indexed)
              LyricWord(
                time: _seconds(10 + index * 0.9),
                end: _seconds(10.9 + index * 0.9),
                text: index + 1 < words.length ? '$word ' : word,
              ),
          ],
        ),
      ]);

      // "hair" is the fifth word, "white" the eighth.
      expect(timeline.at(_seconds(13.5)).line, 'You got that long');
      expect(timeline.at(_seconds(13.6)).line, 'hair slicked back,');
      expect(timeline.at(_seconds(16.2)).line, 'hair slicked back,');
      expect(timeline.at(_seconds(16.3)).line, 'white t-shirt');
    });

    test('paces a long line before a break no slower than singing', () {
      // The next line starts 30 s later; the parts keep 150 ms a character.
      final timeline = LockScreenLyricTimeline([
        _line(10, long),
        _line(40, 'After the break'),
      ]);

      expect(timeline.at(_seconds(14)).line, 'hair slicked back,');
      expect(timeline.at(_seconds(16)).line, 'white t-shirt');
    });

    test('keeps a line sung too fast to read in parts whole', () {
      final timeline = LockScreenLyricTimeline([_line(10, long, end: 12)]);

      expect(timeline.at(_seconds(11.9)).line, long);
    });

    test('cuts lines that fit and wide characters sensibly', () {
      expect(lyricPartCount('Short line', 24), 1);
      expect(lyricTextWidth('我们'), 4);
      // Chinese has no spaces; the comma is the natural place to cut.
      const chinese = '我们一起走过的那些日子，永远留在我的心里';
      expect(lyricPartCount(chinese, 24), 2);
      expect(lyricPartStarts(chinese, 2), [0, 12]);
    });
  });

  group('LockScreenLyrics', () {
    testWidgets('shows the line being sung only while the lock screen shows', (
      tester,
    ) async {
      final h = _Harness(tester);
      h.session.enabled = true;
      await h.play('a', 'Song');
      expect(h.os.titles, ['Song']);

      await h.lock(true);
      await h.elapse(1);
      expect(h.os.titles.last, 'First line');
      await h.elapse(3);
      expect(h.os.titles.last, 'Second line');
      // The empty line at 20 s starts a ten-second break.
      await h.elapse(17);
      expect(h.os.titles.last, 'Song');
      await h.elapse(9);
      expect(h.os.titles.last, 'Third line');

      await h.lock(false);
      await h.elapse(0.5);
      expect(h.os.titles.last, 'Song');
      await h.close();
    });

    testWidgets('with the title kept, the line takes the artist\'s place', (
      tester,
    ) async {
      final h = _Harness(tester);
      h.session
        ..keepTitle = true
        ..enabled = true;
      await h.play('a', 'Song');
      await h.lock(true);
      await h.elapse(1);
      expect(h.os.titles.last, 'Song');
      expect(h.os.artists.last, 'First line');
      // In a break the artist is back.
      await h.elapse(20);
      expect(h.os.artists.last, 'Artist');
      expect(h.os.titles.toSet(), {'Song'});

      // Changing the place moves a line on show.
      await h.elapse(9);
      expect(h.os.artists.last, 'Third line');
      h.session.keepTitle = false;
      await h.flush();
      expect(h.os.titles.last, 'Third line');
      expect(h.os.artists.last, 'Artist');
      await h.close();
    });

    testWidgets('keeps the title while off, paused, or for another song', (
      tester,
    ) async {
      final h = _Harness(tester);
      await h.play('a', 'Song');
      await h.lock(true);
      await h.elapse(2);
      expect(h.os.titles, everyElement('Song'));

      h.session.enabled = true;
      await h.lock(true);
      expect(h.os.titles.last, 'First line');

      h.session.setState(_state(h.now, playing: false, position: 2));
      await h.elapse(1);
      expect(h.os.titles.last, 'Song');

      h.session.setState(_state(h.now, position: 2));
      await h.flush();
      expect(h.os.titles.last, 'First line');

      // The next song shows its own title, never the last song's line.
      await h.play('b', 'Other');
      expect(h.os.titles.last, 'Other');
      await h.elapse(2);
      expect(h.os.titles.last, 'Another song');
      await h.close();
      expect(h.os.titles.last, 'Other');
    });

    testWidgets('times each song with the app-wide and its own offset', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kLyricsOffsetKey: 500,
        kSongLyricsOffsetsKey: jsonEncode({
          songLyricsOffsetKey('Song', 'Artist'): [500, 1],
        }),
      });
      final h = _Harness(tester, storedOffsets: true)..session.enabled = true;
      await h.play('a', 'Song');
      await h.lock(true);
      // The first line at 1 s shows at 2 s: 0.5 s app-wide, 0.5 s its own.
      await h.elapse(1.5);
      expect(h.os.titles.last, 'Song');
      await h.elapse(0.6);
      expect(h.os.titles.last, 'First line');

      // Another song has only the app-wide offset: its line at 2 s shows at
      // 2.5 s.
      await h.play('b', 'Other');
      await h.elapse(2.2);
      expect(h.os.titles.last, 'Other');
      await h.elapse(0.4);
      expect(h.os.titles.last, 'Another song');
      await h.close();
    });

    testWidgets('reads a song played straight from a picked folder', (
      tester,
    ) async {
      final h = _Harness(tester)..session.enabled = true;
      // Playback publishes no resolved copy of an SAF document it streams.
      await h.play('c', 'Song', source: 'content://library/c.flac');
      await h.lock(true);
      await h.elapse(1);
      expect(h.os.titles.last, 'From a picked folder');
      await h.close();
    });

    testWidgets('keeps the line when the same item is sent again', (
      tester,
    ) async {
      final h = _Harness(tester)..session.enabled = true;
      await h.play('a', 'Song');
      await h.lock(true);
      await h.elapse(1.5);
      expect(h.os.titles.last, 'First line');

      h.session.setMediaItem(_item('a', 'Song'));
      await h.flush();
      expect(h.os.titles.last, 'First line');
      await h.close();
      expect(h.os.titles.last, 'Song');
    });

    testWidgets('changes the title at most twice a second', (tester) async {
      final h = _Harness(tester)..session.enabled = true;
      await h.lock(true);
      h.session.setMediaItem(_item('a', 'Song'));
      h.session.setState(_state(h.now, position: 2));
      // The lyrics load, then the line waits out the title just sent.
      await h.flush();
      expect(h.os.titles, ['Song']);
      await h.elapse(0.5);
      expect(h.os.titles, ['Song', 'First line']);

      // Into the break and on to the next line, at once.
      h.session.setState(_state(h.now, position: 25));
      h.session.setState(_state(h.now, position: 5));
      await h.flush();
      expect(h.os.titles, ['Song', 'First line']);
      await h.elapse(0.5);
      expect(h.os.titles, ['Song', 'First line', 'Second line']);
      await h.close();
    });

    testWidgets('restates the position before each change for iOS', (
      tester,
    ) async {
      final h = _Harness(tester, restatePosition: true)..session.enabled = true;
      await h.play('a', 'Song');
      await h.lock(true);
      await h.elapse(1);

      final requests = h.os.requests;
      final item = requests.last as SetMediaItemRequest;
      expect(item.mediaItem.title, 'First line');
      expect(item.mediaItem.artist, 'Artist');
      final state = (requests[requests.length - 2] as SetStateRequest).state;
      expect(state.updateTime, h.now);
      expect(state.updatePosition, _seconds(1));
      expect(state.playing, isTrue);
      await h.close();
    });
  });
}
