import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/whats_new_screen.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.aboutTitle),

            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16 + wideListInset(context),
                  16,
                  16 + wideListInset(context),
                  8,
                ),
                child: _AppHeaderCard(),
              ),
            ),

            ...settingsSectionSlivers(
              title: context.l10n.aboutContributors,
              connected: true,
              children: [
                _ContributorItem(
                  name: AppInfo.mobileAuthor,
                  description: context.l10n.aboutMobileDeveloper,
                  githubUsername: AppInfo.mobileAuthor,
                  showDivider: true,
                ),
                _ContributorItem(
                  name: 'Amonoman',
                  description: context.l10n.aboutLogoArtist,
                  githubUsername: 'Amonoman',
                  showDivider: true,
                ),
                _ContributorItem(
                  name: 'Ruubiiiii',
                  description:
                      'Provided many APIs and backend resources. A huge help for the project!',
                  githubUsername: 'Ruubiiiii',
                  showDivider: false,
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.aboutTranslators,
              ),
            ),
            const SliverToBoxAdapter(child: _TranslatorsSection()),

            ...settingsSectionSlivers(
              title: context.l10n.aboutSpecialThanks,
              connected: true,
              children: [
                _ContributorItem(
                  name: 'binimum',
                  description: context.l10n.aboutBinimumDesc,
                  githubUsername: 'binimum',
                  showDivider: true,
                ),
                _ContributorItem(
                  name: 'sachinsenal0x64',
                  description: context.l10n.aboutSachinsenalDesc,
                  githubUsername: 'sachinsenal0x64',
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.swap_horiz_rounded,
                  title: 'UniTune',
                  subtitle: context.l10n.aboutUnituneDesc,
                  onTap: () =>
                      _launchUrl('https://github.com/FlazeIGuess/unitune-api'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.library_music_outlined,
                  title: 'MusicBrainz',
                  subtitle: context.l10n.aboutMusicBrainzDesc,
                  onTap: () => _launchUrl('https://musicbrainz.org'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.hub_outlined,
                  title: 'Squigly',
                  subtitle: context.l10n.aboutSquiglyDesc,
                  onTap: () => _launchUrl('https://squigly.link'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.lyrics_outlined,
                  title: 'Zarz-LRC',
                  subtitle: context.l10n.lyricsProviderZarzLrcDesc,
                  onTap: () =>
                      _launchUrl('https://api.zarz.moe/apple-music/docs'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.lyrics_outlined,
                  title: 'Paxsenix',
                  subtitle: context.l10n.aboutPaxsenixSubtitle,
                  onTap: () => _launchUrl('https://lyrics.paxsenix.org'),
                  showDivider: false,
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.aboutLinks,
              connected: true,
              children: [
                _AboutSettingsItem(
                  icon: Icons.phone_android,
                  title: context.l10n.aboutMobileSource,
                  subtitle: 'github.com/${AppInfo.githubRepo}',
                  onTap: () => _launchUrl(AppInfo.githubUrl),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.lyrics_outlined,
                  title: context.l10n.aboutLyricsWebsite,
                  subtitle: 'lyrics.zarz.moe',
                  onTap: () => _launchUrl('https://lyrics.zarz.moe'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.monitor_heart_outlined,
                  title: context.l10n.aboutServiceStatus,
                  subtitle: 'status.zarz.moe',
                  onTap: () => _launchUrl('https://status.zarz.moe'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.bug_report_outlined,
                  title: context.l10n.aboutReportIssue,
                  subtitle: context.l10n.aboutReportIssueSubtitle,
                  onTap: () => _launchUrl('${AppInfo.githubUrl}/issues/new'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.lightbulb_outline,
                  title: context.l10n.aboutFeatureRequest,
                  subtitle: context.l10n.aboutFeatureRequestSubtitle,
                  onTap: () => _launchUrl('${AppInfo.githubUrl}/issues/new'),
                  showDivider: false,
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.aboutSocial,
              connected: true,
              children: [
                _AboutSettingsItem(
                  icon: Icons.telegram,
                  title: context.l10n.aboutTelegramChannel,
                  subtitle: context.l10n.aboutTelegramChannelSubtitle,
                  onTap: () => _launchUrl('https://t.me/mornyeupdates'),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.forum_outlined,
                  title: context.l10n.aboutTelegramChat,
                  subtitle: context.l10n.aboutTelegramChatSubtitle,
                  onTap: () => _launchUrl('https://t.me/mornyecommunity'),
                  showDivider: false,
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.aboutApp,
              connected: true,
              children: [
                _AboutSettingsItem(
                  icon: Icons.info_outline,
                  title: context.l10n.aboutVersion,
                  subtitle:
                      'v${AppInfo.displayVersion} (build ${AppInfo.buildNumber})',
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.new_releases,
                  title: context.l10n.whatsNewAboutTitle(
                    AppInfo.whatsNewRelease,
                  ),
                  // Above the shell, as it shows after an update.
                  onTap: () => isDesktopPlatform
                      ? showWhatsNewDialog(context)
                      : Navigator.of(context, rootNavigator: true).push(
                          slidePageRoute<void>(page: const WhatsNewScreen()),
                        ),
                  showDivider: true,
                ),
                _AboutSettingsItem(
                  icon: Icons.policy_outlined,
                  title: MaterialLocalizations.of(context).licensesPageTitle,
                  subtitle: AppInfo.license,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: AppInfo.appName,
                    applicationVersion: AppInfo.displayVersion,
                    applicationLegalese: AppInfo.copyright,
                  ),
                  showDivider: false,
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    AppInfo.shortGitCommit.isEmpty
                        ? AppInfo.copyright
                        : '${AppInfo.copyright} · ${AppInfo.shortGitCommit}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 16)),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }
}

Future<void> _launchUrl(String url) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
}

class _AppHeaderCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Material sits on the settings group tier beside the groups below.
    final cardColor = !context.isMornye
        ? settingsGroupColor(context)
        : isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerHighest;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final textScale = MediaQuery.textScalerOf(
          context,
        ).scale(1.0).clamp(1.0, 1.4);
        final logoSize = (shortestSide * 0.22).clamp(72.0, 88.0);
        final contentPadding = (cardWidth * 0.06).clamp(16.0, 24.0);
        final titleGap = (16 * (1 + ((textScale - 1) * 0.2))).clamp(12.0, 20.0);

        return Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: EdgeInsets.all(contentPadding),
          child: Column(
            children: [
              Container(
                width: logoSize,
                height: logoSize,
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                // The asset is the bare mark, so inset it within the disc.
                padding: EdgeInsets.all(logoSize * 0.24),
                child: Image.asset(
                  'assets/images/logo-transparent.png',
                  color: colorScheme.onPrimary,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: logoSize,
                      height: logoSize,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
              SizedBox(height: titleGap),
              Text(
                AppInfo.appName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'v${AppInfo.displayVersion}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(height: titleGap),
              Text(
                context.l10n.aboutAppDescription,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ContributorItem extends StatelessWidget {
  final String name;
  final String description;
  final String githubUsername;
  final bool showDivider;

  const _ContributorItem({
    required this.name,
    required this.description,
    required this.githubUsername,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => _launchUrl('https://github.com/$githubUsername'),
          splashColor: colorScheme.primary.withValues(alpha: 0.12),
          highlightColor: colorScheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: 'https://github.com/$githubUsername.png',
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    memCacheWidth: 120,
                    memCacheHeight: 120,
                    cacheManager: CoverCacheManager.instance,
                    placeholder: (context, url) => Container(
                      width: 40,
                      height: 40,
                      color: colorScheme.surfaceContainerHighest,
                      child: AppIcon(
                        Icons.person,
                        color: colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: 40,
                      height: 40,
                      color: colorScheme.surfaceContainerHighest,
                      child: AppIcon(
                        Icons.person,
                        color: colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: Theme.of(context).textTheme.bodyLarge),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                AppIcon(
                  Icons.chevron_right,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            thickness: 1,
            indent: 76,
            endIndent: 20,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }
}

class _Translator {
  final String name;
  final String crowdinUsername;
  final String flag;

  const _Translator({
    required this.name,
    required this.crowdinUsername,
    required this.flag,
  });
}

class _TranslatorsSection extends StatelessWidget {
  const _TranslatorsSection();

  static const List<_Translator> _translators = [
    _Translator(
      name: 'Pedro Marcondes',
      crowdinUsername: 'justapedro',
      flag: '🇵🇹',
    ),
    _Translator(
      name: 'Credits 125',
      crowdinUsername: 'credits125',
      flag: '🇪🇸',
    ),
    _Translator(
      name: 'Владислав',
      crowdinUsername: 'odinokiy_kot',
      flag: '🇷🇺',
    ),
    _Translator(name: 'Amonoman', crowdinUsername: 'amonoman', flag: '🇩🇪'),
    _Translator(
      name: 'Re*Index.(ot_inc)',
      crowdinUsername: 'ot_inc',
      flag: '🇯🇵',
    ),
    _Translator(name: 'unkn0wn', crowdinUsername: 'rdclvi', flag: '🇮🇩'),
    _Translator(
      name: 'lunching1272',
      crowdinUsername: 'lunching1272',
      flag: '🇨🇳',
    ),
    _Translator(
      name: 'Serhii Ilchenko',
      crowdinUsername: 'Sega_Mostky',
      flag: '🇺🇦',
    ),
    _Translator(
      name: 'Serhii Ilchenko',
      crowdinUsername: 'Sega_Mostky',
      flag: '🇷🇺',
    ),
    _Translator(name: 'Girl-lass', crowdinUsername: 'Girl-lass', flag: '🇨🇳'),
    _Translator(name: 'Kaan', crowdinUsername: 'glai', flag: '🇹🇷'),
    _Translator(
      name: 'BedirhanGltkn',
      crowdinUsername: 'bedirhangltkn',
      flag: '🇹🇷',
    ),
    _Translator(name: 'Mickael81', crowdinUsername: 'Mickael81', flag: '🇫🇷'),
    _Translator(name: 'BrandQc', crowdinUsername: 'BrandQc', flag: '🇫🇷'),
    _Translator(
      name: 'blackgold8282',
      crowdinUsername: 'blackgold8282',
      flag: '🇰🇷',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final cardColor = !context.isMornye
        ? settingsGroupColor(context)
        : isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _translators
              .map((translator) => _TranslatorChip(translator: translator))
              .toList(),
        ),
      ),
    );
  }
}

class _TranslatorChip extends StatelessWidget {
  final _Translator translator;

  const _TranslatorChip({required this.translator});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () => _launchUrl(
          'https://crowdin.com/profile/${translator.crowdinUsername}',
        ),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                child: Text(
                  translator.name.isNotEmpty
                      ? translator.name[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                translator.name,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Text(translator.flag, style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutSettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool showDivider;

  const _AboutSettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          splashColor: colorScheme.primary.withValues(alpha: 0.12),
          highlightColor: colorScheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: AppIcon(
                    context.adaptiveIcon(icon),
                    color: context.isMornye
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.bodyLarge),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null)
                  AppIcon(
                    Icons.chevron_right,
                    color: colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        if (showDivider && !settingsRowsConnected(context))
          Divider(
            height: 1,
            thickness: 1,
            indent: 76, // 20 + 40 + 16 = 76 (same as contributor item)
            endIndent: 20,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
    return SettingsSearchTarget(label: title, child: content);
  }
}
