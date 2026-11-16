import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('ExtensionAutoUpdate');

/// How old the last background store check must be before returning to the
/// foreground checks again. The native registry cache absorbs closer calls.
const extensionUpdateCheckInterval = Duration(hours: 6);

String extensionUpdateTarget(RepoExtension extension) =>
    '${extension.id}@${extension.version}';

/// Store extensions to update automatically, in store order: installed,
/// enabled, with a newer store version this app can run, and not already
/// attempted at that version ([attemptedTargets], see
/// [extensionUpdateTarget]). [storeExtensions] are the merged store
/// entries, so each version comes from the extension's pinned repository;
/// one whose repository no longer lists it is never updated.
List<RepoExtension> selectExtensionAutoUpdates({
  required Iterable<RepoExtension> storeExtensions,
  required Iterable<Extension> installed,
  Set<String> attemptedTargets = const {},
}) {
  final installedById = {for (final ext in installed) ext.id: ext};
  return [
    for (final candidate in storeExtensions)
      if (installedById[candidate.id] case final current?)
        if (current.enabled &&
            candidate.hasUpdate &&
            !candidate.sourceMissing &&
            current.version != candidate.version &&
            !candidate.requiresNewerApp &&
            !attemptedTargets.contains(extensionUpdateTarget(candidate)))
          candidate,
  ];
}

/// Upgrading an extension reloads its engine, so it waits for downloads.
bool isDownloadQueueIdle(DownloadQueueState queue) =>
    !queue.isProcessing &&
    queue.queuedCount == 0 &&
    queue.activeDownloadsCount == 0 &&
    queue.lookup.finalizingCount == 0;

/// The notice after a background run updated [count] extensions. Each run
/// publishes a new instance, so listeners fire even for an equal count.
class ExtensionAutoUpdateNotice {
  const ExtensionAutoUpdateNotice(this.count);

  final int count;
}

/// Checks the extension store in the background and, when the setting is on,
/// installs updates for enabled extensions. The state is the latest notice.
class ExtensionAutoUpdateNotifier extends Notifier<ExtensionAutoUpdateNotice?> {
  ExtensionAutoUpdateNotifier({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _lastCheckAt;
  Future<void>? _running;
  Completer<void>? _idleWaiter;

  /// Target versions already tried this session; a failed one is not
  /// retried until the store offers a newer version.
  final Set<String> _attemptedTargets = {};

  @override
  ExtensionAutoUpdateNotice? build() {
    ref.onDispose(() {
      final waiter = _idleWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    });
    return null;
  }

  /// Runs the first check once startup has settled.
  Future<void> checkAfterStartup() {
    if (_lastCheckAt != null) return _running ?? Future<void>.value();
    return _check();
  }

  /// Checks again on returning to the foreground when the last check is
  /// older than [extensionUpdateCheckInterval].
  Future<void> checkOnResume() {
    final last = _lastCheckAt;
    if (last == null ||
        _clock().difference(last) < extensionUpdateCheckInterval) {
      return _running ?? Future<void>.value();
    }
    return _check();
  }

  Future<void> _check() {
    final running = _running;
    if (running != null) return running;
    _lastCheckAt = _clock();
    return _running = _run().whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    try {
      if (!await RepoNotifier.hasSavedRegistryUrls()) return;
      await ref.read(extensionProvider.notifier).ensureInitialized();
      final repo = ref.read(repoProvider.notifier);
      if (ref.read(repoProvider).isInitialized) {
        await repo.refresh();
      } else {
        await repo.initializeToDefaultPaths();
      }
      if (!ref.mounted) return;
      final error = ref.read(repoProvider).error;
      if (error != null) {
        _log.w('Background store check failed: $error');
        return;
      }
      if (!ref.read(settingsProvider).autoUpdateExtensions) return;
      final updated = await _installUpdates();
      if (updated > 0 && ref.mounted) {
        state = ExtensionAutoUpdateNotice(updated);
      }
    } catch (error) {
      _log.w('Background store check failed: $error');
    }
  }

  List<RepoExtension> _candidates() => selectExtensionAutoUpdates(
    storeExtensions: ref.read(repoProvider).extensions,
    installed: ref.read(extensionProvider).extensions,
    attemptedTargets: _attemptedTargets,
  );

  /// Updates one extension at a time through the store's serialized path.
  Future<int> _installUpdates() async {
    var updated = 0;
    for (final planned in _candidates()) {
      await _waitForIdleDownloads();
      if (!ref.mounted || !ref.read(settingsProvider).autoUpdateExtensions) {
        break;
      }
      // The user may have disabled or updated it while downloads ran.
      final candidate = _candidates()
          .where((e) => e.id == planned.id)
          .firstOrNull;
      if (candidate == null) continue;
      final target = extensionUpdateTarget(candidate);
      _attemptedTargets.add(target);
      final success = await ref
          .read(repoProvider.notifier)
          .updateExtensionToDefaultPaths(candidate.id, quiet: true);
      if (success) {
        updated++;
        _log.i('Updated extension in the background: $target');
      } else {
        _log.w(
          'Background extension update failed, kept the old version: '
          '$target',
        );
      }
      if (!ref.mounted) break;
    }
    return updated;
  }

  /// Completes when no download is queued or running. Listens to the queue
  /// instead of polling it.
  Future<void> _waitForIdleDownloads() async {
    if (isDownloadQueueIdle(ref.read(downloadQueueProvider))) return;
    _log.d('Waiting for downloads to finish before updating extensions');
    final waiter = _idleWaiter = Completer<void>();
    final subscription = ref.listen<bool>(
      downloadQueueProvider.select(isDownloadQueueIdle),
      (_, idle) {
        if (idle && !waiter.isCompleted) waiter.complete();
      },
    );
    try {
      await waiter.future;
    } finally {
      subscription.close();
      if (identical(_idleWaiter, waiter)) _idleWaiter = null;
    }
  }
}

final extensionAutoUpdateProvider =
    NotifierProvider<ExtensionAutoUpdateNotifier, ExtensionAutoUpdateNotice?>(
      ExtensionAutoUpdateNotifier.new,
    );
