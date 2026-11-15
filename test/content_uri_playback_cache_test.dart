import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/content_uri_playback_cache.dart';

void main() {
  late Directory directory;
  late Set<String> pins;
  late List<Object> errors;
  late bool disposed;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('playback-cache-test-');
    pins = {};
    errors = [];
    disposed = false;
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<String> file(String name, {int bytes = 1}) async {
    final result = File('${directory.path}/$name');
    await result.writeAsBytes(List.filled(bytes, 0));
    return result.path;
  }

  ContentUriPlaybackCache cache(
    Future<String?> Function(String) copy, {
    int maxEntries = 3,
    int maxBytes = 256 * 1024 * 1024,
    Future<bool> Function(String)? exists,
  }) => ContentUriPlaybackCache(
    copy: copy,
    isDisposed: () => disposed,
    isPinned: pins.contains,
    onResolveError: errors.add,
    onDeleteError: errors.add,
    maxEntries: maxEntries,
    maxBytes: maxBytes,
    exists: exists,
  );

  test('concurrent resolutions share one copy and reuse it', () async {
    final copy = Completer<String?>();
    var copies = 0;
    final sources = cache((_) {
      copies++;
      return copy.future;
    });
    final first = sources.resolve('content://music/one');
    final second = sources.resolve('content://music/one');
    final path = await file('one');
    copy.complete(path);
    expect(await first, path);
    expect(await second, path);
    expect(await sources.resolve('content://music/one'), path);
    expect(copies, 1);
    await sources.dispose();
    expect(await File(path).exists(), isFalse);
  });

  test('retired copy cannot replace or remove a newer resolution', () async {
    final older = Completer<String?>();
    final newer = Completer<String?>();
    var copies = 0;
    final sources = cache((_) => copies++ == 0 ? older.future : newer.future);
    final oldResult = sources.resolve('content://music/one');
    expect(await sources.invalidate('content://music/one'), isTrue);
    final newResult = sources.resolve('content://music/one');
    final oldPath = await file('old');
    older.complete(oldPath);
    expect(await oldResult, isNull);
    expect(await File(oldPath).exists(), isFalse);
    final shared = sources.resolve('content://music/one');
    final newPath = await file('new');
    newer.complete(newPath);
    expect(await newResult, newPath);
    expect(await shared, newPath);
    expect(sources.cachedPath('content://music/one'), newPath);
    expect(copies, 2);
    await sources.dispose();
  });

  test('editing waits for and discards an older tag snapshot', () async {
    final copy = Completer<String?>();
    final sources = cache((_) => copy.future);
    final resolution = sources.resolve('content://music/one');
    var invalidated = false;
    final edit = sources.invalidate('content://music/one', waitForPending: true)
      ..then((_) => invalidated = true);
    await Future<void>.delayed(Duration.zero);
    expect(invalidated, isFalse);
    final path = await file('old-tags');
    copy.complete(path);
    expect(await resolution, path);
    expect(await edit, isTrue);
    expect(sources.cachedPath('content://music/one'), isNull);
    await sources.releaseUnpinned();
    expect(await File(path).exists(), isFalse);
    await sources.dispose();
  });

  test('an edit keeps a copy a deck opens until the deck lets go', () async {
    final copy = Completer<String?>();
    final sources = cache((_) => copy.future);
    final resolution = sources.resolve('content://music/one');
    final edit = sources.invalidate(
      'content://music/one',
      waitForPending: true,
    );
    final path = await file('handed-out');
    copy.complete(path);
    expect(await edit, isTrue);
    // The copy reached its deck after the edit retired it; the deck pins it
    // only once it has opened the file.
    expect(await resolution, path);
    expect(await File(path).exists(), isTrue);
    pins.add(path);
    await sources.releaseUnpinned();
    expect(await File(path).exists(), isTrue);
    expect(sources.cachedPath('content://music/one'), isNull);
    pins.clear();
    await sources.releaseUnpinned();
    expect(await File(path).exists(), isFalse);
    await sources.dispose();
  });

  test('entry eviction retains a pinned deck until it releases', () async {
    final sources = cache((source) => file(source), maxEntries: 1);
    final first = (await sources.resolve('one'))!;
    pins.add(first);
    await sources.resolve('two');
    await sources.releaseUnpinned();
    expect(sources.cachedPath('one'), isNull);
    expect(await File(first).exists(), isTrue);
    pins.clear();
    await sources.releaseUnpinned();
    expect(await File(first).exists(), isFalse);
    await sources.dispose();
  });

  test(
    'byte budget permits one oversized track and evicts older copies',
    () async {
      final sources = cache((source) => file(source, bytes: 4), maxBytes: 3);
      final first = (await sources.resolve('one'))!;
      expect(await File(first).exists(), isTrue);
      final second = (await sources.resolve('two'))!;
      expect(sources.cachedPath('one'), isNull);
      expect(sources.cachedPath('two'), second);
      await sources.dispose();
      expect(await File(second).exists(), isFalse);
    },
  );

  test(
    'shutdown does not wait for a provider and cleans its late copy',
    () async {
      final copy = Completer<String?>();
      final sources = cache((_) => copy.future);
      final resolution = sources.resolve('content://music/one');
      disposed = true;
      await sources.dispose();
      final path = await file('late');
      copy.complete(path);
      expect(await resolution, isNull);
      expect(await File(path).exists(), isFalse);
      expect(await sources.resolve('content://music/one'), isNull);
    },
  );

  test('provider failure allows a later retry', () async {
    var copies = 0;
    final sources = cache((_) async {
      if (copies++ == 0) throw StateError('provider offline');
      return file('retry');
    });
    expect(await sources.resolve('content://music/one'), isNull);
    expect(errors.single, isA<StateError>());
    expect(await sources.resolve('content://music/one'), isNotNull);
    await sources.dispose();
  });

  test('an old existence check cannot evict a newer copy', () async {
    final stat = Completer<bool>();
    final statStarted = Completer<void>();
    var copies = 0;
    final sources = cache(
      (_) => file('copy-${copies++}'),
      exists: (path) {
        if (path.endsWith('copy-0')) {
          statStarted.complete();
          return stat.future;
        }
        return File(path).exists();
      },
    );
    await sources.resolve('content://music/one');
    final checking = sources.resolve('content://music/one');
    await statStarted.future;
    await sources.invalidate('content://music/one');
    final newer = await sources.resolve('content://music/one');
    stat.complete(false);
    expect(await checking, newer);
    expect(sources.cachedPath('content://music/one'), newer);
    expect(copies, 2);
    await sources.dispose();
  });

  test('shutdown retires a cached path while its stat is pending', () async {
    final stat = Completer<bool>();
    final statStarted = Completer<void>();
    final sources = cache(
      (_) => file('cached'),
      exists: (_) {
        statStarted.complete();
        return stat.future;
      },
    );
    await sources.resolve('content://music/one');
    final checking = sources.resolve('content://music/one');
    await statStarted.future;
    await sources.dispose();
    stat.complete(true);
    expect(await checking, isNull);
  });
}
