import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';

/// Keeps a scanned thumbnail when available, recovering missing artwork from
/// the audio through the same bounded extraction cache used by the player.
class LocalLibraryArtworkBuilder extends StatefulWidget {
  const LocalLibraryArtworkBuilder({
    super.key,
    required this.coverPath,
    required this.filePath,
    required this.builder,
  });

  final String? coverPath;
  final String? filePath;
  final Widget Function(BuildContext context, String? coverPath) builder;

  @override
  State<LocalLibraryArtworkBuilder> createState() =>
      _LocalLibraryArtworkBuilderState();
}

class _LocalLibraryArtworkBuilderState
    extends State<LocalLibraryArtworkBuilder> {
  String? _coverPath;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _checkCover();
  }

  @override
  void didUpdateWidget(covariant LocalLibraryArtworkBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverPath != widget.coverPath ||
        oldWidget.filePath != widget.filePath) {
      _checkCover();
    }
  }

  Future<void> _checkCover() async {
    final generation = ++_generation;
    final candidate = widget.coverPath?.trim();
    _coverPath = candidate == null || candidate.isEmpty ? null : candidate;
    if (_coverPath == null) return;
    var available = false;
    try {
      final path = _coverPath!;
      if (path.startsWith('file://')) {
        _coverPath = Uri.parse(path).toFilePath();
      }
      final stat = await File(_coverPath!).stat();
      available = stat.type == FileSystemEntityType.file && stat.size > 0;
    } catch (_) {
      // An expired scan path must not hide recoverable embedded artwork.
    }
    if (available || !mounted || generation != _generation) return;
    setState(() => _coverPath = null);
  }

  void _onCoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cover =
        _coverPath ??
        DownloadedEmbeddedCoverResolver.resolve(
          widget.filePath,
          onChanged: _onCoverChanged,
        );
    return widget.builder(context, cover);
  }
}
