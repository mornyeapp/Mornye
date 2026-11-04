import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/album_track_order.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// A play button that appears over artwork while the pointer is on it, on
/// desktop. Place it in the artwork's [Stack]; it fills the stack to track
/// the hover and shows the button in the bottom-leading corner. Phones and
/// tablets get nothing: their tiles keep the tap to open.
class DesktopHoverPlayButton extends StatefulWidget {
  const DesktopHoverPlayButton({
    super.key,
    required this.tooltip,
    required this.onPlay,
  });

  final String tooltip;
  final VoidCallback? onPlay;

  /// Visible circle; the pointer target is [_target].
  static const double _diameter = 36;
  static const double _mornyeDiameter = 30;
  static const double _target = 40;

  /// Dims the artwork behind the Mornye button, as in Music.
  static const Color _mornyeScrim = Color(0x4D333333);

  /// Corner radius of the Mornye tiles this button sits on.
  static const double _mornyeRadius = 8;

  @override
  State<DesktopHoverPlayButton> createState() => _DesktopHoverPlayButtonState();
}

class _DesktopHoverPlayButtonState extends State<DesktopHoverPlayButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform || widget.onPlay == null) {
      return const SizedBox.shrink();
    }
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final visible = _hovered || _focused;
    // Mornye follows Apple Music's light disc; Material uses its primary FAB
    // colors.
    final background = mornye
        ? Colors.white.withValues(alpha: 0.92)
        : colorScheme.primaryContainer;
    final foreground = mornye ? Colors.black : colorScheme.onPrimaryContainer;
    final diameter = mornye
        ? DesktopHoverPlayButton._mornyeDiameter
        : DesktopHoverPlayButton._diameter;
    final fade = Duration(milliseconds: mornye ? 100 : 120);
    final fadeCurve = mornye ? Curves.easeIn : Curves.linear;
    final button = Align(
      alignment: AlignmentDirectional.bottomStart,
      child: Padding(
        // The visible circle sits 10 from the Mornye artwork's corner; the
        // target around it is larger.
        padding: EdgeInsets.all(mornye ? 5 : 6),
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: fade,
          curve: fadeCurve,
          child: IgnorePointer(
            ignoring: !visible,
            child: Focus(
              canRequestFocus: false,
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: IconButton(
                tooltip: widget.tooltip,
                onPressed: widget.onPlay,
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(DesktopHoverPlayButton._target),
                  minimumSize: const Size.square(
                    DesktopHoverPlayButton._target,
                  ),
                  shape: const CircleBorder(),
                  backgroundColor: Colors.transparent,
                ),
                icon: Container(
                  width: diameter,
                  height: diameter,
                  decoration: BoxDecoration(
                    color: background,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(blurRadius: 6, color: Color(0x33000000)),
                    ],
                  ),
                  child: Icon(
                    mornye
                        ? mornyeIconFor(Icons.play_arrow)
                        : Icons.play_arrow_rounded,
                    size: mornye ? 16 : 22,
                    color: foreground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: !mornye
            ? button
            : Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    child: AnimatedOpacity(
                      key: const ValueKey('desktop-hover-scrim'),
                      opacity: visible ? 1 : 0,
                      duration: fade,
                      curve: fadeCurve,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: DesktopHoverPlayButton._mornyeScrim,
                          borderRadius: BorderRadius.circular(
                            DesktopHoverPlayButton._mornyeRadius,
                          ),
                        ),
                      ),
                    ),
                  ),
                  button,
                ],
              ),
      ),
    );
  }
}

/// Plays a downloaded album from its first track, in disc and track order.
Future<void> playDownloadedAlbum(
  WidgetRef ref, {
  required String albumName,
  required String artistName,
}) async {
  final rows = await HistoryDatabase.instance.getAlbumTracks(
    albumName,
    artistName,
  );
  final tracks = AlbumTrackOrder(
    rows.map(DownloadHistoryItem.fromJson),
    discNumber: (track) => track.discNumber,
    trackNumber: (track) => track.trackNumber,
    trackName: (track) => track.trackName,
  ).tracks;
  if (tracks.isEmpty) return;
  await ref
      .read(playbackProvider.notifier)
      .playHistoryQueue(tracks, startItem: tracks.first);
}

/// Plays a scanned album from its first track, in disc and track order.
Future<void> playLocalAlbum(
  WidgetRef ref,
  Iterable<LocalLibraryItem> items,
) async {
  final tracks = AlbumTrackOrder(
    items,
    discNumber: (track) => track.discNumber,
    trackNumber: (track) => track.trackNumber,
    trackName: (track) => track.trackName,
  ).tracks;
  if (tracks.isEmpty) return;
  await ref
      .read(playbackProvider.notifier)
      .playLocalLibraryQueue(tracks, startItem: tracks.first);
}
