import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/expressive_button.dart';

/// Error card shown by detail screens: a dedicated rate-limit presentation
/// when the message looks like an HTTP 429, otherwise a generic error row.
///
/// Pass [onRetry] so the card offers a way out; a message with no action leaves
/// the user stuck on a dead screen.
class ErrorCard extends StatelessWidget {
  const ErrorCard({
    super.key,
    required this.error,
    required this.colorScheme,
    this.onRetry,
  });

  final String error;
  final ColorScheme colorScheme;

  /// Re-runs whatever failed. Omit only when the failure is deterministic
  /// (e.g. an unrecognized URL), where retrying cannot help.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final displayError = context.friendlyError(error);
    final isRateLimit =
        error.contains('429') ||
        error.toLowerCase().contains('rate limit') ||
        error.toLowerCase().contains('too many requests');

    final title = isRateLimit ? context.l10n.errorRateLimited : null;
    final message = isRateLimit
        ? context.l10n.errorRateLimitedMessage
        : displayError;
    final icon = isRateLimit ? Icons.timer_off : Icons.error_outline;
    // A solid container with its paired on-color keeps text contrast.
    final background = colorScheme.errorContainer;
    final foreground = colorScheme.onErrorContainer;

    return AppContentCard(
      elevation: 0,
      color: background,
      mornyeSurface: false,
      shape: RoundedRectangleBorder(borderRadius: tokens.borderRadiusCard),
      child: Padding(
        padding: EdgeInsets.all(tokens.gapLg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon.adaptive(icon, color: foreground),
            SizedBox(width: tokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null) ...[
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: tokens.gapXs),
                  ],
                  Text(
                    message,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: foreground),
                  ),
                  if (onRetry != null) ...[
                    SizedBox(height: tokens.gapMd),
                    ExpressiveButton(
                      tonal: true,
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      child: Text(context.l10n.dialogRetry),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty-state block with an optional call to action.
/// [action] provides an optional recovery path.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.gapXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (context.isMornye)
              AppIcon.adaptive(
                icon,
                size: 64,
                color: colorScheme.onSurfaceVariant,
              )
            else
              AppShapeBadge(
                kind: AppShapes.badge,
                size: 112,
                color: colorScheme.secondaryContainer,
                child: AppIcon(
                  icon,
                  size: 52,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            SizedBox(height: tokens.gapLg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (message != null) ...[
              SizedBox(height: tokens.gapSm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[SizedBox(height: tokens.gapXl), action!],
          ],
        ),
      ),
    );
  }
}
