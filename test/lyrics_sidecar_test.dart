import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/lyric_supplement_tags.dart';
import 'package:mornye/utils/lyrics_parser.dart';

String _encoded(String text) => base64.encode(utf8.encode(text));

Future<ParsedLyrics> _parse(String? raw) async => LyricsParser.parse(raw);

const _translationWords = '<00:01.00>Hola <00:01.40>mundo<00:02.00>';

ParsedLyrics _translated(ParsedLyrics lyrics, List<String?> translations) =>
    applyLyricsTranslation(
      lyrics,
      LyricsTranslationSource.of(lyrics),
      translations,
    );

class _MemorySidecar extends LyricsSidecarStore {
  _MemorySidecar({this.writable = true});

  final bool writable;
  final files = <String, String>{};

  @override
  bool canWrite(String source) => writable;

  @override
  Future<String?> read(String source) async => files[source];

  @override
  Future<void> write(String source, String content) async =>
      files[source] = content;
}

class _Events extends SourceMetadataEvents {
  final published = <String>[];

  @override
  Future<void> publish(String source) async => published.add(source);
}

const _source = '/music/Album/Song.flac';

const _item = MediaItem(
  id: _source,
  title: 'Song',
  artist: 'Artist',
  extras: {'source': _source},
);

void main() {
  group('format', () {
    test('sits next to the song', () {
      expect(mlrcPathFor('/music/Album/Song.flac'), '/music/Album/Song.mlrc');
      expect(mlrcPathFor('/music/Album/Song'), '/music/Album/Song.mlrc');
    });

    test('keeps synced LRC as written and adds what is shown', () async {
      const raw = '[ti:Song]\n[00:01.00]Hola\n[00:02.00]Mundo';
      final shown = _translated(LyricsParser.parse(raw), ['Hello', 'World']);
      final mlrc = buildMlrc(raw: raw, shown: shown);
      expect(
        mlrc,
        '[x-mlrc:2]\n'
        '[ti:Song]\n'
        '[00:01.00]Hola\n'
        '[x-translated:1000:Hello]\n'
        '[00:02.00]Mundo\n'
        '[x-translated:2000:World]\n',
      );
      final read = await readMlrc(mlrc, _parse);
      expect(read.lines.map((line) => line.translation), ['Hello', 'World']);
    });

    test('writes TTML lyrics as enhanced LRC with their voices', () async {
      final shown = ParsedLyrics(
        synced: true,
        wordSynced: true,
        lines: const [
          LyricLine(
            time: Duration(seconds: 1),
            end: Duration(seconds: 2),
            text: 'Hello world',
            words: [
              LyricWord(time: Duration(seconds: 1), text: 'Hello'),
              LyricWord(
                time: Duration(milliseconds: 1500),
                end: Duration(seconds: 2),
                text: 'world',
              ),
            ],
            voice: LyricVoice(id: 'v2', index: 1, isGroup: false),
            translation: 'Hola mundo',
            translationWords: [
              LyricWord(
                time: Duration(seconds: 1),
                end: Duration(milliseconds: 1400),
                text: 'Hola ',
              ),
              LyricWord(
                time: Duration(milliseconds: 1400),
                end: Duration(seconds: 2),
                text: 'mundo',
              ),
            ],
            romanization: 'Hello world',
          ),
          LyricLine(
            time: Duration(milliseconds: 1200),
            text: 'ooh',
            words: [
              LyricWord(
                time: Duration(milliseconds: 1200),
                end: Duration(milliseconds: 1600),
                text: 'ooh',
              ),
            ],
            isBackground: true,
          ),
        ],
        plainText: 'Hello world\nooh',
      );
      final mlrc = buildMlrc(
        raw: '<tt xmlns="http://www.w3.org/ns/ttml"><body/></tt>',
        shown: shown,
      );
      expect(
        mlrc,
        '[x-mlrc:2]\n'
        '[00:01.00]v2: <00:01.00>Hello <00:01.50>world<00:02.00>\n'
        '[x-romanized:1000:Hello world]\n'
        '[x-translated-words:1000:$_translationWords]\n'
        '[x-translated:1000:Hola mundo]\n'
        '[bg:<00:01.20>ooh<00:01.60>]\n',
      );
      final read = await readMlrc(mlrc, _parse);
      expect(read.synced, isTrue);
      expect(read.lines.first.voice?.index, 1);
      expect(read.lines.first.words.map((word) => word.text.trim()), [
        'Hello',
        'world',
      ]);
      expect(read.lines.first.translation, 'Hola mundo');
      expect(
        encodeLyricWordsTag(read.lines.first.translationWords),
        _translationWords,
      );
      expect(read.lines.last.isBackground, isTrue);
    });

    test('keys the lines of lyrics without timing by index', () async {
      final shown = _translated(
        const ParsedLyrics(
          synced: false,
          wordSynced: false,
          lines: [],
          plainText: 'Hola\n\nMundo',
        ),
        ['Hello', 'World'],
      );
      final mlrc = buildMlrc(raw: 'Hola\n\nMundo', shown: shown);
      expect(
        mlrc,
        '[x-mlrc:2]\n'
        'Hola\n'
        '[x-translated:0:Hello]\n'
        'Mundo\n'
        '[x-translated:1:World]\n',
      );
      final read = await readMlrc(mlrc, _parse);
      expect(read.synced, isFalse);
      expect(read.plainText, 'Hola\nMundo');
      expect(read.lines.map((line) => line.translation), ['Hello', 'World']);
    });
  });

  group('merge', () {
    test('lays saved lines over the song by text', () {
      final song = LyricsParser.parse(
        '[00:01.00]Hola\n'
        '[x-translation:1000:${_encoded('Provider')}]\n'
        '[00:02.00]Mundo\n'
        '[00:03.00]Otra',
      );
      final saved = LyricsParser.parse(
        '[00:01.00]Hola\n'
        '[x-translation-words:1000:${_encoded(jsonEncode([
          {'text': 'Hel', 'startTimeMs': 1000, 'endTimeMs': 1300},
          {'text': 'lo', 'startTimeMs': 1300, 'endTimeMs': 1600},
        ]))}]\n'
        '[x-translation:1000:${_encoded('Hello')}]\n'
        '[00:09.00]Mundo\n'
        '[x-translation-words:9000:${_encoded(jsonEncode([
          {'text': 'World', 'startTimeMs': 9000, 'endTimeMs': 9400},
        ]))}]\n'
        '[x-translation:9000:${_encoded('World')}]\n'
        '[x-romaji-words:9000:${_encoded(jsonEncode([
          {'text': 'mun', 'startTimeMs': 9000, 'endTimeMs': 9200},
        ]))}]\n'
        '[x-romaji:9000:${_encoded('mun')}]',
      );
      final merged = mergeSavedLyrics(song, saved);
      expect(merged.lines.map((line) => line.translation), [
        'Hello',
        'World',
        null,
      ]);
      expect(merged.lines.first.translationWords.map((word) => word.text), [
        'Hel',
        'lo',
      ]);
      expect(merged.lines[1].romanization, 'mun');
      // Word timing from another time does not fit this line.
      expect(merged.lines[1].romanizationWords, isEmpty);
      expect(merged.lines[1].translationWords, isEmpty);
      expect(mergeSavedLyrics(song, null), same(song));
      expect(mergeSavedLyrics(ParsedLyrics.empty, saved), same(saved));
    });

    test('gives plain lyrics lines with saved translations', () {
      const song = ParsedLyrics(
        synced: false,
        wordSynced: false,
        lines: [],
        plainText: 'Hola\nMundo',
      );
      final saved = _translated(song, ['Hello', null]);
      final merged = mergeSavedLyrics(song, saved);
      expect(merged.synced, isFalse);
      expect(merged.plainText, 'Hola\nMundo');
      expect(merged.lines.map((line) => line.translation), ['Hello', null]);
    });
  });

  group('store', () {
    tearDown(() => debugDesktopPlatformOverride = null);

    test('writes and reads the file next to a local song', () async {
      final dir = await Directory.systemTemp.createTemp('mlrc_store_');
      addTearDown(() => dir.delete(recursive: true));
      final song = p.join(dir.path, 'Song.flac');
      const store = LyricsSidecarStore();
      expect(store.canWrite(song), isTrue);
      expect(await store.read(song), isNull);
      await store.write(song, '[x-mlrc:1]\nHola\n');
      expect(
        await File(p.join(dir.path, 'Song.mlrc')).readAsString(),
        '[x-mlrc:1]\nHola\n',
      );
      expect(await store.read(song), '[x-mlrc:1]\nHola\n');
      expect(dir.listSync().map((entry) => p.basename(entry.path)), [
        'Song.mlrc',
      ]);
    });

    test('reads the .lrc file next to a local song', () async {
      final dir = await Directory.systemTemp.createTemp('lrc_store_');
      addTearDown(() => dir.delete(recursive: true));
      final song = p.join(dir.path, 'Song.wav');
      const store = LyricsSidecarStore(extension: lrcExtension);
      expect(await store.read(song), isNull);
      await File(p.join(dir.path, 'Song.lrc')).writeAsString('[00:01.00]Hola');
      expect(await store.read(song), '[00:01.00]Hola');
      await store.write(song, '[00:01.00]Adios');
      expect(
        await File(p.join(dir.path, 'Song.lrc')).readAsString(),
        '[00:01.00]Adios',
      );
    });

    test('has none for network songs, CUE tracks and streams', () {
      const store = LyricsSidecarStore();
      expect(store.canWrite('network://share/Song.flac'), isFalse);
      expect(store.canWrite('/music/Album.flac#track01'), isFalse);
      expect(store.canWrite('https://example.com/song.flac'), isFalse);
      debugDesktopPlatformOverride = true;
      expect(store.canWrite('content://docs/tree/a/document/b'), isFalse);
      debugDesktopPlatformOverride = false;
      expect(store.canWrite('content://docs/tree/a/document/b'), isTrue);
    });
  });

  group('player', () {
    PlayerMetadataController controller({
      required String lyrics,
      required _MemorySidecar sidecar,
      required List<String> saved,
      required _Events events,
      _MemorySidecar? lrcFile,
    }) => PlayerMetadataController(
      readMetadata: (path) async => {if (lyrics.isNotEmpty) 'lyrics': lyrics},
      parseLyrics: _parse,
      saveOnlineLyrics: (source, raw) async => saved.add(raw),
      metadataEvents: events,
      sidecar: sidecar,
      lrcFile: lrcFile ?? _MemorySidecar(),
    );

    test('shows the .lrc file of a song without lyrics of its own', () async {
      final lrcFile = _MemorySidecar()
        ..files[_source] =
            '[00:01.00]Hola\n[00:01.00]Hello\n'
            '[00:02.00]Mundo\n[00:02.00]World';
      final metadata = controller(
        lyrics: '',
        sidecar: _MemorySidecar(),
        saved: [],
        events: _Events(),
        lrcFile: lrcFile,
      );
      addTearDown(metadata.dispose);
      await metadata.load(_item);
      await pumpEventQueue();
      expect(metadata.rawLyrics, lrcFile.files[_source]);
      // A bilingual file shows each second line as the translation.
      expect(
        metadata.lyrics.lines.map((line) => (line.text, line.translation)),
        [('Hola', 'Hello'), ('Mundo', 'World')],
      );
    });

    test('the song\'s own lyrics win over its .lrc file', () async {
      final lrcFile = _MemorySidecar()..files[_source] = '[00:01.00]Other';
      final metadata = controller(
        lyrics: '[00:01.00]Own',
        sidecar: _MemorySidecar(),
        saved: [],
        events: _Events(),
        lrcFile: lrcFile,
      );
      addTearDown(metadata.dispose);
      await metadata.load(_item);
      await pumpEventQueue();
      expect(metadata.rawLyrics, '[00:01.00]Own');
    });

    test('translations and edits of .lrc lyrics go back to the .lrc '
        'file', () async {
      final lrcFile = _MemorySidecar()..files[_source] = '[00:01.00]Hola';
      final saved = <String>[];
      final metadata = controller(
        lyrics: '',
        sidecar: _MemorySidecar(),
        saved: saved,
        events: _Events(),
        lrcFile: lrcFile,
      );
      addTearDown(metadata.dispose);
      await metadata.load(_item);
      await pumpEventQueue();
      final target = await metadata.saveShownLyrics(
        _translated(metadata.lyrics, ['Hello']),
        preferSidecar: false,
      );
      const tagged = '[00:01.00]Hola\n[x-translated:1000:Hello]';
      expect(target, LyricsSaveTarget.songFile);
      expect(lrcFile.files[_source], tagged);
      expect(metadata.rawLyrics, tagged);

      final edit = metadata.beginLyricsEdit()!;
      expect(edit.inLrcFile, isTrue);
      await metadata.saveEditedLyrics('[00:01.00]Adios', edit: edit);
      expect(lrcFile.files[_source], '[00:01.00]Adios');
      expect(metadata.lyrics.lines.single.text, 'Adios');
      expect(saved, isEmpty);
    });

    // Version 1 files, with base64 tags, are still read.
    test('shows what the .mlrc file saved over the song', () async {
      final sidecar = _MemorySidecar()
        ..files[_source] =
            '[x-mlrc:1]\n[00:01.00]Hola\n'
            '[x-translation:1000:${_encoded('Hello')}]\n';
      final metadata = controller(
        lyrics: '[00:01.00]Hola',
        sidecar: sidecar,
        saved: [],
        events: _Events(),
      );
      addTearDown(metadata.dispose);
      await metadata.load(_item);
      await pumpEventQueue();
      expect(metadata.rawLyrics, '[00:01.00]Hola');
      expect(metadata.lyrics.lines.single.translation, 'Hello');
    });

    test('shows the .mlrc lyrics of a song without its own', () async {
      final sidecar = _MemorySidecar()
        ..files[_source] =
            '[x-mlrc:1]\nHola\n[x-translation:0:${_encoded('Hello')}]\n';
      final metadata = controller(
        lyrics: '',
        sidecar: sidecar,
        saved: [],
        events: _Events(),
      );
      addTearDown(metadata.dispose);
      await metadata.load(_item);
      await pumpEventQueue();
      expect(metadata.lyrics.plainText, 'Hola');
      expect(metadata.lyrics.lines.single.translation, 'Hello');
    });

    for (final preferSidecar in [false, true]) {
      test('saves synced LRC to the '
          '${preferSidecar ? '.mlrc file' : 'song file'}', () async {
        final sidecar = _MemorySidecar();
        final saved = <String>[];
        final events = _Events();
        final metadata = controller(
          lyrics: '[00:01.00]Hola',
          sidecar: sidecar,
          saved: saved,
          events: events,
        );
        addTearDown(metadata.dispose);
        await metadata.load(_item);
        await pumpEventQueue();
        expect(metadata.canSaveTranslations, isTrue);
        final target = await metadata.saveShownLyrics(
          _translated(metadata.lyrics, ['Hello']),
          preferSidecar: preferSidecar,
        );
        const tagged = '[00:01.00]Hola\n[x-translated:1000:Hello]';
        if (preferSidecar) {
          expect(target, LyricsSaveTarget.sidecar);
          expect(saved, isEmpty);
          expect(sidecar.files[_source], '[x-mlrc:2]\n$tagged\n');
          expect(metadata.rawLyrics, '[00:01.00]Hola');
        } else {
          expect(target, LyricsSaveTarget.songFile);
          expect(saved, [tagged]);
          expect(sidecar.files, isEmpty);
          expect(metadata.rawLyrics, tagged);
        }
        expect(events.published, [_source]);
        expect(metadata.lyrics.lines.single.translation, 'Hello');
      });
    }

    test('keeps an existing .mlrc file in step with the song file', () async {
      final sidecar = _MemorySidecar()
        ..files[_source] =
            '[x-mlrc:1]\n[00:01.00]Hola\n'
            '[x-translation:1000:${_encoded('Old')}]\n';
      final saved = <String>[];
      final metadata = controller(
        lyrics: '[00:01.00]Hola',
        sidecar: sidecar,
        saved: saved,
        events: _Events(),
      );
      addTearDown(metadata.dispose);
      await metadata.load(_item);
      await pumpEventQueue();
      expect(metadata.lyrics.lines.single.translation, 'Old');
      await metadata.saveShownLyrics(
        _translated(metadata.lyrics, ['New']),
        preferSidecar: false,
      );
      const tagged = '[00:01.00]Hola\n[x-translated:1000:New]';
      expect(saved, [tagged]);
      expect(sidecar.files[_source], '[x-mlrc:2]\n$tagged\n');
      expect(metadata.lyrics.lines.single.translation, 'New');
    });

    test('plain lyrics go to a .mlrc file or cannot be saved', () async {
      for (final writable in [true, false]) {
        final sidecar = _MemorySidecar(writable: writable);
        final saved = <String>[];
        final metadata = controller(
          lyrics: 'Hola',
          sidecar: sidecar,
          saved: saved,
          events: _Events(),
        );
        addTearDown(metadata.dispose);
        await metadata.load(_item);
        await pumpEventQueue();
        final shown = _translated(metadata.lyrics, ['Hello']);
        if (writable) {
          expect(
            await metadata.saveShownLyrics(shown, preferSidecar: false),
            LyricsSaveTarget.sidecar,
          );
          expect(
            sidecar.files[_source],
            '[x-mlrc:2]\nHola\n[x-translated:0:Hello]\n',
          );
          expect(metadata.lyrics.lines.single.translation, 'Hello');
        } else {
          expect(metadata.canSaveTranslations, isFalse);
          await expectLater(
            metadata.saveShownLyrics(shown, preferSidecar: true),
            throwsA(isA<LyricsSaveUnsupported>()),
          );
        }
        expect(saved, isEmpty);
      }
    });
  });
}
