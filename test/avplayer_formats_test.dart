import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/avplayer_formats.dart';

/// Writes FFmpeg's output file, the argument before the trailing `-y`.
Future<bool> _fakeFFmpeg(List<String> arguments) async {
  await File(arguments[arguments.length - 2]).writeAsBytes([1, 2, 3]);
  return true;
}

void main() {
  test('formats AVPlayer never opens are copied up front', () {
    for (final (name, codec, label) in [
      ('/music/a.ape', null, 'APE'),
      ('/music/a.WV', null, 'WavPack'),
      ('/music/a.dsf', null, 'DSF'),
      ('/music/a.dff', null, 'DFF'),
      ('/music/a.mpc', null, 'Musepack'),
      ('/music/a.tta', null, 'TTA'),
      ('/music/a.wma', null, 'WMA'),
      ('/music/a.mka', 'flac', 'Matroska'),
      ('network://nas/a/b.ape', null, 'APE'),
      ('/music/a.flac', 'dsd_lsbf_planar', 'DSD'),
      ('/music/a.ogg', 'Vorbis', 'Ogg Vorbis'),
    ]) {
      final format = avPlayerFormat(name: name, codec: codec);
      expect(format?.label, label, reason: name);
      expect(format?.never, isTrue, reason: name);
    }
  });

  test('Ogg and Opus wait for AVPlayer; native formats need nothing', () {
    for (final name in ['a.ogg', 'a.oga', 'a.opus']) {
      expect(avPlayerFormat(name: name)?.never, isFalse, reason: name);
    }
    for (final (name, codec) in [
      ('a.flac', 'flac'),
      ('a.m4a', 'alac'),
      ('a.m4a', 'aac'),
      ('a.mp3', null),
      ('a.wav', null),
      ('a.aiff', null),
      ('a.ac3', null),
      ('a.eac3', null),
      ('dir.ape/song', null),
      ('noext', null),
    ]) {
      expect(
        avPlayerFormat(name: name, codec: codec),
        isNull,
        reason: name,
      );
    }
  });

  test('copies keep sample rates AVPlayer plays and bring DSD down', () {
    expect(avPlayerCopyRate(null, dsd: false), isNull);
    expect(avPlayerCopyRate(192000, dsd: false), isNull);
    expect(avPlayerCopyRate(384000, dsd: false), isNull);
    expect(avPlayerCopyRate(705600, dsd: false), 352800);
    expect(avPlayerCopyRate(768000, dsd: false), 384000);
    expect(avPlayerCopyRate(2822400, dsd: true), 176400);
    expect(avPlayerCopyRate(null, dsd: true), 176400);
  });

  test('copy arguments pick the stream, block size and sample format', () {
    final ape = avPlayerFormat(name: 'a.ape');
    final local = avPlayerCopyArguments(
      '/in/a.ape',
      '/out/a.flac',
      format: ape,
    );
    expect(local, containsAllInOrder(['-i', '/in/a.ape']));
    expect(local, containsAllInOrder(['-map', '0:a:0']));
    expect(local, containsAllInOrder(['-c:a', 'flac']));
    expect(local, containsAllInOrder(['-frame_size', '4096']));
    expect(local, isNot(contains('-sample_fmt')));
    expect(local, isNot(contains('-ar')));
    expect(local, isNot(contains('-rw_timeout')));
    expect(local.sublist(local.length - 4), [
      '-f',
      'flac',
      '/out/a.flac',
      '-y',
    ]);

    final ogg = avPlayerCopyArguments(
      'http://127.0.0.1:1/x.ogg',
      '/out/b.flac',
      format: avPlayerFormat(name: 'x.ogg'),
    );
    expect(ogg, containsAllInOrder(['-rw_timeout', '30000000', '-i']));
    expect(ogg, containsAllInOrder(['-sample_fmt', 's16']));

    final dsd = avPlayerCopyArguments(
      '/in/a.dsf',
      '/out/c.flac',
      format: avPlayerFormat(name: 'a.dsf'),
      sampleRate: 2822400,
      dsd: true,
    );
    expect(dsd, containsAllInOrder(['-sample_fmt', 's32', '-ar', '176400']));
  });

  group('copies', () {
    late Directory folder;
    setUp(() async {
      folder = await Directory.systemTemp.createTemp('avplayer-copies-test-');
      addTearDown(() async {
        if (await folder.exists()) await folder.delete(recursive: true);
      });
    });

    test('are made once per song and bounded', () async {
      final runs = <List<String>>[];
      final pinned = <String>{};
      final copies = AvPlayerCopies(
        run: (arguments) {
          runs.add(arguments);
          return _fakeFFmpeg(arguments);
        },
        isDisposed: () => false,
        isPinned: pinned.contains,
        directory: Directory('${folder.path}/copies'),
        maxEntries: 2,
      );
      final first = await copies.resolve('/a.ape', '/a.ape');
      expect(first, isNotNull);
      expect(first, endsWith('.flac'));
      expect(copies.ownsPath(first!), isTrue);
      expect(copies.has('/a.ape'), isTrue);
      // A NAS song resolves to a new proxy URL each time; its source keys it.
      expect(await copies.resolve('/a.ape', '/other-url.ape'), first);
      expect(runs, hasLength(1));

      pinned.add(first);
      final second = await copies.resolve('/b.ape', '/b.ape');
      final third = await copies.resolve('/c.ape', '/c.ape');
      expect(runs, hasLength(3));
      expect(copies.has('/a.ape'), isFalse);
      // The playing copy outlives its eviction until it is released.
      expect(await File(first).exists(), isTrue);
      pinned.clear();
      await copies.resolve('/c.ape', '/c.ape');
      expect(await File(first).exists(), isFalse);
      expect(await File(second!).exists(), isTrue);

      await copies.dispose();
      expect(await File(second).exists(), isFalse);
      expect(await File(third!).exists(), isFalse);
    });

    test('a failed conversion leaves no file and no entry', () async {
      final copies = AvPlayerCopies(
        run: (arguments) async {
          await _fakeFFmpeg(arguments);
          return false;
        },
        isDisposed: () => false,
        isPinned: (_) => false,
        directory: Directory('${folder.path}/copies'),
      );
      addTearDown(copies.dispose);
      expect(await copies.resolve('/a.ape', '/a.ape'), isNull);
      expect(copies.has('/a.ape'), isFalse);
      expect(Directory('${folder.path}/copies').listSync(), isEmpty);
    });

    test('copies left by an earlier run are deleted', () async {
      final stale = File('${folder.path}/copies/old.flac');
      await stale.create(recursive: true);
      final copies = AvPlayerCopies(
        run: _fakeFFmpeg,
        isDisposed: () => false,
        isPinned: (_) => false,
        directory: Directory('${folder.path}/copies'),
      );
      addTearDown(copies.dispose);
      await copies.resolve('/a.ape', '/a.ape');
      expect(await stale.exists(), isFalse);
    });

    final ffmpeg = Platform.environment['PATH']
        ?.split(':')
        .map((path) => File('$path/ffmpeg'))
        .where((file) => file.existsSync())
        .firstOrNull;
    test('the arguments convert WavPack to FLAC with small blocks', () async {
      final input = '${folder.path}/in.wv';
      final made = await Process.run(ffmpeg!.path, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1:sample_rate=48000',
        '-c:a',
        'wavpack',
        input,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final copies = AvPlayerCopies(
        run: (arguments) async =>
            (await Process.run(ffmpeg.path, arguments)).exitCode == 0,
        isDisposed: () => false,
        isPinned: (_) => false,
        directory: Directory('${folder.path}/copies'),
      );
      addTearDown(copies.dispose);
      final copy = await copies.resolve(
        input,
        input,
        format: avPlayerFormat(name: input),
        sampleRate: 48000,
      );
      expect(copy, isNotNull);
      final bytes = await File(copy!).readAsBytes();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'fLaC');
      // STREAMINFO: minimum and maximum block size, big endian.
      expect(bytes.sublist(8, 12), [0x10, 0x00, 0x10, 0x00]);
    }, skip: ffmpeg == null ? 'ffmpeg is not installed' : false);
  });
}
