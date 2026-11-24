import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/source_metadata_events.dart';

/// Edits one seekable local copy, then publishes it back to the owning NAS.
/// Edits of the same source are serialized without blocking other songs.
class NetworkFileEditor {
  NetworkFileEditor({
    NetworkStorageService? storage,
    NetworkAudioAnalysisInput? input,
    Future<void> Function(String source)? changed,
    Future<Future<void> Function()> Function()? keepAwake,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _input = input ?? NetworkAudioAnalysisInput(storage: storage),
       _changed = changed ?? _notifyChanged,
       _keepAwake = keepAwake;

  static final instance = NetworkFileEditor(
    keepAwake: () => NotificationService().acquireNetworkEditWork(),
  );
  final NetworkStorageService _storage;
  final NetworkAudioAnalysisInput _input;
  final Future<void> Function(String source) _changed;
  // Keeps the save running when the screen turns off mid-transfer.
  final Future<Future<void> Function()> Function()? _keepAwake;
  final _pending = <String, Future<void>>{};

  Future<T> edit<T>(
    String source,
    Future<T> Function(String path) edit, {
    required bool Function(T result) succeeded,
    bool publishLyricsSidecar = false,
  }) {
    final result = (_pending[source] ?? Future<void>.value()).then((_) async {
      if (!await _storage.canEditFile(source)) {
        throw const FormatException('File editing requires SMB or WebDAV');
      }
      final release = await _keepAwake?.call();
      try {
        return await _input.withFile(source, (original) async {
          final input = File(original);
          final working = await input.copy(
            '${input.parent.path}/edited${_extension(input.path)}',
          );
          final result = await edit(working.path);
          if (succeeded(result)) {
            await _storage.replaceFile(source, working, original: input);
            try {
              if (publishLyricsSidecar) await _publishLyrics(source, working);
            } finally {
              // The audio was committed even if its optional sidecar failed.
              await _changed(source);
            }
          }
          return result;
        });
      } finally {
        await release?.call();
      }
    });
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[source] = tail;
    return result.whenComplete(() {
      if (identical(_pending[source], tail)) _pending.remove(source);
    });
  }

  /// Writes [file] as [destination], a file beside a song on an SMB or
  /// WebDAV connection, replacing one already there as Save Cover Art and
  /// Save Lyrics do on this device.
  Future<void> saveSidecar(String destination, File file) async {
    if (!await _storage.canEditFile(destination)) {
      throw const FormatException('File editing requires SMB or WebDAV');
    }
    final release = await _keepAwake?.call();
    try {
      await _replaceOrCreate(destination, file);
    } finally {
      await release?.call();
    }
  }

  Future<void> _publishLyrics(String source, File working) async {
    final sidecar = File(p.setExtension(working.path, '.lrc'));
    if (!await sidecar.exists()) return;
    final uri = Uri.parse(source);
    final destination = uri
        .replace(path: p.url.setExtension(uri.path, '.lrc'))
        .toString();
    await _replaceOrCreate(destination, sidecar);
  }

  /// Replaces the file at [destination] with [sidecar], checked against a
  /// copy of the old one, or uploads it without overwriting when none is
  /// there.
  Future<void> _replaceOrCreate(String destination, File sidecar) async {
    if (await _storage.editableFileExists(destination)) {
      await _input.withFile(destination, (original) async {
        await _storage.replaceFile(
          destination,
          sidecar,
          original: File(original),
        );
      });
    } else {
      await _storage.publishUpload(
        destination,
        sidecar,
        NetworkStorageService.newId(),
        checkpoint: () {},
        progress: (_, _) {},
      );
    }
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot);
  }

  static Future<void> _notifyChanged(String source) async {
    await NetworkMetadataService.instance.invalidate(
      source,
      refreshArtwork: true,
    );
    await SourceMetadataEvents.instance.publish(source);
  }
}
