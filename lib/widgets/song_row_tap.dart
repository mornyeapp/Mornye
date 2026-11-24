import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/track_card.dart';

/// Whether a tap on a Library song row plays the song, with the row's
/// button opening its details, rather than the reverse, which is the
/// default ([AppSettings.librarySongTap]).
final librarySongTapPlaysProvider = Provider<bool>(
  (ref) => ref.watch(
    settingsProvider.select(
      (s) => s.librarySongTap == AppSettings.librarySongTapPlay,
    ),
  ),
);

/// The tap of a song row that has both a details page and a play button:
/// [play], which should do what the play button does, when
/// [librarySongTapPlaysProvider] is on, else [openDetails]. The setting is
/// read at the tap, so rows built before a change follow it.
///
/// Rows without a play action keep their own tap, and selection mode stays
/// with the caller. A CUE virtual track at [path] cannot play before it is
/// split, so its tap always opens the details.
VoidCallback songRowTap(
  WidgetRef ref, {
  required VoidCallback openDetails,
  required VoidCallback play,
  String? path,
}) =>
    () => ref.read(librarySongTapPlaysProvider) && !isCueVirtualPath(path)
    ? play()
    : openDetails();

/// How a [SongRowButton] lays out its details button.
enum SongRowButtonSize {
  /// A row button with the full touch target.
  list,

  /// The 32dp pointer target of desktop table rows.
  dense,

  /// The small circle over a grid cell's cover ([TrackGridPlayButton]).
  grid,
}

/// The trailing button of a song row that has both a details page and a play
/// button: [playButton], or a details button running [onOpenDetails] while a
/// tap on the row plays (see [songRowTap]). A CUE virtual track at [path]
/// keeps [playButton], because its tap opens the details.
class SongRowButton extends ConsumerWidget {
  const SongRowButton({
    super.key,
    required this.playButton,
    required this.onOpenDetails,
    this.size = SongRowButtonSize.list,
    this.path,
  });

  final Widget playButton;
  final VoidCallback onOpenDetails;
  final SongRowButtonSize size;
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(librarySongTapPlaysProvider) || isCueVirtualPath(path)) {
      return playButton;
    }
    final tooltip = context.l10n.desktopMenuShowDetails;
    // A page of text, not the circled "i": beside a row's circled error
    // sign the two read as the same warning.
    const glyph = Icons.article_outlined;
    if (size == SongRowButtonSize.grid) {
      return TrackGridPlayButton(
        tooltip: tooltip,
        onPressed: onOpenDetails,
        icon: context.adaptiveIcon(glyph),
        compact: true,
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final dense = size == SongRowButtonSize.dense;
    return AppIconButton(
      tooltip: tooltip,
      onPressed: onOpenDetails,
      icon: AppIcon.adaptive(
        glyph,
        // Smaller than the play glyph it replaces: details are the lesser
        // action of the row.
        size: dense ? 16 : 20,
        color: context.isMornye
            ? colorScheme.primary
            : colorScheme.onSurfaceVariant,
      ),
      style: IconButton.styleFrom(
        minimumSize: Size.square(dense ? 32 : context.tokens.minTouchTarget),
        padding: dense ? EdgeInsets.zero : null,
        tapTargetSize: dense ? MaterialTapTargetSize.shrinkWrap : null,
      ),
    );
  }
}
