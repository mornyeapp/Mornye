import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const openAudioExtensions = [
  'flac',
  'alac',
  'wav',
  'aiff',
  'aif',
  'opus',
  'ogg',
  'mp3',
  'aac',
  'm4a',
];

class OpenAudioFile {
  const OpenAudioFile(this.source, {this.name});
  final String source;
  final String? name;

  static OpenAudioFile? parse(Object? value) {
    final source = value is String
        ? value
        : value is Map
        ? value['source']
        : null;
    final name = value is Map ? value['name'] : null;
    if (source is! String || source.isEmpty || source.contains('\u0000')) {
      return null;
    }
    if (source.startsWith('content://')) {
      return OpenAudioFile(source, name: name is String ? name : null);
    }
    var path = source;
    if (source.startsWith('file:')) {
      final uri = Uri.tryParse(source);
      if (uri == null || uri.hasQuery || uri.hasFragment) return null;
      try {
        path = uri.toFilePath();
      } on Object {
        return null;
      }
    }
    if (!p.isAbsolute(path)) return null;
    return OpenAudioFile(p.normalize(path), name: name is String ? name : null);
  }

  String get displayName => name ?? p.basename(source);
  bool get isAudio {
    final extension = p.extension(displayName);
    return extension.isNotEmpty &&
        openAudioExtensions.contains(extension.substring(1).toLowerCase());
  }
}

/// Holds OS file-open events until the main shell can start playback.
/// Each event is a queue; repeated explicit opens are not discarded.
class AudioFileOpenService {
  AudioFileOpenService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.zarz.mornye/open_audio');

  static final instance = AudioFileOpenService();
  final MethodChannel _channel;
  final _requests = StreamController<List<OpenAudioFile>>.broadcast();
  final _pending = Queue<List<OpenAudioFile>>();
  bool _initialized = false;

  Stream<List<OpenAudioFile>> get requests => _requests.stream;

  List<List<OpenAudioFile>> takePending() {
    final pending = _pending.toList(growable: false);
    _pending.clear();
    return pending;
  }

  void receive(Iterable<Object?> values) {
    final files = values
        .map(OpenAudioFile.parse)
        .whereType<OpenAudioFile>()
        .toList();
    if (files.isEmpty) return;
    if (_requests.hasListener) {
      _requests.add(files);
    } else {
      if (_pending.length >= 32) _pending.removeFirst();
      _pending.add(files);
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is List) {
        receive(call.arguments as List);
      } else if (call.method == 'ready') {
        // Android can attach its activity after a widget has started the
        // shared player engine in the background.
        await _drainNativePending();
      }
    });
    await _drainNativePending();
  }

  Future<void> _drainNativePending() async {
    try {
      final batches = await _channel.invokeListMethod<Object?>('takePending');
      for (final batch in batches ?? const []) {
        if (batch is List) receive(batch);
      }
    } on MissingPluginException {
      // Tests and hosts that have not yet installed the native file handler.
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _requests.close();
    _pending.clear();
  }
}

/// Expands explicit file/folder selections without writing Library sources.
/// Never follows directory symlinks, and bounds accidental huge selections.
Future<List<OpenAudioFile>> collectOpenAudioFiles(
  Iterable<OpenAudioFile> inputs, {
  int limit = 10000,
}) async {
  final files = <String, OpenAudioFile>{};
  void add(OpenAudioFile file) {
    if (!file.isAudio) return;
    if (!files.containsKey(file.source) && files.length >= limit) {
      throw const FileSystemException('Too many audio files selected');
    }
    files.putIfAbsent(file.source, () => file);
  }

  for (final input in inputs) {
    if (input.source.startsWith('content://')) {
      add(input);
    } else if (await FileSystemEntity.isDirectory(input.source)) {
      final children = <OpenAudioFile>[];
      await for (final entity in Directory(
        input.source,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File && OpenAudioFile(entity.path).isAudio) {
          if (children.length >= limit) {
            throw const FileSystemException('Too many audio files selected');
          }
          children.add(OpenAudioFile(entity.path));
        }
      }
      children.sort(
        (a, b) => a.source.toLowerCase().compareTo(b.source.toLowerCase()),
      );
      for (final child in children) {
        add(child);
      }
    } else if (await File(input.source).exists()) {
      add(input);
    }
  }
  return files.values.toList(growable: false);
}
