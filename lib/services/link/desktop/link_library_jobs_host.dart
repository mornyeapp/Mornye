import 'dart:async';

import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/logger.dart';

typedef LinkLibraryExecute =
    Future<Map<String, dynamic>> Function(LinkLibraryWork work, String songId);

class _Job {
  _Job(this.work);

  final LinkLibraryWork work;
  LinkLibraryJobStatus status = LinkLibraryJobStatus.queued;
  String currentTitle = '';
  bool cancelled = false;
  int completedMs = 0;
  final results = <Map<String, dynamic>>[];

  LinkLibraryJob get snapshot => LinkLibraryJob(
    id: work.id,
    action: work.action,
    status: status,
    total: work.songIds.length,
    finished: results.length,
    succeeded: results.where((result) => result['error'] == null).length,
    currentTitle: currentTitle,
    results: List.unmodifiable(results),
    completedMs: completedMs,
  );
}

/// Serial desktop work that survives a phone disconnect. A retry with the
/// same request ID returns the existing job instead of writing files twice.
class LinkLibraryJobsHost {
  LinkLibraryJobsHost({
    required this.isPaired,
    required this.execute,
    required this.notify,
    required this.onChanged,
    this.titleFor,
  });

  final Future<bool> Function(String deviceId) isPaired;
  final LinkLibraryExecute execute;
  final void Function(String deviceId, LinkLibraryJob job) notify;
  final Future<void> Function() onChanged;
  final String Function(String songId)? titleFor;
  final _jobs = <String, _Job>{};
  bool _running = false;
  bool _closed = false;

  void register(LinkHostRouter router) =>
      router.register(LinkOps.libraryJobs, handle);

  Future<Object?> handle(LinkRequest request) async {
    if (_closed || !await isPaired(request.deviceId)) {
      throw const LinkException('forbidden', 'A paired phone is required');
    }
    if (request.method == 'GET') {
      return {
        'actions': [for (final action in LinkLibraryAction.values) action.name],
        'jobs': [
          for (final job in _jobs.values)
            if (job.work.deviceId == request.deviceId) job.snapshot.toJson(),
        ],
      };
    }
    final args = request.args;
    final id = args['id'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(id)) {
      invalidLinkLibraryRequest('A valid job ID is required');
    }
    final key = '${request.deviceId}:$id';
    if (args['cancel'] == true) {
      final job = _jobs[key];
      if (job == null) throw const LinkException('not_found', 'No such job');
      if (job.snapshot.active) {
        job.cancelled = true;
        if (job.status == LinkLibraryJobStatus.queued) {
          job.status = LinkLibraryJobStatus.cancelled;
        }
        _notify(job);
      }
      return job.snapshot.toJson();
    }
    final action = LinkLibraryAction.values.asNameMap()[args['action']];
    final rawIds = args['songIds'];
    if (action == null ||
        rawIds is! List ||
        rawIds.isEmpty ||
        rawIds.length > 100) {
      invalidLinkLibraryRequest('Choose an action and up to 100 songs');
    }
    final ids = <String>[];
    for (final value in rawIds) {
      if (value is! String ||
          value.length > 256 ||
          !RegExp(r'^[ld]:[^/\\\x00-\x1f]+$').hasMatch(value)) {
        invalidLinkLibraryRequest('Only desktop catalog song IDs are accepted');
      }
      if (!ids.contains(value)) ids.add(value);
    }
    final options = linkLibraryMap(args['options']);
    if ((action == LinkLibraryAction.readMetadata ||
            action == LinkLibraryAction.editMetadata) &&
        ids.length != 1) {
      invalidLinkLibraryRequest('Metadata editing requires one song');
    }
    final work = LinkLibraryWork(
      id: id,
      deviceId: request.deviceId,
      action: action,
      songIds: ids,
      options: options,
    );
    if (_jobs[key] case final previous?) {
      if (previous.work.fingerprint != work.fingerprint) {
        invalidLinkLibraryRequest('This job ID was already used');
      }
      return previous.snapshot.toJson();
    }
    if (_jobs.values.where((job) => job.snapshot.active).length >= 10) {
      throw const LinkException('busy', 'The desktop work queue is full');
    }
    if (action == LinkLibraryAction.reEnrich) {
      final preview = _jobs['${request.deviceId}:${options['previewJobId']}'];
      if (preview == null ||
          preview.work.action != LinkLibraryAction.reEnrichPreview ||
          preview.snapshot.active ||
          ids.any((id) => !preview.work.songIds.contains(id))) {
        invalidLinkLibraryRequest('Review a completed metadata preview first');
      }
    }
    while (_jobs.length >= 80) {
      final old = _jobs.entries.where((entry) => !entry.value.snapshot.active);
      if (old.isEmpty) break;
      _jobs.remove(old.first.key);
    }
    final job = _Job(work);
    _jobs[key] = job;
    _notify(job);
    unawaited(Future<void>(_drain));
    return job.snapshot.toJson();
  }

  void _notify(_Job job) {
    if (!_closed) notify(job.work.deviceId, job.snapshot);
  }

  Future<void> _drain() async {
    if (_running || _closed) return;
    _running = true;
    try {
      while (!_closed) {
        final queued = _jobs.values.where(
          (job) => job.status == LinkLibraryJobStatus.queued,
        );
        if (queued.isEmpty) break;
        final job = queued.first;
        job.status = LinkLibraryJobStatus.running;
        for (final id in job.work.songIds) {
          if (_closed || job.cancelled) break;
          job.currentTitle = titleFor?.call(id) ?? id;
          _notify(job);
          try {
            final result = await execute(job.work, id);
            job.results.add({
              'songId': id,
              'title': job.currentTitle,
              ...result,
            });
          } on Object catch (error, stack) {
            AppLogger(
              'LinkLibrary',
            ).e('Desktop ${job.work.action.name} failed for $id', error, stack);
            job.results.add({
              'songId': id,
              'title': job.currentTitle,
              'error': 'operation_failed',
            });
          }
          _notify(job);
        }
        if (job.results.any((result) => result['error'] == null) &&
            linkLibraryActionChangesCatalog(job.work.action)) {
          try {
            await onChanged();
          } on Object catch (error) {
            AppLogger(
              'LinkLibrary',
            ).w('Files saved but catalog refresh failed: $error');
          }
        }
        job.status = job.cancelled || _closed
            ? LinkLibraryJobStatus.cancelled
            : LinkLibraryJobStatus.completed;
        job.completedMs = DateTime.now().millisecondsSinceEpoch;
        _notify(job);
      }
    } finally {
      _running = false;
    }
  }

  void close() => _closed = true;
}
