import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/audio_file_open_service.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:path/path.dart' as p;

final openAudioControllerProvider = NotifierProvider<OpenAudioController, bool>(
  OpenAudioController.new,
);

class OpenAudioController extends Notifier<bool> {
  int _request = 0;
  final _hydrated = <String>{};
  final _iosLeases = <IosSecurityScopedAccess>[];

  @override
  bool build() {
    ref.listen(localMediaItemProvider, (_, next) {
      final item = next.value;
      if (item == null ||
          !item.id.startsWith('opened:') ||
          !_hydrated.add(item.id)) {
        return;
      }
      final source = item.extras?['source'];
      if (source is String) {
        unawaited(
          ref
              .read(musicPlayerRuntimeProvider)
              .handler
              ?.onSourceMetadataChanged(source),
        );
      }
    });
    ref.onDispose(() {
      _request++;
      for (final token in _iosLeases) {
        unawaited(PlatformBridge.stopAccessingIosBookmark(token));
      }
    });
    return false;
  }

  Future<void> pickFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: openAudioExtensions,
    );
    if (!ref.mounted || result.isEmpty) return;
    await open([
      for (final file in result)
        if (file.path case final path?) OpenAudioFile(path, name: file.name),
    ]);
  }

  Future<void> pickFolder() async {
    if (Platform.isAndroid) {
      final folder = await PlatformBridge.pickSafTree();
      if (!ref.mounted || folder == null) return;
      final uri = folder['tree_uri'];
      if (uri is! String) return;
      final files = await PlatformBridge.listSafAudioFiles(uri);
      if (!ref.mounted) return;
      await open(files.map(OpenAudioFile.parse).whereType<OpenAudioFile>());
      return;
    }
    if (Platform.isIOS) {
      final folder = await PlatformBridge.pickIosDirectory();
      if (!ref.mounted || folder == null) return;
      final access = await PlatformBridge.startAccessingIosBookmark(
        folder.bookmark,
      );
      if (access == null) {
        throw const FileSystemException('Folder access was not granted');
      }
      if (!ref.mounted) {
        await PlatformBridge.stopAccessingIosBookmark(access);
        return;
      }
      await open([OpenAudioFile(access.path)], access: access);
      return;
    }
    final path = await FilePicker.getDirectoryPath();
    if (ref.mounted && path != null) await open([OpenAudioFile(path)]);
  }

  Future<void> open(
    Iterable<OpenAudioFile> inputs, {
    IosSecurityScopedAccess? access,
  }) async {
    final request = ++_request;
    var retainedAccess = false;
    state = true;
    try {
      final files = await collectOpenAudioFiles(inputs);
      if (!ref.mounted || request != _request) return;
      if (files.isEmpty) {
        throw const FileSystemException('No supported audio files found');
      }
      // An explicit Open with Mornye request must not launch the OS handler
      // again when the user's ordinary Library player is external.
      if (ref.read(settingsProvider).playerMode != 'internal') {
        ref.read(settingsProvider.notifier).setPlayerMode('internal');
      }
      if (!ref.mounted || request != _request) return;
      _hydrated.clear();
      await ref.read(musicPlayerControllerProvider).playAll([
        for (final file in files)
          PlayableMedia(
            id: 'opened:${file.source}',
            source: file.source,
            title: p.basenameWithoutExtension(file.displayName),
            artist: '',
            format: audioFormatForPath(file.displayName),
          ),
      ], initialIndex: 0);
      if (!ref.mounted || request != _request) return;
      final oldLeases = _iosLeases.toList();
      _iosLeases.clear();
      if (access != null) {
        _iosLeases.add(access);
        retainedAccess = true;
      }
      for (final old in oldLeases) {
        await PlatformBridge.stopAccessingIosBookmark(old);
      }
    } finally {
      if (access != null && !retainedAccess) {
        await PlatformBridge.stopAccessingIosBookmark(access);
      }
      if (ref.mounted && request == _request) state = false;
    }
  }
}
