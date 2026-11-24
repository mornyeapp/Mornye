import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/services/metadata_autofill_service.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

class MetadataCandidateTile extends StatelessWidget {
  final Map<String, dynamic> candidate;
  final VoidCallback onTap;

  /// Where the result comes from and how well it fits, as the last line.
  final String? source;

  const MetadataCandidateTile({
    super.key,
    required this.candidate,
    required this.onTap,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    final title = (candidate['name'] ?? candidate['title'] ?? '')
        .toString()
        .trim();
    final artists = (candidate['artists'] ?? candidate['artist'] ?? '')
        .toString()
        .trim();
    final album = (candidate['album_name'] ?? candidate['album'] ?? '')
        .toString()
        .trim();
    final date = candidate['release_date']?.toString().trim() ?? '';
    final isrc = candidate['isrc']?.toString().trim() ?? '';
    final subtitle = [
      artists,
      album,
      if (date.isNotEmpty) date,
      if (isrc.isNotEmpty) 'ISRC ${formatIsrcForDisplay(isrc)}',
      ?source?.trim(),
    ].where((value) => value.isNotEmpty).join('\n');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _MetadataCandidateArtwork(
        coverUrl: MetadataAutofillService().coverUrl(candidate),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 5, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _MetadataCandidateArtwork extends StatefulWidget {
  final String? coverUrl;

  const _MetadataCandidateArtwork({required this.coverUrl});

  @override
  State<_MetadataCandidateArtwork> createState() =>
      _MetadataCandidateArtworkState();
}

class _MetadataCandidateArtworkState extends State<_MetadataCandidateArtwork> {
  final _covers = MetadataCoverResources();
  String? _coverPath;
  String? _tempDir;
  ({int width, int height, int bytes})? _details;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.coverUrl?.isNotEmpty == true) {
      unawaited(_loadCover());
    }
  }

  Future<void> _loadCover() async {
    final generation = ++_generation;
    final preview = await _covers.download(widget.coverUrl!);
    if (!mounted || generation != _generation) {
      await _covers.release(preview?.tempDir);
      return;
    }
    setState(() {
      _coverPath = preview?.path;
      _tempDir = preview?.tempDir;
      _details = preview?.details;
    });
  }

  @override
  void didUpdateWidget(covariant _MetadataCandidateArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.coverUrl == oldWidget.coverUrl) return;
    _generation++;
    unawaited(_covers.release(_tempDir));
    _tempDir = null;
    _coverPath = null;
    _details = null;
    if (widget.coverUrl?.isNotEmpty == true) unawaited(_loadCover());
  }

  @override
  void dispose() {
    unawaited(_covers.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final coverUrl = widget.coverUrl;
    final details = _details;
    final image = _coverPath != null
        ? Image.file(
            File(_coverPath!),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
            cacheHeight: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
            filterQuality: FilterQuality.low,
          )
        : coverUrl != null
        ? CachedCoverImage(
            imageUrl: coverUrl,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
          )
        : Container(
            width: 56,
            height: 56,
            color: colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.music_note),
          );

    return SizedBox(
      width: 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(10), child: image),
          if (details != null) ...[
            const SizedBox(height: 3),
            Text(
              '${details.width}×${details.height} · '
              '${(details.bytes / 1024).toStringAsFixed(1)} KB',
              maxLines: 2,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontSize: 9,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
