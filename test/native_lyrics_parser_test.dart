import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyrics_parser.dart';

Map<String, dynamic> _word(LyricWord value) => {
  'timeMs': value.time.inMilliseconds,
  'endMs': value.end?.inMilliseconds,
  'text': value.text,
};

Map<String, dynamic> _dto(ParsedLyrics value) => {
  'synced': value.synced,
  'wordSynced': value.wordSynced,
  'plainText': value.plainText,
  'writers': value.writers,
  'provider': value.provider,
  'lines': [
    for (final line in value.lines)
      {
        'timeMs': line.time.inMilliseconds,
        'endMs': line.end?.inMilliseconds,
        'text': line.text,
        'words': line.words.map(_word).toList(),
        'romanization': line.romanization,
        'romanizationWords': line.romanizationWords.map(_word).toList(),
        'translation': line.translation,
        // The native parser sends it only for lines that have it.
        if (line.translationWords.isNotEmpty)
          'translationWords': line.translationWords.map(_word).toList(),
        'voice': line.voice == null
            ? null
            : {
                'id': line.voice!.id,
                'index': line.voice!.index,
                'isGroup': line.voice!.isGroup,
              },
        'isBackground': line.isBackground,
        'vocalGroup': line.vocalGroup,
      },
  ],
};

/// Word-synced TTML of at least [chars] characters.
String _ttml(int chars) {
  String clock(int ms) => '${(ms / 1000).toStringAsFixed(3)}s';
  final out = StringBuffer('<tt xmlns="http://www.w3.org/ns/ttml"><body>');
  for (var line = 0; out.length < chars; line++) {
    final start = line * 4000;
    out.write('<p begin="${clock(start)}" end="${clock(start + 4000)}">');
    for (var word = 0; word < 7; word++) {
      final at = start + word * 500;
      out.write(
        '<span begin="${clock(at)}" end="${clock(at + 500)}">'
        'word$line-$word </span>',
      );
    }
    out.write('</p>');
  }
  out.write('</body></tt>');
  return out.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures =
      (jsonDecode(
                File(
                  'test/fixtures/native_lyrics_parsers.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final fixture in fixtures) {
    test('native DTO and fallback preserve ${fixture['name']}', () async {
      final request = fixture['request'] as Map<String, dynamic>;
      final raw = request['raw'] as String;
      final expected = fixture['expected'] as Map;
      expect(_dto(LyricsParser.parse(raw)), expected);
      // With no native host, the production async caller uses its isolated
      // compatibility parser and preserves the same public models.
      expect(_dto(await LyricsParser.parseAsyncNative(raw)), expected);
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final args = call.arguments as Map;
        final request = jsonDecode(args['request_json'] as String) as Map;
        expect(request['operation'], 'parse_lyrics');
        expect(args['bytes'] as Uint8List, utf8.encode(raw));
        calls++;
        return jsonEncode(expected);
      });
      try {
        expect(_dto(await LyricsParser.parseAsyncNative(raw)), expected);
        expect(calls, raw.isEmpty ? 0 : 1);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }

  test('deep valid TTML uses the isolated compatibility parser', () async {
    final raw =
        '<tt xmlns="http://www.w3.org/ns/ttml"><body><p begin="1s" end="3s">'
        '${List.filled(18, '<span>').join()}'
        '<span begin="1s">First </span><span begin="2s">second</span>'
        '${List.filled(18, '</span>').join()}</p></body></tt>';
    final expected = LyricsParser.parse(raw);
    expect(expected.lines.single.text, 'First second');
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'runNativeDataJob');
      calls++;
      throw PlatformException(
        code: 'data_job_error',
        message: 'XML nesting exceeds 16 elements',
      );
    });
    try {
      expect(_dto(await LyricsParser.parseAsyncNative(raw)), _dto(expected));
      expect(calls, 1);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('a real native parser failure is not retried as Dart success', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'data_job_error',
        message: 'Invalid lyric document',
      );
    });
    try {
      await expectLater(
        LyricsParser.parseAsyncNative('[00:01]Line'),
        throwsA(isA<PlatformException>()),
      );
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  void answerWith(ParsedLyrics expected) {
    final json = jsonEncode(_dto(expected));
    messenger.setMockMethodCallHandler(channel, (_) async => json);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  // Widget tests run on fake time, where isolate work cannot finish until
  // runAsync: what finishes on a pump stayed on the calling isolate.
  testWidgets('small lyrics parse without an isolate hop', (tester) async {
    final raw = _ttml(LyricsParser.inlineNativeParseChars - 1024);
    final expected = LyricsParser.parse(raw);
    answerWith(expected);
    ParsedLyrics? parsed;
    LyricsParser.parseAsyncNative(raw).then((value) => parsed = value);
    await tester.pump();
    expect(parsed, isNotNull);
    expect(_dto(parsed!), _dto(expected));
  });

  testWidgets('large lyrics parse off the calling isolate', (tester) async {
    final raw = _ttml(LyricsParser.inlineNativeParseChars + 1024);
    answerWith(LyricsParser.parse(raw));
    ParsedLyrics? parsed;
    LyricsParser.parseAsyncNative(raw).then((value) => parsed = value);
    await tester.pump();
    expect(parsed, isNull);
  });

  test('large lyrics parse to the same result', () async {
    final raw = _ttml(LyricsParser.inlineNativeParseChars + 1024);
    final expected = LyricsParser.parse(raw);
    answerWith(expected);
    expect(_dto(await LyricsParser.parseAsyncNative(raw)), _dto(expected));
  });

  test('lyrics at the inline limit parse well within a frame', () async {
    final raw = _ttml(LyricsParser.inlineNativeParseChars);
    answerWith(LyricsParser.parse(raw));
    final times = <int>[];
    for (var i = 0; i < 9; i++) {
      final watch = Stopwatch()..start();
      await LyricsParser.parseAsyncNative(raw);
      times.add(watch.elapsedMicroseconds);
    }
    times.sort();
    // About 2 ms here, most of it the JSON decode the bridge always does
    // inline at this size; encoding and rebuilding take about 0.4 ms.
    expect(times[times.length ~/ 2], lessThan(16000));
  });
}
