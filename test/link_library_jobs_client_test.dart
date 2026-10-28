import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/features/link_library_jobs_client.dart';
import 'package:mornye/services/link/features/link_library_reconcile.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

LinkLibraryJob _job(
  String id, {
  LinkLibraryJobStatus status = LinkLibraryJobStatus.completed,
}) => LinkLibraryJob(
  id: id,
  action: LinkLibraryAction.replayGain,
  status: status,
  total: 1,
  finished: status == LinkLibraryJobStatus.completed ? 1 : 0,
  succeeded: status == LinkLibraryJobStatus.completed ? 1 : 0,
);

void main() {
  late FakeLinkClient client;
  late ProviderContainer container;
  late List<String> reconciled;

  setUp(() {
    reconciled = [];
    client = FakeLinkClient(
      onGet: (_, _) => {
        'actions': ['replayGain'],
        'jobs': <Object?>[],
      },
    );
    container = ProviderContainer(
      overrides: [
        linkPhoneClientProvider.overrideWithValue(client),
        linkLibraryReconcileProvider.overrideWithValue((_, job) async {
          reconciled.add(job.id);
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await client.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'reconnect recovers completed work and refreshes each job once',
    () async {
      container.read(linkLibraryJobsProvider);
      await settle();
      client.setConnection(LinkConnectionState.disconnected);
      client.onGet = (_, _) => {
        'actions': ['replayGain'],
        'jobs': [_job('finished_1').toJson()],
      };
      client.setConnection(LinkConnectionState.connected);
      await settle();
      expect(container.read(linkLibraryJobsProvider).jobs.single.finished, 1);
      expect(reconciled, ['finished_1']);
      await container.read(linkLibraryJobsProvider.notifier).refresh();
      await settle();
      expect(reconciled, ['finished_1']);
    },
  );

  test('late HTTP acknowledgement cannot overwrite a completed push', () async {
    client.onPost = (_, body) {
      final id = body['id'] as String;
      client.push({'type': 'library.job', 'job': _job(id).toJson()});
      return _job(id, status: LinkLibraryJobStatus.queued).toJson();
    };
    final controller = container.read(linkLibraryJobsProvider.notifier);
    await settle();
    await controller.start(LinkLibraryAction.replayGain, ['l:one'], {});
    expect(
      container.read(linkLibraryJobsProvider).jobs.single.status,
      LinkLibraryJobStatus.completed,
    );
    expect(client.posts.single.body['songIds'], ['l:one']);
    expect(client.posts.single.body, isNot(contains('filePath')));
  });

  test('stale status fetch cannot discard a newer job push', () async {
    final pending = Completer<Object?>();
    client.onGet = (_, _) => pending.future;
    container.read(linkLibraryJobsProvider);
    await Future<void>.delayed(Duration.zero);
    client.push({
      'type': 'library.job',
      'job': _job('new_job_1', status: LinkLibraryJobStatus.running).toJson(),
    });
    pending.complete({
      'actions': ['replayGain'],
      'jobs': <Object?>[],
    });
    await settle();
    expect(container.read(linkLibraryJobsProvider).jobs.single.id, 'new_job_1');
  });

  test(
    'older desktop stays usable and disconnected requests fail before POST',
    () async {
      client.onGet = (_, _) => const LinkException('not_found');
      final controller = container.read(linkLibraryJobsProvider.notifier);
      await settle();
      expect(container.read(linkLibraryJobsProvider).loaded, isTrue);
      expect(container.read(linkLibraryJobsProvider).supported, isFalse);
      client.setConnection(LinkConnectionState.disconnected);
      await expectLater(
        controller.start(LinkLibraryAction.delete, ['l:one'], {}),
        throwsA(isA<LinkException>()),
      );
      expect(client.posts, isEmpty);
    },
  );
}
