import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/motion_artwork_folder.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyrics_parser.dart';

const _channel = MethodChannel('com.zarz.mornye/backend');
const _listings = {'readSafSidecar', 'findSafSibling', 'findSafSiblings'};

String _encoded(String text) => base64.encode(utf8.encode(text));

Future<ParsedLyrics> _parse(String? raw) async => LyricsParser.parse(raw);

/// An Android document folder: the files beside one song, by name, as the
/// old per-file calls and the one folder listing both answer them.
class _Folder {
  _Folder(this.song, this.base);

  final String song;
  final String base;
  final files = <String, String>{};
  final calls = <String>[];

  String _uri(String name) => '$song/sibling/$name';

  Map<String, Object> _entry(String name) => {
    'uri': _uri(name),
    'size': utf8.encode(files[name]!).length,
    'modified': 1,
  };

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'readSafSidecar':
        return files['$base.${args['extension']}'];
      case 'findSafSibling':
        final name = args['name'] as String;
        return files.containsKey(name) ? _entry(name) : null;
      case 'findSafSiblings':
        return {
          'sidecars': {
            for (final extension in args['extensions'] as List)
              if (files.containsKey('$base.$extension'))
                extension: _entry('$base.$extension'),
          },
          'files': {
            for (final name in (args['names'] as List).cast<String>())
              if (files.containsKey(name)) name: _entry(name),
          },
        };
      case 'readSafText':
        final uri = args['uri'] as String;
        final name = uri.substring(uri.lastIndexOf('/') + 1);
        return uri == _uri(name) ? files[name] : null;
      case 'writeSafSidecar':
        files['$base.${args['extension']}'] = args['content'] as String;
        return true;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    debugDesktopPlatformOverride = false;
    root = await Directory.systemTemp.createTemp('saf-siblings-');
  });

  tearDown(() async {
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(_channel, null);
    await root.delete(recursive: true);
  });

  _Folder folder(String id) {
    final folder = _Folder('content://tree/a/document/$id', 'Song');
    messenger.setMockMethodCallHandler(_channel, folder.handle);
    return folder;
  }

  MediaItem item(String song) => MediaItem(
    id: song,
    title: 'Song',
    artist: 'Artist',
    extras: {'source': song, 'resolvedSource': '/cache/Song.flac'},
  );

  PlayerMetadataController controller({
    String lyrics = '',
    SourceMetadataEvents? events,
  }) {
    final metadata = PlayerMetadataController(
      readMetadata: (path) async => {if (lyrics.isNotEmpty) 'lyrics': lyrics},
      parseLyrics: _parse,
      saveOnlineLyrics: (source, raw) async {},
      metadataEvents: events ?? SourceMetadataEvents(),
    );
    addTearDown(metadata.dispose);
    return metadata;
  }

  MotionArtworkFolder motion() => MotionArtworkFolder(
    directory: () async => root,
    documents: true,
    copyDocument: (uri) async {
      final copy = File(p.join(root.path, 'copy.mp4'));
      await copy.writeAsBytes([1, 2]);
      return copy.path;
    },
  );

  test('a song start lists the song\'s folder once for its lyrics files and '
      'its animated cover', () async {
    final songFolder = folder('start')
      ..files['Song.lrc'] = '[00:01.00]Hola\n[00:02.00]Mundo'
      ..files['Song.mlrc'] =
          '[x-mlrc:1]\n'
          '[00:01.00]Hola\n'
          '[x-translation:1000:${_encoded('Hello')}]\n'
          '[00:02.00]Mundo\n'
      ..files[motionArtworkFileName] = 'mp';
    final metadata = controller();
    final song = songFolder.song;
    final (_, cover) = await (
      metadata.load(item(song)),
      motion().find(song),
    ).wait;
    await pumpEventQueue();

    expect(songFolder.calls.where(_listings.contains), hasLength(1));
    // The .lrc file stands in for the song's missing lyrics and the .mlrc
    // file lays its translation over them.
    expect(metadata.rawLyrics, songFolder.files['Song.lrc']);
    expect(metadata.lyrics.lines.map((line) => (line.text, line.translation)), [
      ('Hola', 'Hello'),
      ('Mundo', null),
    ]);
    expect(cover, isNotNull);
    expect(File.fromUri(Uri.parse(cover!.source)).readAsBytesSync(), [1, 2]);
  });

  test('a song with lyrics of its own and no files beside it asks its '
      'folder once', () async {
    final songFolder = folder('own');
    final metadata = controller(lyrics: '[00:01.00]Own');
    final song = songFolder.song;
    final (_, cover) = await (
      metadata.load(item(song)),
      motion().find(song),
    ).wait;
    await pumpEventQueue();

    expect(songFolder.calls.where(_listings.contains), hasLength(1));
    expect(metadata.rawLyrics, '[00:01.00]Own');
    expect(metadata.lyrics.lines.single.translation, isNull);
    expect(cover, isNull);
  });

  test('a saved .mlrc file is read again right after it is written', () async {
    final songFolder = folder('write');
    final song = songFolder.song;
    const store = LyricsSidecarStore();
    expect(await store.read(song), isNull);
    await store.write(song, '[x-mlrc:1]\nHola\n');
    expect(await store.read(song), '[x-mlrc:1]\nHola\n');
  });

  test('changed tags read the song\'s .lrc file again', () async {
    final songFolder = folder('tags');
    final events = SourceMetadataEvents();
    final metadata = controller(events: events);
    final song = songFolder.song;
    await metadata.load(item(song));
    await pumpEventQueue();
    expect(metadata.rawLyrics, isEmpty);

    songFolder.files['Song.lrc'] = '[00:01.00]Hola';
    await events.publish(song);
    await pumpEventQueue();
    expect(metadata.rawLyrics, '[00:01.00]Hola');
  });
}
