import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/lyrics_parser.dart';

MediaItem _item(
  String id, {
  String? source,
  String? resolved,
  Map<String, dynamic> metadata = const {},
}) => MediaItem(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  extras: {
    'source': source ?? '/music/$id.flac',
    'resolvedSource': ?resolved,
    ...metadata,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'file changes refresh cached lyrics and tags without changing tracks',
    () async {
      final events = SourceMetadataEvents();
      var reads = 0;
      final controller = PlayerMetadataController(
        metadataEvents: events,
        readMetadata: (_) async => {
          'title': 'Title ${++reads}',
          'lyrics': '[00:01]Verse $reads',
          'replaygain_track_gain': '-$reads dB',
        },
      );
      await controller.load(_item('a'));
      expect(controller.lyrics.lines.single.text, 'Verse 1');
      await events.publish('/other.flac');
      expect(reads, 1);
      await events.publish('/music/a.flac');
      expect(controller.metadata!['title'], 'Title 2');
      expect(controller.lyrics.lines.single.text, 'Verse 2');
      expect(controller.metadata!['replaygain_track_gain'], '-2 dB');
      controller.dispose();
      await events.publish('/music/a.flac');
      expect(reads, 2);
    },
  );

  test(
    'new metadata is visible immediately while lyrics parse is pending',
    () async {
      final parse = Completer<ParsedLyrics>();
      final controller = PlayerMetadataController(
        readMetadata: (path) async => path.endsWith('a.flac')
            ? {'lyrics': '[00:01]Old', 'format': 'MP3'}
            : {'lyrics': '[00:01]New', 'format': 'FLAC', 'bit_depth': 24},
        parseLyrics: (raw) => raw == '[00:01]Old'
            ? Future.value(LyricsParser.parse(raw))
            : parse.future,
      );
      addTearDown(controller.dispose);
      await controller.load(_item('a'));
      expect(controller.lyrics.lines.single.text, 'Old');
      final pending = controller.load(_item('b', metadata: {'format': 'AAC'}));
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.qualityLabel, 'AAC');
      await Future<void>.delayed(Duration.zero);
      expect(controller.qualityLabel, 'FLAC  ·  24-bit');
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.loading, isTrue);
      parse.complete(LyricsParser.parse('[00:01]New'));
      await pending;
      expect(controller.lyrics.lines.single.text, 'New');
      expect(controller.loading, isFalse);
    },
  );

  test(
    'failed native lyrics retain new quality metadata and clear loading',
    () async {
      final controller = PlayerMetadataController(
        readMetadata: (_) async => {'lyrics': '[00:01]Text', 'format': 'FLAC'},
        parseLyrics: (_) async => throw StateError('Invalid native lyrics'),
      );
      addTearDown(controller.dispose);
      await controller.load(_item('a'));
      expect(controller.qualityLabel, 'FLAC');
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.loading, isFalse);
    },
  );

  test(
    'late native lyrics cannot publish after switching away and back',
    () async {
      final parses = <String, Completer<ParsedLyrics>>{};
      final controller = PlayerMetadataController(
        readMetadata: (path) async => {'lyrics': path},
        parseLyrics: (raw) => (parses[raw!] = Completer<ParsedLyrics>()).future,
      );
      addTearDown(controller.dispose);
      final first = controller.load(_item('a'));
      await Future<void>.delayed(Duration.zero);
      final oldParse = parses['/music/a.flac']!;
      final second = controller.load(_item('b'));
      await Future<void>.delayed(Duration.zero);
      final current = controller.load(_item('a'));
      await Future<void>.delayed(Duration.zero);
      parses['/music/a.flac']!.complete(LyricsParser.parse('[00:01]Current A'));
      await current;
      oldParse.complete(LyricsParser.parse('[00:01]Old A'));
      parses['/music/b.flac']!.complete(LyricsParser.parse('[00:01]Old B'));
      await Future.wait([first, second]);
      expect(controller.lyrics.lines.single.text, 'Current A');
      expect(controller.loading, isFalse);
    },
  );

  test(
    'disposal while native lyrics parse is pending never publishes',
    () async {
      final parse = Completer<ParsedLyrics>();
      final controller = PlayerMetadataController(
        readMetadata: (_) async => {'lyrics': '[00:01]Late'},
        parseLyrics: (_) => parse.future,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.load(_item('a'));
      await Future<void>.delayed(Duration.zero);
      final beforeDispose = notifications;
      controller.dispose();
      parse.complete(LyricsParser.parse('[00:01]Late'));
      await pending;
      expect(notifications, beforeDispose);
      expect(controller.lyrics.isEmpty, isTrue);
    },
  );
  test('late result cannot overwrite a track switched away and back', () async {
    final reads = <Completer<Map<String, dynamic>>>[];
    final controller = PlayerMetadataController(
      readMetadata: (_) {
        final read = Completer<Map<String, dynamic>>();
        reads.add(read);
        return read.future;
      },
    );
    addTearDown(controller.dispose);
    final first = controller.load(_item('a'));
    final second = controller.load(_item('b'));
    final current = controller.load(_item('a'));

    reads[2].complete({'lyrics': '[00:01.00]Current A'});
    await current;
    reads[0].complete({'lyrics': '[00:01.00]Old A'});
    reads[1].completeError(StateError('Old B failed'));
    await Future.wait([first, second]);

    expect(controller.lyrics.lines.single.text, 'Current A');
    expect(controller.loading, isFalse);
  });

  test('resolved source supersedes an outstanding content URI read', () async {
    final old = Completer<Map<String, dynamic>>();
    final paths = <String>[];
    final controller = PlayerMetadataController(
      readMetadata: (path) {
        paths.add(path);
        return path.startsWith('content://')
            ? old.future
            : Future.value({'lyrics': '[00:01.00]Resolved'});
      },
    );
    addTearDown(controller.dispose);
    final source = 'content://library/song.flac';
    final pending = controller.load(
      _item('a', source: source),
      inspectUnresolvedContentUri: true,
    );
    await controller.load(
      _item('a', source: source, resolved: '/tmp/song.flac'),
    );
    old.complete({'lyrics': '[00:01.00]Unresolved'});
    await pending;

    expect(paths, [source, '/tmp/song.flac']);
    expect(controller.lyrics.lines.single.text, 'Resolved');
  });

  test(
    'disposal prevents outstanding reads from notifying or mutating',
    () async {
      final read = Completer<Map<String, dynamic>>();
      final controller = PlayerMetadataController(
        readMetadata: (_) => read.future,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.load(_item('a'));
      final beforeDispose = notifications;
      controller.dispose();
      read.complete({'lyrics': '[00:01.00]Late'});
      await pending;
      await controller.load(_item('b'));

      expect(notifications, beforeDispose);
      expect(controller.lyrics.isEmpty, isTrue);
    },
  );

  test(
    'unresolved SAF metadata stays on demand and reads are deduplicated',
    () async {
      final read = Completer<Map<String, dynamic>>();
      final paths = <String>[];
      final controller = PlayerMetadataController(
        readMetadata: (path) {
          paths.add(path);
          return read.future;
        },
      );
      addTearDown(controller.dispose);
      final item = _item('a', source: 'content://library/a.flac');
      await controller.load(item);
      expect(paths, isEmpty);
      expect(controller.loading, isFalse);
      final pending = controller.load(item, inspectUnresolvedContentUri: true);
      await controller.load(item, inspectUnresolvedContentUri: true);
      expect(paths, [item.extras!['source']]);
      read.complete({'lyrics': '[00:01.00]Embedded'});
      await pending;
      await controller.load(item, inspectUnresolvedContentUri: true);
      expect(paths, hasLength(1));
    },
  );

  test('HTTP quality fallback avoids file probes and old lyrics', () async {
    final paths = <String>[];
    final controller = PlayerMetadataController(
      readMetadata: (path) async {
        paths.add(path);
        return {'lyrics': '[00:01.00]Local'};
      },
    );
    addTearDown(controller.dispose);
    await controller.load(_item('local'));
    final remote = _item(
      'remote',
      source: 'https://audio.test/song.mp3',
      resolved: 'https://cdn.audio.test/song.mp3',
      metadata: {'format': 'mp3', 'bitrate': 320, 'sample_rate': 44100},
    );
    expect((await controller.readDetails(remote))['title'], 'remote');
    await controller.load(remote);
    expect((await controller.readDetails(remote))['format'], 'mp3');

    expect(paths, ['/music/local.flac']);
    expect(controller.lyrics.isEmpty, isTrue);
    expect(controller.qualityLabel, 'MP3  ·  44.1 kHz  ·  320 kbps');
  });

  test(
    'network metadata uses logical source despite playback HTTP URL',
    () async {
      final paths = <String>[];
      final controller = PlayerMetadataController(
        readMetadata: (path) async {
          paths.add(path);
          return {'lyrics': '[00:01.00]Network'};
        },
      );
      addTearDown(controller.dispose);
      await controller.load(
        _item(
          'network',
          source: 'network://library/song.flac',
          resolved: 'http://127.0.0.1/playback',
        ),
      );
      expect(paths, ['network://library/song.flac']);
      expect(controller.lyrics.lines.single.text, 'Network');
    },
  );

  test('failed probes retain quality metadata and may retry', () async {
    var reads = 0;
    final controller = PlayerMetadataController(
      readMetadata: (_) async {
        if (++reads == 1) throw StateError('Temporarily unavailable');
        return {
          'lyrics': '[00:01.00]Recovered',
          'format': '',
          'sample_rate': 0,
          'lyricist': 'Writer',
          'lyrics_provider': 'Provider',
        };
      },
    );
    addTearDown(controller.dispose);
    final item = _item(
      'a',
      metadata: {'format': 'FLAC', 'sample_rate': 48000, 'bit_depth': 24},
    );
    await controller.load(item);
    expect(controller.loading, isFalse);
    expect(controller.qualityLabel, 'FLAC  ·  24-bit  ·  48 kHz');
    await controller.load(item);
    expect(controller.qualityLabel, 'FLAC  ·  24-bit  ·  48 kHz');
    expect(controller.lyrics.lines.single.text, 'Recovered');
    expect(controller.credits, (writers: 'Writer', provider: 'Provider'));
    expect(
      () => controller.metadata!['format'] = 'MP3',
      throwsUnsupportedError,
    );
  });

  test('inspecting loaded stream tags preserves online lyrics', () async {
    final controller = PlayerMetadataController(
      readMetadata: (_) async => fail('Streams must not probe a local file'),
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      fetchOnlineLyrics: (_) async => '[00:01.00]Online lyrics',
    );
    addTearDown(controller.dispose);
    await controller.load(
      _item(
        'stream',
        source: 'https://audio.test/song.opus',
        metadata: {'format': 'opus'},
      ),
    );
    await controller.searchOnline();
    await controller.ensureFileMetadata();
    expect(controller.lyrics.lines.single.text, 'Online lyrics');
    expect(controller.qualityLabel, 'OPUS');
  });

  test('details snapshot probes SAF without changing lyrics state', () async {
    final controller = PlayerMetadataController(
      readMetadata: (_) async => {
        'title': 'Tagged',
        'lyrics': '[00:01.00]Lyrics',
      },
    );
    addTearDown(controller.dispose);
    final item = _item('a', source: 'content://library/a.flac');
    await controller.load(item);
    final details = await controller.readDetails(item);
    expect(details['title'], 'Tagged');
    expect(details['artist'], 'Artist');
    expect(controller.lyrics.isEmpty, isTrue);
    expect(controller.loading, isFalse);
    await controller.load(null);
    expect(controller.source, isNull);
    expect(controller.metadata, isNull);
  });

  test(
    'failed details retain their snapshot after the track changes',
    () async {
      final read = Completer<Map<String, dynamic>>();
      final controller = PlayerMetadataController(
        readMetadata: (path) => path.startsWith('content://')
            ? read.future
            : Future.value({'lyrics': '[00:01.00]Current'}),
      );
      addTearDown(controller.dispose);
      final item = _item(
        'a',
        source: 'content://library/a.flac',
        metadata: {'format': 'FLAC'},
      );
      await controller.load(item);
      final pending = controller.readDetails(item);
      await controller.load(_item('b'));
      read.completeError(StateError('File unavailable'));

      expect(await pending, {
        'title': 'a',
        'artist': 'Artist',
        'album': 'Album',
        'format': 'FLAC',
      });
      expect(controller.lyrics.lines.single.text, 'Current');
    },
  );

  group('online lyrics search', () {
    PlayerMetadataController controllerFor(
      Future<String> Function(MediaItem) fetch, {
      OnlineLyricsSaver? save,
      PlaybackMetadataReader? read,
      SourceMetadataEvents? events,
    }) {
      final controller = PlayerMetadataController(
        readMetadata: read ?? (_) async => const {},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: fetch,
        saveOnlineLyrics: save ?? (_, _) async {},
        metadataEvents: events,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('shows provider lyrics for a file without its own', () async {
      final requested = <String>[];
      final controller = controllerFor((item) async {
        requested.add(item.title);
        return '[00:01.00]Found';
      });
      await controller.load(_item('a'));
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.canSearchOnline, isTrue);
      final search = controller.searchOnline();
      expect(controller.searchingOnline, isTrue);
      await search;
      expect(requested, ['a']);
      expect(controller.searchingOnline, isFalse);
      expect(controller.onlineSearchMissed, isFalse);
      expect(controller.lyrics.lines.single.text, 'Found');
    });

    test('a miss or failure is reported until the track changes', () async {
      var attempt = 0;
      final controller = controllerFor((_) async {
        if (attempt++ == 0) return '';
        throw StateError('offline');
      });
      await controller.load(_item('a'));
      await controller.searchOnline();
      expect(controller.onlineSearchMissed, isTrue);
      await controller.searchOnline();
      expect(controller.onlineSearchMissed, isTrue);
      expect(controller.lyrics.isEmpty, isTrue);
      await controller.load(_item('b'));
      expect(controller.onlineSearchMissed, isFalse);
    });

    test('a late result cannot replace the next track', () async {
      final result = Completer<String>();
      final controller = controllerFor((_) => result.future);
      await controller.load(_item('a'));
      final search = controller.searchOnline();
      await controller.load(_item('b'));
      expect(controller.searchingOnline, isFalse);
      result.complete('[00:01.00]Old track');
      await search;
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.onlineSearchMissed, isFalse);
    });

    test(
      'embeds raw timed lyrics and reloads them without another search',
      () async {
        const raw = '[ar:Artist]\n[00:01.00]Found\n[00:02.00]Offline';
        final stored = <String, String>{};
        final events = SourceMetadataEvents();
        final changes = <String>[];
        final unsubscribe = events.subscribe(
          (source) async => changes.add(source),
        );
        addTearDown(unsubscribe);
        var fetches = 0;
        Future<Map<String, dynamic>> read(String path) async => {
          'lyrics': stored[path] ?? '',
          'format': 'FLAC',
        };
        final controller = controllerFor(
          (_) async {
            fetches++;
            return raw;
          },
          read: read,
          save: (source, lyrics) async {
            stored[source] = lyrics;
          },
          events: events,
        );
        await controller.load(_item('a'));
        await controller.searchOnline();
        expect(stored, {'/music/a.flac': raw});
        expect(changes, ['/music/a.flac']);
        expect(controller.metadata!['lyrics'], raw);
        expect(controller.onlineLyricsSaveFailed, isFalse);

        final reopened = controllerFor(
          (_) async => fail('Embedded lyrics must load offline'),
          read: read,
        );
        await reopened.load(_item('a'));
        expect(reopened.lyrics.lines.map((line) => line.text), [
          'Found',
          'Offline',
        ]);
        expect(fetches, 1);
      },
    );

    test(
      'SAF saves to the original URI instead of the playback temp file',
      () async {
        final saves = <String>[];
        final controller = controllerFor(
          (_) async => '[00:01.00]Found',
          save: (source, _) async => saves.add(source),
        );
        const source = 'content://library/song.flac';
        await controller.load(
          _item('a', source: source, resolved: '/tmp/song.flac'),
        );
        await controller.searchOnline();
        expect(saves, [source]);
      },
    );

    test(
      'a save failure retains found lyrics and exposes the failure',
      () async {
        final controller = controllerFor(
          (_) async => '[00:01.00]Found',
          save: (_, _) async => throw StateError('Read-only file'),
        );
        await controller.load(_item('a'));
        await controller.searchOnline();
        expect(controller.lyrics.lines.single.text, 'Found');
        expect(controller.onlineLyricsSaveFailed, isTrue);
        expect(controller.onlineSearchMissed, isFalse);
        await controller.load(_item('b'));
        expect(controller.onlineLyricsSaveFailed, isFalse);
      },
    );

    test(
      'switching tracks during parsing never saves a stale result',
      () async {
        final parse = Completer<ParsedLyrics>();
        final saves = <String>[];
        final controller = PlayerMetadataController(
          readMetadata: (_) async => const {},
          fetchOnlineLyrics: (_) async => '[00:01.00]Old',
          parseLyrics: (_) => parse.future,
          saveOnlineLyrics: (source, _) async => saves.add(source),
        );
        addTearDown(controller.dispose);
        await controller.load(_item('a'));
        final pending = controller.searchOnline();
        await Future<void>.delayed(Duration.zero);
        await controller.load(_item('b'));
        parse.complete(LyricsParser.parse('[00:01.00]Old'));
        await pending;
        expect(saves, isEmpty);
      },
    );

    test(
      'an in-flight save finishes on its original file after a track change',
      () async {
        final saved = Completer<void>();
        final saves = <String>[];
        final controller = controllerFor(
          (_) async => '[00:01.00]First',
          save: (source, _) async {
            saves.add(source);
            await saved.future;
          },
        );
        await controller.load(_item('a'));
        final pending = controller.searchOnline();
        await Future<void>.delayed(Duration.zero);
        expect(controller.lyrics.lines.single.text, 'First');
        await controller.load(_item('b'));
        saved.complete();
        await pending;
        expect(saves, ['/music/a.flac']);
        expect(controller.lyrics.isEmpty, isTrue);
        expect(controller.onlineLyricsSaveFailed, isFalse);
      },
    );

    test('empty results never write tags', () async {
      final controller = controllerFor(
        (_) async => '',
        save: (_, _) async => fail('Empty lyrics must not change the file'),
      );
      await controller.load(_item('a'));
      await controller.searchOnline();
      expect(controller.onlineSearchMissed, isTrue);
    });

    test(
      'closing the player during a save still finishes the original file',
      () async {
        final saved = Completer<void>();
        final writes = <String>[];
        final controller = PlayerMetadataController(
          readMetadata: (_) async => const {},
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (_) async => '[00:01.00]Found',
          saveOnlineLyrics: (source, _) async {
            await saved.future;
            writes.add(source);
          },
        );
        var notifications = 0;
        controller.addListener(() => notifications++);
        await controller.load(_item('a'));
        final pending = controller.searchOnline();
        await Future<void>.delayed(Duration.zero);
        await controller.searchOnline();
        controller.dispose();
        final before = notifications;
        saved.complete();
        await pending;
        expect(writes, ['/music/a.flac']);
        expect(notifications, before);
      },
    );

    test('needs a title and artist to search', () async {
      final controller = controllerFor((_) async => '[00:01.00]Found');
      await controller.load(
        MediaItem(id: 'a', title: 'a', extras: const {'source': '/a.flac'}),
      );
      expect(controller.canSearchOnline, isFalse);
      await controller.searchOnline();
      expect(controller.lyrics.isEmpty, isTrue);
    });
  });
}
