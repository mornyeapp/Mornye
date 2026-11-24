import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/l10n/l10n.dart';

/// Compact folder badge shown next to a track that already exists in the
/// local library or download history.
class InLibraryBadge extends StatelessWidget {
  const InLibraryBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: context.l10n.libraryInLibrary,
      child: Container(
        padding: context.tokens.badgePadding,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: context.tokens.borderRadiusBadge,
        ),
        child: Icon(
          Icons.folder_outlined,
          size: 14,
          color: colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
