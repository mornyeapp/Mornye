import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/utils/file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local deletion waits for file release and coalesces requests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'release-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final entered = Completer<void>();
      final released = Completer<void>();
      var preparations = 0;
      var publications = 0;
      events.subscribe(
        (_) async => publications++,
        beforeDelete: (source) async {
          preparations++;
          expect(events.isDeleting(source), isTrue);
          expect(await file.exists(), isTrue);
          entered.complete();
          await released.future;
        },
      );
      final first = deleteFile(file.path, deletionEvents: events);
      await entered.future;
      final second = deleteFile(file.path, deletionEvents: events);
      expect(await file.exists(), isTrue);
      released.complete();
      expect(await Future.wait([first, second]), [true, true]);
      expect(preparations, 1);
      expect(publications, 1);
      expect(events.isDeleting(file.path), isFalse);
    },
  );

  test('failed release keeps the file and does not publish deletion', () async {
    final directory = await Directory.systemTemp.createTemp('failed-release-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/song.flac',
    ).writeAsString('audio');
    final events = SourceDeletionEvents();
    final deleted = <String>[];
    final unsubscribe = events.subscribe(
      (source) async => deleted.add(source),
      beforeDelete: (_) async =>
          throw StateError('Decoder still owns the file'),
    );
    expect(await deleteFile(file.path, deletionEvents: events), isFalse);
    expect(await file.readAsString(), 'audio');
    expect(deleted, isEmpty);
    expect(events.isDeleting(file.path), isFalse);
    unsubscribe();
    expect(await deleteFile(file.path, deletionEvents: events), isTrue);
  });

  test(
    'successful deletion waits for cleanup and survives reaction failure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-deletion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsString('audio');
      final events = SourceDeletionEvents();
      final entered = Completer<void>();
      final cleaned = Completer<void>();
      final reactions = <String>[];
      events.subscribe((source) async {
        expect(await File(source).exists(), isFalse);
        entered.complete();
        await cleaned.future;
        throw StateError('playback failed');
      });
      events.subscribe((source) async => reactions.add(source));
      var finished = false;
      final deletion = deleteFile('EXISTS:${file.path}', deletionEvents: events)
          .then((result) {
            finished = true;
            return result;
          });
      await entered.future;
      expect(finished, isFalse);
      cleaned.complete();
      expect(await deletion, isTrue);
      expect(reactions, [file.path]);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'unsubscribe retires a consumer during an awaited publication',
    () async {
      final events = SourceDeletionEvents();
      final entered = Completer<void>();
      final gate = Completer<void>();
      events.subscribe((_) async {
        entered.complete();
        await gate.future;
      });
      final reactions = <String>[];
      final unsubscribe = events.subscribe(
        (source) async => reactions.add(source),
      );
      final publication = events.publish('/song.flac');
      await entered.future;
      unsubscribe();
      unsubscribe();
      gate.complete();
      await publication;
      expect(reactions, isEmpty);
    },
  );

  const channel = MethodChannel('com.zarz.mornye/backend');
  const uri = 'content://test.provider/document/song.flac';
  for (final (deleted, exists, expected) in [
    (true, true, true),
    (false, false, true),
    (false, true, false),
    (false, null, false),
    (false, PlatformException(code: 'unavailable'), false),
    (null, false, false),
    (PlatformException(code: 'unavailable'), false, false),
  ]) {
    test(
      'SAF deletion $deleted, existence $exists reports $expected',
      () async {
        final calls = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          final result = call.method == 'safDelete' ? deleted : exists;
          if (result is PlatformException) throw result;
          return result;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final events = SourceDeletionEvents();
        final reactions = <String>[];
        events.subscribe((source) async {
          reactions.add(source);
          throw StateError('playback failed');
        });
        expect(await deleteFile(uri, deletionEvents: events), expected);
        expect(reactions, expected ? [uri] : isEmpty);
        expect(calls, ['safDelete', if (deleted == false) 'safExists']);
      },
    );
  }

  test(
    'invalid, network and virtual CUE paths never publish deletions',
    () async {
      final directory = await Directory.systemTemp.createTemp('cue-deletion-');
      addTearDown(() => directory.delete(recursive: true));
      final cue = await File(
        '${directory.path}/album.cue',
      ).writeAsString('cue');
      final events = SourceDeletionEvents();
      final reactions = <String>[];
      events.subscribe((source) async => reactions.add(source));
      for (final path in [
        null,
        '',
        'EXISTS:',
        'network://song',
        '${cue.path}#track01',
      ]) {
        expect(await deleteFile(path, deletionEvents: events), isFalse);
      }
      expect(reactions, isEmpty);
      expect(await cue.exists(), isTrue);
    },
  );
}
