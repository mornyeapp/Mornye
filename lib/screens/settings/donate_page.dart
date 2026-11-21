import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/donate_icons.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

/// Fill of the donate cards. Material puts them on the settings group tier;
/// Mornye keeps the tone it blends over its surface.
Color _donateCardColor(BuildContext context) {
  final theme = Theme.of(context);
  final colorScheme = theme.colorScheme;
  if (!context.isMornye) return colorScheme.surfaceContainer;
  final isDark = theme.brightness == Brightness.dark;
  return Color.alphaBlend(
    (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.08 : 0.04,
    ),
    colorScheme.surface,
  );
}

class DonatePage extends StatefulWidget {
  final AppRemoteConfigService? remoteConfigService;

  const DonatePage({super.key, this.remoteConfigService});

  @override
  State<DonatePage> createState() => _DonatePageState();
}

class _DonatePageState extends State<DonatePage> {
  DonateConfig _config = DonateConfig.fallback();
  bool _hasRequestedConfig = false;
  String? _activeRemoteJson;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasRequestedConfig) return;

    _hasRequestedConfig = true;
    unawaited(_loadConfig(Localizations.localeOf(context).toLanguageTag()));
  }

  Future<void> _loadConfig(String locale) async {
    final service = widget.remoteConfigService ?? AppRemoteConfigService();
    final cached = await service.readCachedConfig();
    if (!mounted) return;

    if (cached != null) {
      _applyRemoteConfig(cached);
    }

    final refreshed = await service.fetchConfigSnapshot(locale: locale);
    if (!mounted || refreshed == null) return;
    _applyRemoteConfig(refreshed);
  }

  void _applyRemoteConfig(RemoteConfigSnapshot snapshot) {
    if (_activeRemoteJson == snapshot.rawJson) return;

    setState(() {
      _activeRemoteJson = snapshot.rawJson;
      _config = snapshot.config.donate;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final monthlyGoal = _config.monthlyGoal;

    return MornyeSettingsTheme(
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: 'Donate'),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16 + wideListInset(context),
                  16,
                  16 + wideListInset(context),
                  16,
                ),
                child: Column(
                  children: [
                    if (monthlyGoal != null && monthlyGoal.isVisible) ...[
                      _MonthlyDonationGoalCard(goal: monthlyGoal),
                      const SizedBox(height: 16),
                    ],
                    _DonateLinksCard(colorScheme: colorScheme, config: _config),
                    const SizedBox(height: 16),
                    _RecentSupportersCard(supporters: _config.supporters),
                    const SizedBox(height: 16),
                    _DonateNoticeCard(
                      colorScheme: colorScheme,
                      notices: _config.notices,
                    ),
                  ],
                ),
              ),
            ),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }
}

class _MonthlyDonationGoalCard extends StatelessWidget {
  final MonthlyDonationGoal goal;

  const _MonthlyDonationGoalCard({required this.goal});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final numberFormat = NumberFormat('0.#', locale);
    final currencyFormat = NumberFormat.simpleCurrency(
      name: goal.currency,
      locale: locale,
    );
    var period = goal.period;
    if (RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(period)) {
      period = DateFormat.yMMMM(locale).format(DateTime.parse('$period-01'));
    }
    final cardColor = _donateCardColor(context);

    return AppContentCard(
      elevation: 0,
      mornyeSurface: false,
      color: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              goal.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            if (period.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                period,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (goal.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                goal.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (goal.showPercentage) ...[
              Text(
                '${numberFormat.format(goal.progressPercent)}%',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
            ],
            AppProgressIndicator.linear(
              wavy: false,
              value: goal.progressRatio,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              semanticsLabel: goal.title,
              semanticsValue: goal.showPercentage
                  ? '${numberFormat.format(goal.progressPercent)}%'
                  : null,
            ),
            if (goal.goalReached) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  AppIcon(
                    Icons.check_circle_outline,
                    size: 20,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Goal reached',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (goal.showAmounts &&
                goal.raisedAmount != null &&
                goal.targetAmount != null) ...[
              const SizedBox(height: 12),
              Text(
                '${currencyFormat.format(goal.raisedAmount)} / '
                '${currencyFormat.format(goal.targetAmount)}',
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (goal.showSourceBreakdown && goal.sources.isNotEmpty) ...[
              const SizedBox(height: 16),
              for (final entry in goal.sources.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    [
                      switch (entry.key) {
                        'kofi' => 'Ko-fi',
                        'patreon' => 'Patreon',
                        'manual' => 'Manual',
                        _ => entry.key,
                      },
                      if (goal.showAmounts && entry.value.amount != null)
                        currencyFormat.format(entry.value.amount),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DonateLinksCard extends StatelessWidget {
  final ColorScheme colorScheme;
  final DonateConfig config;

  const _DonateLinksCard({required this.colorScheme, required this.config});

  @override
  Widget build(BuildContext context) {
    final cardColor = _donateCardColor(context);

    return AppContentCard(
      elevation: 0,
      mornyeSurface: false,
      color: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Text(
              config.title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          // Material groups rows by the card alone; dividers are Mornye's.
          if (context.isMornye)
            Divider(
              height: 1,
              thickness: 1,
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          if (!config.enabled)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Donation links are currently unavailable.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (var index = 0; index < config.methods.length; index++) ...[
              _DonateMethodItem(
                method: config.methods[index],
                colorScheme: colorScheme,
              ),
              if (context.isMornye && index < config.methods.length - 1)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 74,
                  endIndent: 16,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
            ],
        ],
      ),
    );
  }
}

class _RecentSupportersCard extends StatelessWidget {
  const _RecentSupportersCard({required this.supporters});

  final List<String> supporters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppContentCard(
      elevation: 0,
      mornyeSurface: false,
      color: _donateCardColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon(
                  Icons.star_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recent Supporters',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Thank you for your generosity!',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (supporters.isEmpty)
              Text(
                'No recent supporters to show.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final name in supporters)
                    Chip(
                      backgroundColor: colorScheme.secondaryContainer,
                      side: BorderSide.none,
                      shape: const StadiumBorder(),
                      avatar: CircleAvatar(
                        backgroundColor: colorScheme.primary.withValues(
                          alpha: 0.2,
                        ),
                        child: Text(
                          name.isEmpty
                              ? '?'
                              : name.characters.first.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                      label: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _DonateNoticeCard extends StatelessWidget {
  final ColorScheme colorScheme;
  final List<String> notices;

  const _DonateNoticeCard({required this.colorScheme, required this.notices});

  @override
  Widget build(BuildContext context) {
    return AppContentCard(
      elevation: 0,
      mornyeSurface: false,
      color: colorScheme.secondaryContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon(
                  Icons.volunteer_activism_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Good to Know',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < notices.length; index++) ...[
              _NoticeLine(
                icon: _noticeIcon(index),
                text: notices[index],
                colorScheme: colorScheme,
              ),
              if (index < notices.length - 1) const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _DonateMethodItem extends StatelessWidget {
  final DonateMethod method;
  final ColorScheme colorScheme;

  const _DonateMethodItem({required this.method, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    // Every method shares the icon container role; the glyph identifies it.
    return InkWell(
      onTap: () => _handleTap(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: _methodIcon(method, colorScheme.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    method.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    method.subtitle.isEmpty
                        ? method.walletAddress ?? method.url ?? ''
                        : method.subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: method.isWallet ? 11 : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            AppIcon(
              method.isWallet ? Icons.copy_rounded : Icons.open_in_new,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleTap(BuildContext context) async {
    if (method.isWallet) {
      await Clipboard.setData(ClipboardData(text: method.walletAddress!));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${method.title} address copied to clipboard'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final url = method.url;
    if (url == null || url.isEmpty) return;

    final uri = Uri.tryParse(url);
    if (uri == null) return;

    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _NoticeLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final ColorScheme colorScheme;

  const _NoticeLine({
    required this.icon,
    required this.text,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(icon, size: 16, color: colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
          ),
        ),
      ],
    );
  }
}

Widget _methodIcon(DonateMethod method, Color color) {
  switch (method.icon.toLowerCase()) {
    case 'kofi':
    case 'ko-fi':
      return KofiIcon(size: 22, color: color);
    case 'github':
    case 'github-sponsors':
      return GitHubIcon(size: 22, color: color);
    case 'crypto':
    case 'wallet':
      return Text(
        '\$',
        style: TextStyle(
          color: color,
          fontSize: 22,
          fontWeight: FontWeight.bold,
        ),
      );
    case 'coffee':
      return AppIcon(Icons.local_cafe_rounded, color: color, size: 22);
    case 'heart':
    default:
      return AppIcon(Icons.favorite_rounded, color: color, size: 22);
  }
}

IconData _noticeIcon(int index) {
  const icons = [
    Icons.block,
    Icons.build_outlined,
    Icons.favorite_border,
    Icons.history,
    Icons.update,
  ];
  return icons[index % icons.length];
}
