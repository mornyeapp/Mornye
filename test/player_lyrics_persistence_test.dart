import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Map<String, dynamic>> edits;
  late Map<String, dynamic> response;

  setUp(() {
    edits = [];
    response = {'success': true, 'method': 'native'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'editFileMetadata') {
        edits.add(Map<String, dynamic>.from(call.arguments as Map));
        return response;
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final source in [
    '/music/song.flac',
    '/music/song.mp3',
    '/music/song.m4a',
    '/music/song.opus',
    '/music/song.ogg',
    r'C:\Music\song.flac',
    r'\\nas\Music\song.mp3',
    'content://example.documents/document/song.mp3',
  ]) {
    test(
      'embeds only lyrics through the native file editor: $source',
      () async {
        const lyrics = '[ar:Artist]\n[00:01.00]Found';
        await persistPlayerLyrics(source, lyrics);
        expect(edits.single['file_path'], source);
        expect(jsonDecode(edits.single['metadata_json'] as String), {
          'lyrics': lyrics,
          'artist_tag_mode': 'joined',
          'cover_path': '',
        });
      },
    );
  }

  test('file URIs are written as local paths', () async {
    await persistPlayerLyrics('file:///music/Song%20One.flac', 'Lyrics');
    expect(edits.single['file_path'], '/music/Song One.flac');
  });

  for (final source in [
    'https://audio.example/song.mp3',
    'http://audio.example/song.mp3',
    'link-phone:example/song.flac',
    'relative/song.mp3',
    '',
  ]) {
    test('read-only or unresolved source never writes tags: $source', () async {
      await expectLater(
        persistPlayerLyrics(source, 'Lyrics'),
        throwsUnsupportedError,
      );
      expect(edits, isEmpty);
    });
  }

  for (final failure in [
    {'error': 'File is read only'},
    {'success': false},
  ]) {
    test(
      'native write rejection is not reported as a save: $failure',
      () async {
        response = failure;
        await expectLater(
          persistPlayerLyrics('/music/song.flac', 'Lyrics'),
          throwsA(anything),
        );
      },
    );
  }
}
