import 'package:flutter/widgets.dart';
import 'package:mornye/utils/desktop_platform.dart';

int coverCacheWidthForViewport(
  BuildContext context, {
  double widthMultiplier = 1.0,
  int min = 320,
  int max = 2048,
}) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final logicalWidth = MediaQuery.sizeOf(context).width * widthMultiplier;
  return (logicalWidth * dpr).round().clamp(min, max);
}

/// The largest side of the artwork in a desktop detail page's header.
const double desktopDetailArtworkMaxSize = 300;

/// A landscape header cover, such as a 16:9 video thumbnail, decoded this
/// much wider still fills the square header's height.
const double _widestHeaderCoverAspect = 16 / 9;

/// The decode width of a detail page's header cover. Phones show it across
/// the screen; desktop decodes it once at its largest header size instead of
/// again for every pane width.
int detailHeaderCoverCacheWidth(BuildContext context) => isDesktopPlatform
    ? (desktopDetailArtworkMaxSize *
              _widestHeaderCoverAspect *
              MediaQuery.devicePixelRatioOf(context))
          .ceil()
    : coverCacheWidthForViewport(context);
