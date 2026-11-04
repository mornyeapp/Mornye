import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

/// The artist's newest album, with a short note and a download action.
///
/// The note is the provider's editorial text. Most providers have none, and
/// those albums describe themselves by their type, year and track count.
class ArtistFeaturedAlbumCard extends StatefulWidget {
  const ArtistFeaturedAlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    required this.onDownload,
    this.loadMetadata,
  });

  final ArtistAlbum album;
  final VoidCallback onTap;
  final VoidCallback onDownload;

  /// Reads the album's metadata for its editorial note; null when no provider
  /// can be asked.
  final Future<Map<String, dynamic>> Function()? loadMetadata;

  @override
  State<ArtistFeaturedAlbumCard> createState() =>
      _ArtistFeaturedAlbumCardState();
}

class _ArtistFeaturedAlbumCardState extends State<ArtistFeaturedAlbumCard> {
  String? _note;
  int _noteGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  @override
  void didUpdateWidget(ArtistFeaturedAlbumCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.id == widget.album.id &&
        oldWidget.album.providerId == widget.album.providerId) {
      return;
    }
    _note = null;
    _loadNote();
  }

  Future<void> _loadNote() async {
    final generation = ++_noteGeneration;
    final load = widget.loadMetadata;
    if (load == null) return;
    final String? note;
    try {
      final metadata = await load();
      final info = metadata['album_info'];
      final html = albumDescriptionFromMetadata(
        info is Map<String, dynamic> ? info : metadata,
      );
      note = html == null ? null : parseEditorialNotes(html).text?.trim();
    } catch (_) {
      // The card already reads well without its note.
      return;
    }
    if (!mounted || generation != _noteGeneration || note == null) return;
    setState(() => _note = note);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final album = widget.album;
    final caption = TextStyle(
      fontSize: 13,
      height: 1.25,
      color: Colors.white.withValues(alpha: 0.7),
    );
    final summary = [
      switch (album.albumType) {
        'ep' => l10n.releaseTypeEp,
        'single' => l10n.releaseTypeSingle,
        _ => l10n.recentTypeAlbum,
      },
      if (album.releaseDate.isNotEmpty) album.releaseDate.split('-').first,
      if (album.totalTracks > 0) l10n.tracksCount(album.totalTracks),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Material(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox.square(
                    dimension: 96,
                    child: album.coverUrl != null
                        ? CachedCoverImage(
                            imageUrl: album.coverUrl!,
                            fit: BoxFit.cover,
                          )
                        : const Icon(CupertinoIcons.square_stack, size: 36),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.artistLatestRelease, style: caption),
                      const SizedBox(height: 2),
                      Text(
                        album.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _note ?? summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                HeaderCircleButton(
                  icon: CupertinoIcons.arrow_down,
                  buttonSize: 32,
                  iconSize: 16,
                  tonal: true,
                  tooltip: l10n.dialogDownload,
                  onPressed: widget.onDownload,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
