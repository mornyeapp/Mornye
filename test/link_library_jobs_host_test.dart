import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_library_jobs_host.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_protocol.dart';

void main() {
  late LinkLibraryJobsHost host;
  late LinkHostRouter router;
  late List<String> executed;
  late List<LinkLibraryJob> updates;
  late int changes;
  LinkLibraryExecute? run;

  setUp(() {
    executed = [];
    updates = [];
    changes = 0;
    run = null;
    router = LinkHostRouter();
    host = LinkLibraryJobsHost(
      isPaired: (id) async => id != 'unpaired',
      execute: (work, id) async {
        executed.add('$id:${work.action.name}');
        return await run?.call(work, id) ?? {};
      },
      notify: (_, job) => updates.add(job),
      onChanged: () async {
        changes++;
      },
    )..register(router);
  });
  tearDown(() => host.close());

  Future<Object?> call(Map<String, dynamic> args, {String device = 'phone'}) =>
      router.dispatch(
        LinkRequest(
          requestId: 'request',
          op: LinkOps.libraryJobs,
          deviceId: device,
          args: args,
        ),
      );
  Map<String, dynamic> request({
    String id = 'request_1',
    List<String> songs = const ['l:one', 'd:two'],
    String action = 'replayGain',
  }) => {'id': id, 'action': action, 'songIds': songs};
  Future<void> complete() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
      if (updates.isNotEmpty && !updates.last.active) return;
    }
    fail('Work did not complete');
  }

  Matcher error(String code) =>
      throwsA(isA<LinkException>().having((e) => e.code, 'code', code));

  test(
    'accepts quickly and executes sequentially with per-song outcomes',
    () async {
      final first = Completer<Map<String, dynamic>>();
      run = (_, id) async =>
          id == 'l:one' ? first.future : {'error': 'read_failed'};
      final accepted = linkLibraryMap(await call(request()));
      expect(accepted['status'], 'queued');
      await Future<void>.delayed(Duration.zero);
      expect(executed, ['l:one:replayGain']);
      first.complete({});
      await complete();
      expect(executed, ['l:one:replayGain', 'd:two:replayGain']);
      expect(updates.last.finished, 2);
      expect(updates.last.succeeded, 1);
      expect(updates.last.failed, 1);
      expect(changes, 1);
    },
  );

  test(
    'retry is idempotent and a reused ID with different work is rejected',
    () async {
      await call(request());
      await call(request());
      await complete();
      expect(executed.length, 2);
      await expectLater(call(request(action: 'delete')), error('invalid'));
    },
  );

  test(
    'completed work is recovered on reconnect and isolated per phone',
    () async {
      await call(request());
      await complete();
      final own = linkLibraryMap(await call({'_method': 'GET'}));
      final other = linkLibraryMap(
        await call({'_method': 'GET'}, device: 'other'),
      );
      expect((own['jobs'] as List).single, updates.last.toJson());
      expect(other['jobs'], isEmpty);
      await expectLater(
        call({'id': 'request_1', 'cancel': true}, device: 'other'),
        error('not_found'),
      );
    },
  );

  test(
    'cancel finishes current file and does not start remaining songs',
    () async {
      final first = Completer<Map<String, dynamic>>();
      run = (_, _) => first.future;
      await call(request());
      await Future<void>.delayed(Duration.zero);
      await call({'id': 'request_1', 'cancel': true});
      first.complete({});
      await complete();
      expect(executed.length, 1);
      expect(updates.last.status, LinkLibraryJobStatus.cancelled);
      expect(updates.last.succeeded, 1);
    },
  );

  test('cancelled queued jobs never touch a file', () async {
    await call(request());
    await call({'id': 'request_1', 'cancel': true});
    await complete();
    expect(executed, isEmpty);
  });

  test('unpaired callers and raw filesystem paths are rejected', () async {
    await expectLater(call(request(), device: 'unpaired'), error('forbidden'));
    for (final id in [
      '/music/song.flac',
      'l:../file',
      'd:C:\\music\\song',
      'other:one',
    ]) {
      await expectLater(call(request(songs: [id])), error('invalid'));
    }
    expect(executed, isEmpty);
  });

  test(
    'failed file does not prevent the next one or falsely count success',
    () async {
      run = (_, id) async {
        if (id == 'l:one') throw StateError('decoder');
        return {};
      };
      await call(request());
      await complete();
      expect(updates.last.succeeded, 1);
      expect(updates.last.failed, 1);
    },
  );

  test(
    'preview does not refresh catalog and apply requires its owner',
    () async {
      await call(request(action: 'reEnrichPreview'));
      await complete();
      expect(changes, 0);
      final apply = {
        ...request(id: 'apply_123', action: 'reEnrich'),
        'options': {'previewJobId': 'request_1'},
      };
      await expectLater(call(apply, device: 'other'), error('invalid'));
      await call(apply);
      await complete();
      expect(changes, 1);
    },
  );

  test(
    'queue bounds reject excess jobs while allowing existing retries',
    () async {
      final blocker = Completer<Map<String, dynamic>>();
      run = (_, _) => blocker.future;
      for (var i = 0; i < 10; i++) {
        await call(request(id: 'request_$i'));
      }
      await expectLater(call(request(id: 'overflow_1')), error('busy'));
      await call(request(id: 'request_0'));
      host.close();
      blocker.complete({});
    },
  );
}
