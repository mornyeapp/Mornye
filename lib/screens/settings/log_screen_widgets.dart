part of 'log_screen.dart';

final RegExp _domainPattern = RegExp(
  r'domain:\s*([^\s,]+)',
  caseSensitive: false,
);

class _LogEntryTile extends StatelessWidget {
  final LogEntry entry;
  final Color levelColor;
  final bool showDivider;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _LogEntryTile({
    required this.entry,
    required this.levelColor,
    this.showDivider = true,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isError = entry.level == 'ERROR' || entry.level == 'FATAL';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          container: true,
          selected: selected,
          onTap: selectionMode ? onTap : null,
          onLongPress: onLongPress,
          child: InkWell(
            excludeFromSemantics: true,
            onTap: selectionMode ? onTap : null,
            onLongPress: onLongPress,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                    : isError
                    ? colorScheme.errorContainer.withValues(alpha: 0.2)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        entry.formattedTime,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: levelColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          entry.level,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: levelColor,
                          ),
                        ),
                      ),
                      if (entry.isFromNative) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Native',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.tag,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.primary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selectionMode) ...[
                        const SizedBox(width: 8),
                        AppIcon(
                          selected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color: selected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.previewMessage,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: colorScheme.onSurface,
                      height: 1.4,
                    ),
                  ),
                  if (entry.previewError != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.previewError!,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: colorScheme.error,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            indent: 20,
            endIndent: 20,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }
}

class _LogSummaryCard extends StatelessWidget {
  final List<LogEntry> logs;

  const _LogSummaryCard({required this.logs});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final analysis = _analyzeLogs();

    if (!analysis.hasIssues) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AppContentCard(
        elevation: 0,
        mornyeSurface: false,
        color: analysis.hasISPBlocking
            ? colorScheme.errorContainer.withValues(alpha: 0.5)
            : colorScheme.tertiaryContainer.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(
                    analysis.hasISPBlocking
                        ? Icons.block
                        : Icons.warning_amber_rounded,
                    size: 20,
                    color: analysis.hasISPBlocking
                        ? colorScheme.error
                        : colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.logIssueSummary,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (analysis.hasISPBlocking) ...[
                _IssueBadge(
                  icon: Icons.block,
                  label: context.l10n.logIssueIspBlockingLabel,
                  description: context.l10n.logIssueIspBlockingDescription,
                  suggestion: context.l10n.logIssueIspBlockingSuggestion,
                  color: colorScheme.error,
                  domains: analysis.blockedDomains,
                ),
                const SizedBox(height: 8),
              ],

              if (analysis.hasRateLimit) ...[
                _IssueBadge(
                  icon: Icons.speed,
                  label: context.l10n.logIssueRateLimitedLabel,
                  description: context.l10n.logIssueRateLimitedDescription,
                  suggestion: context.l10n.logIssueRateLimitedSuggestion,
                  color: colorScheme.tertiary,
                ),
                const SizedBox(height: 8),
              ],

              if (analysis.hasNetworkError && !analysis.hasISPBlocking) ...[
                _IssueBadge(
                  icon: Icons.wifi_off,
                  label: context.l10n.logIssueNetworkErrorLabel,
                  description: context.l10n.logIssueNetworkErrorDescription,
                  suggestion: context.l10n.logIssueNetworkErrorSuggestion,
                  color: colorScheme.tertiary,
                ),
                const SizedBox(height: 8),
              ],

              if (analysis.hasNotFound) ...[
                _IssueBadge(
                  icon: Icons.search_off,
                  label: context.l10n.logIssueTrackNotFoundLabel,
                  description: context.l10n.logIssueTrackNotFoundDescription,
                  suggestion: context.l10n.logIssueTrackNotFoundSuggestion,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],

              const SizedBox(height: 12),
              Text(
                context.l10n.logTotalErrors(analysis.errorCount),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _LogAnalysis _analyzeLogs() {
    int errorCount = 0;
    bool hasISPBlocking = false;
    bool hasRateLimit = false;
    bool hasNetworkError = false;
    bool hasNotFound = false;
    final Set<String> blockedDomains = {};

    for (final log in logs) {
      if (log.level == 'ERROR' || log.level == 'FATAL') {
        errorCount++;
      }

      final msgLower = log.message.toLowerCase();
      final errorLower = (log.error ?? '').toLowerCase();
      final combined = '$msgLower $errorLower';

      if (combined.contains('isp blocking') ||
          combined.contains('isp may be') ||
          combined.contains('blocked by isp') ||
          combined.contains('connection reset') ||
          combined.contains('connection refused')) {
        hasISPBlocking = true;

        final domainMatch = _domainPattern.firstMatch(combined);
        if (domainMatch != null) {
          blockedDomains.add(domainMatch.group(1)!);
        }
      }

      if (combined.contains('rate limit') ||
          combined.contains('429') ||
          combined.contains('too many requests')) {
        hasRateLimit = true;
      }

      if (combined.contains('connection') ||
          combined.contains('timeout') ||
          combined.contains('network') ||
          combined.contains('dial')) {
        hasNetworkError = true;
      }

      if (combined.contains('not found') ||
          combined.contains('no results') ||
          combined.contains('could not find')) {
        hasNotFound = true;
      }
    }

    return _LogAnalysis(
      errorCount: errorCount,
      hasISPBlocking: hasISPBlocking,
      hasRateLimit: hasRateLimit,
      hasNetworkError: hasNetworkError,
      hasNotFound: hasNotFound,
      blockedDomains: blockedDomains.toList(),
    );
  }
}

class _LogAnalysis {
  final int errorCount;
  final bool hasISPBlocking;
  final bool hasRateLimit;
  final bool hasNetworkError;
  final bool hasNotFound;
  final List<String> blockedDomains;

  _LogAnalysis({
    required this.errorCount,
    required this.hasISPBlocking,
    required this.hasRateLimit,
    required this.hasNetworkError,
    required this.hasNotFound,
    required this.blockedDomains,
  });

  bool get hasIssues =>
      errorCount > 0 ||
      hasISPBlocking ||
      hasRateLimit ||
      hasNetworkError ||
      hasNotFound;
}

class _IssueBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final String suggestion;
  final Color color;
  final List<String>? domains;

  const _IssueBadge({
    required this.icon,
    required this.label,
    required this.description,
    required this.suggestion,
    required this.color,
    this.domains,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
          ),
          if (domains != null && domains!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              context.l10n.logAffectedDomains(domains!.join(', ')),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(
                Icons.lightbulb_outline,
                size: 14,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  suggestion,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
