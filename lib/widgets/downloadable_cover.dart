import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/cover_download_service.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

/// Adds the app-wide long-press-to-save behavior to a remote cover image.
///
/// The child keeps its normal tap behavior. Only the long-press gesture is
/// claimed here, so a surrounding track or collection card can still open its
/// usual options when the user presses outside the artwork.
class DownloadableCover extends ConsumerStatefulWidget {
  final String? coverUrl;
  final String baseName;
  final Widget child;
  final bool enabled;

  const DownloadableCover({
    super.key,
    required this.coverUrl,
    required this.baseName,
    required this.child,
    this.enabled = true,
  });

  @override
  ConsumerState<DownloadableCover> createState() => _DownloadableCoverState();
}

class _DownloadableCoverState extends ConsumerState<DownloadableCover> {
  bool _saving = false;

  String get _coverUrl => normalizeRemoteHttpUrl(widget.coverUrl) ?? '';

  Future<void> _saveCover() async {
    if (_saving) return;
    final coverUrl = _coverUrl;
    if (coverUrl.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.trackCoverNoSource)));
      return;
    }

    setState(() => _saving = true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.updateDownloading)));

    try {
      final saved = await CoverDownloadService.saveRemoteCover(
        coverUrl: coverUrl,
        baseName: widget.baseName,
        settings: ref.read(settingsProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.trackCoverSaved(saved.fileName))),
        );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.trackSaveFailed(context.friendlyError(error)),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = widget.enabled && _coverUrl.isNotEmpty;
    final semanticLabel =
        '${context.l10n.dialogDownload} '
        '${context.l10n.editMetadataFieldCover}: ${widget.baseName}';

    return Semantics(
      button: canSave,
      label: semanticLabel,
      onLongPress: canSave ? _saveCover : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: canSave ? _saveCover : null,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_saving)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x33000000),
                  child: Center(
                    child: AppLoadingIndicator(size: 22, strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
