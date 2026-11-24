import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/app_crash_report.dart';
import 'package:mornye/providers/app_crash_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/expressive_button.dart';

/// Home notice for a crash saved by the previous session. Styled like
/// `ErrorCard`; the full report opens in a sheet instead of expanding inline,
/// so Home never nests a second scroll area.
class AppCrashBanner extends ConsumerStatefulWidget {
  const AppCrashBanner({super.key, this.diagnostic = false});

  /// Allows opening the latest saved report even after its Home notice was seen.
  final bool diagnostic;

  @override
  ConsumerState<AppCrashBanner> createState() => _AppCrashBannerState();
}

class _AppCrashBannerState extends ConsumerState<AppCrashBanner> {
  String? _shownId;

  @override
  Widget build(BuildContext context) {
    final crash = widget.diagnostic
        ? ref.watch(latestAppCrashProvider).value
        : ref.watch(appCrashProvider).value;
    if (crash == null) return const SizedBox.shrink();
    final noticeVisible =
        !widget.diagnostic &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (noticeVisible && _shownId != crash.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !widget.diagnostic &&
            _shownId != crash.id &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.isCurrentOf(context) ?? true)) {
          _shownId = crash.id;
          ref.read(appCrashProvider.notifier).markShown(crash.id);
        }
      });
    }
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final inset = 16 + wideListInset(context);
    return Padding(
      // Aligned with the Home search bar, including the tablet inset.
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 16),
      child: AppContentCard(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colorScheme.errorContainer,
        mornyeSurface: false,
        shape: RoundedRectangleBorder(borderRadius: tokens.borderRadiusCard),
        child: Padding(
          padding: EdgeInsets.all(tokens.gapLg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon.adaptive(
                Icons.error_outline,
                color: colorScheme.onErrorContainer,
              ),
              SizedBox(width: tokens.gapMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      crash.isAnr ? l10n.appAnrTitle : l10n.appCrashTitle,
                      style: TextStyle(
                        color: colorScheme.onErrorContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: tokens.gapXs),
                    Text(
                      crash.isAnr ? l10n.appAnrMessage : l10n.appCrashMessage,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                    SizedBox(height: tokens.gapSm),
                    Text(
                      crash.description.isEmpty
                          ? crash.reason
                          : crash.description,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                    SizedBox(height: tokens.gapMd),
                    Wrap(
                      spacing: tokens.gapSm,
                      runSpacing: tokens.gapSm,
                      children: [
                        ExpressiveButton(
                          tonal: true,
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () => _copy(context, crash),
                          child: Text(l10n.appCrashCopy),
                        ),
                        ExpressiveButton(
                          text: true,
                          onPressed: () => _showReport(context, crash),
                          child: Text(l10n.appCrashDetails),
                        ),
                        if (!widget.diagnostic)
                          ExpressiveButton(
                            text: true,
                            onPressed: () => _dismiss(context, ref, crash),
                            child: Text(l10n.appCrashDismiss),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReport(BuildContext context, AppCrashReport crash) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.appCrashDetails,
      dialogSize: AppDialogSize.wide,
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        padding: EdgeInsets.fromLTRB(
          tokens.gapXl,
          tokens.gapSm,
          tokens.gapXl,
          tokens.gapXl,
        ),
        child: SelectableText(
          crash.report,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'monospace',
            color: colorScheme.onSurface,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Future<void> _dismiss(
    BuildContext context,
    WidgetRef ref,
    AppCrashReport crash,
  ) async {
    try {
      await ref.read(appCrashProvider.notifier).dismiss(crash.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.appCrashDismissFailed)),
        );
      }
    }
  }

  Future<void> _copy(BuildContext context, AppCrashReport crash) async {
    final l10n = context.l10n;
    try {
      await Clipboard.setData(ClipboardData(text: crash.report));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.logCopied)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.appCrashCopyFailed)));
      }
    }
  }
}
