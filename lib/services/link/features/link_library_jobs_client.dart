import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_library_reconcile.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';

class LinkLibraryJobsState {
  const LinkLibraryJobsState({
    this.loaded = false,
    this.supported = false,
    this.jobs = const [],
  });

  final bool loaded;
  final bool supported;
  final List<LinkLibraryJob> jobs;
}

/// Tracks desktop work independently of the sheet that submitted it. A
/// reconnect fetches finished jobs as well as those still running.
class LinkLibraryJobsClient extends Notifier<LinkLibraryJobsState> {
  LinkClientApi? _client;
  Timer? _poll;
  int _revision = 0;
  bool _refreshing = false;
  final _reconciled = <String>{};
  Future<void> _reconcile = Future.value();

  @override
  LinkLibraryJobsState build() {
    _refreshing = false;
    _revision++;
    final client = _client = ref.watch(linkPhoneClientProvider);
    if (client == null) return const LinkLibraryJobsState();
    final messages = client.messages.listen((message) {
      if (message['type'] != 'library.job') return;
      try {
        _accept(LinkLibraryJob.fromJson(linkLibraryMap(message['job'])));
      } on Object {
        /* Ignore malformed messages from an older desktop. */
      }
    });
    final connections = client.connectionStates.listen((connection) {
      _schedulePoll();
      if (connection == LinkConnectionState.connected) unawaited(refresh());
    });
    ref.onDispose(() {
      _poll?.cancel();
      unawaited(messages.cancel());
      unawaited(connections.cancel());
    });
    Future.microtask(refresh);
    return const LinkLibraryJobsState();
  }

  Future<void> refresh() async {
    final client = _client;
    if (client == null ||
        _refreshing ||
        client.connectionState != LinkConnectionState.connected) {
      return;
    }
    _refreshing = true;
    final revision = _revision;
    try {
      final response = linkLibraryMap(await client.get(LinkOps.libraryJobs));
      final jobs = [
        for (final raw in response['jobs'] as List? ?? const [])
          LinkLibraryJob.fromJson(linkLibraryMap(raw)),
      ];
      if (!ref.mounted || client != _client || revision != _revision) return;
      state = LinkLibraryJobsState(
        loaded: true,
        supported: response['actions'] is List,
        jobs: jobs,
      );
      for (final job in jobs) {
        _onCompleted(client, job);
      }
    } on Object {
      // Older desktops do not implement these operations. Playback still works.
      if (ref.mounted && client == _client) {
        state = LinkLibraryJobsState(
          loaded: true,
          supported: state.supported,
          jobs: state.jobs,
        );
      }
    } finally {
      if (client == _client) {
        _refreshing = false;
        _schedulePoll();
      }
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = null;
    if (!ref.mounted ||
        _client?.connectionState != LinkConnectionState.connected ||
        !state.jobs.any((job) => job.active)) {
      return;
    }
    _poll = Timer(const Duration(seconds: 4), () => unawaited(refresh()));
  }

  void _accept(LinkLibraryJob job) {
    if (!ref.mounted) return;
    for (final previous in state.jobs) {
      if (previous.id != job.id) continue;
      if (previous.finished > job.finished ||
          (!previous.active && job.active) ||
          (previous.status == LinkLibraryJobStatus.running &&
              job.status == LinkLibraryJobStatus.queued)) {
        return;
      }
    }
    _revision++;
    state = LinkLibraryJobsState(
      loaded: true,
      supported: true,
      jobs: [
        for (final previous in state.jobs)
          if (previous.id != job.id) previous,
        job,
      ],
    );
    final client = _client;
    if (client != null) _onCompleted(client, job);
    _schedulePoll();
  }

  void _onCompleted(LinkClientApi client, LinkLibraryJob job) {
    if (job.active ||
        job.succeeded == 0 ||
        !linkLibraryActionChangesCatalog(job.action)) {
      return;
    }
    final key = '${client.server.serverId}:${job.id}';
    if (!_reconciled.add(key)) return;
    if (_reconciled.length > 400) _reconciled.remove(_reconciled.first);
    _reconcile = _reconcile.then((_) async {
      if (!ref.mounted || client != _client) {
        _reconciled.remove(key);
        return;
      }
      try {
        await ref.read(linkLibraryReconcileProvider)(client, job);
      } on Object catch (error) {
        _reconciled.remove(key);
        AppLogger('LinkLibrary').w('Could not refresh desktop files: $error');
      }
    });
  }

  Future<LinkLibraryJob> start(
    LinkLibraryAction action,
    List<String> songIds,
    Map<String, dynamic> options,
  ) async {
    final client = _client;
    if (client == null ||
        client.connectionState != LinkConnectionState.connected) {
      throw const LinkException('unavailable', 'The desktop is disconnected');
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final response = await client.post(LinkOps.libraryJobs, {
      'id': id,
      'action': action.name,
      'songIds': songIds,
      'options': options,
    });
    if (!ref.mounted || client != _client) {
      throw const LinkException('unavailable', 'The paired desktop changed');
    }
    final job = LinkLibraryJob.fromJson(linkLibraryMap(response));
    _accept(job);
    return job;
  }

  Future<void> cancel(String id) async {
    final client = _client;
    if (client == null) return;
    final response = await client.post(LinkOps.libraryJobs, {
      'id': id,
      'cancel': true,
    });
    if (ref.mounted && client == _client) {
      _accept(LinkLibraryJob.fromJson(linkLibraryMap(response)));
    }
  }
}

final linkLibraryJobsProvider =
    NotifierProvider<LinkLibraryJobsClient, LinkLibraryJobsState>(
      LinkLibraryJobsClient.new,
    );
