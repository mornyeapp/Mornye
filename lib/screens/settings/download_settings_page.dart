import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/settings/download_fallback_extensions_page.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_search_field.dart';

part 'download_settings_page_widgets.dart';

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final extensionState = ref.watch(extensionProvider);
    final hasDownloadExtensions = extensionState.extensions.any(
      (extension) => extension.enabled && extension.hasDownloadProvider,
    );
    final selectedDownloadService = resolveEffectiveDownloadService(
      settings.defaultService,
      extensionState,
    );
    final selectedDownloadExtension = extensionState.extensions
        .where(
          (extension) =>
              extension.enabled &&
              extension.hasDownloadProvider &&
              extension.id == selectedDownloadService,
        )
        .firstOrNull;
    final qualityOptions =
        selectedDownloadExtension?.qualityOptions ?? const <QualityOption>[];
    final canSelectQuality = qualityOptions.isNotEmpty;
    final nativeWorkerAvailable = Platform.isAndroid && hasDownloadExtensions;

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.settingsDownload),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.sectionService),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  _ServiceSelector(
                    currentService: settings.defaultService,
                    onChanged: (service) => ref
                        .read(settingsProvider.notifier)
                        .setDefaultService(service),
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.sectionAudioQuality,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  SettingsSwitchItem(
                    icon: Icons.tune,
                    title: context.l10n.downloadAskBeforeDownload,
                    subtitle: !hasDownloadExtensions
                        ? context.l10n.extensionsNoDownloadProvider
                        : canSelectQuality
                        ? context.l10n.downloadAskQualitySubtitle
                        : context.l10n.downloadSelectServiceToEnable,
                    value: settings.askQualityBeforeDownload,
                    enabled: hasDownloadExtensions && canSelectQuality,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAskQualityBeforeDownload(value),
                  ),
                  if (!settings.askQualityBeforeDownload &&
                      canSelectQuality) ...[
                    for (final quality in qualityOptions)
                      _QualityOption(
                        title: _localizedQualityLabel(context, quality),
                        subtitle: _localizedQualityDescription(
                          context,
                          quality,
                        ),
                        icon: _qualityIcon(quality.id),
                        isSelected: settings.audioQuality == quality.id,
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .setAudioQuality(quality.id),
                        showDivider: true,
                      ),
                  ],
                  SettingsSwitchItem(
                    icon: Icons.verified_outlined,
                    title: context.l10n.downloadRedownloadFakeHiRes,
                    subtitle: context.l10n.downloadRedownloadFakeHiResSubtitle,
                    value: settings.redownloadFakeHiRes,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setRedownloadFakeHiRes(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.auto_fix_high_outlined,
                    title: context.l10n.downloadAutoConvert,
                    subtitle: context.l10n.downloadAutoConvertSubtitle,
                    value: settings.autoConvertDownloads,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAutoConvertDownloads(value),
                    showDivider: settings.autoConvertDownloads,
                  ),
                  if (settings.autoConvertDownloads) ...[
                    SettingsItem(
                      icon: Icons.audio_file_outlined,
                      title: context.l10n.downloadAutoConvertFormat,
                      subtitle: autoConvertFormatLabel(
                        settings.autoConvertFormat,
                      ),
                      onTap: () => _showAutoConvertFormatPicker(
                        context,
                        ref,
                        settings.autoConvertFormat,
                      ),
                    ),
                    SettingsItem(
                      icon: Icons.speed_outlined,
                      title: context.l10n.downloadAutoConvertBitrate,
                      subtitle: normalizeAutoConvertBitrate(
                        settings.autoConvertBitrate,
                      ).replaceAll('k', ' kbps'),
                      onTap: () => _showAutoConvertBitratePicker(
                        context,
                        ref,
                        settings.autoConvertBitrate,
                      ),
                      showDivider: false,
                    ),
                  ],
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.sectionPerformance,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.wifi,
                    title: context.l10n.settingsDownloadNetwork,
                    subtitle: settings.downloadNetworkMode == 'wifi_only'
                        ? context.l10n.settingsDownloadNetworkWifiOnly
                        : context.l10n.settingsDownloadNetworkAny,
                    onTap: () => _showNetworkModePicker(
                      context,
                      ref,
                      settings.downloadNetworkMode,
                    ),
                  ),
                  SettingsItem(
                    icon: Icons.dynamic_feed_outlined,
                    title: context.l10n.settingsConcurrentDownloads,
                    subtitle: settings.concurrentDownloads <= 1
                        ? context.l10n.concurrentDownloadsOne
                        : context.l10n.concurrentDownloadsCount(
                            settings.concurrentDownloads,
                          ),
                    onTap: () => _showConcurrentDownloadsPicker(
                      context,
                      ref,
                      settings.concurrentDownloads,
                    ),
                  ),
                  if (Platform.isAndroid)
                    SettingsSwitchItem(
                      icon: Icons.downloading_outlined,
                      title: context.l10n.downloadNativeWorker,
                      subtitle: hasDownloadExtensions
                          ? context.l10n.downloadNativeWorkerSubtitle
                          : context.l10n.extensionsNoDownloadProvider,
                      value:
                          settings.nativeDownloadWorkerEnabled &&
                          nativeWorkerAvailable,
                      enabled: nativeWorkerAvailable,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setNativeDownloadWorkerEnabled(value),
                    ),
                  SettingsSwitchItem(
                    icon: Icons.security_outlined,
                    title: context.l10n.downloadNetworkCompatibilityMode,
                    subtitle: settings.networkCompatibilityMode
                        ? context.l10n.downloadNetworkCompatibilityModeEnabled
                        : context.l10n.downloadNetworkCompatibilityModeDisabled,
                    value: settings.networkCompatibilityMode,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setNetworkCompatibilityMode(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.lan_outlined,
                    title: context.l10n.downloadAllowLocalNetwork,
                    subtitle: settings.allowLocalNetwork
                        ? context.l10n.downloadAllowLocalNetworkEnabled
                        : context.l10n.downloadAllowLocalNetworkDisabled,
                    value: settings.allowLocalNetwork,
                    onChanged: (value) {
                      ref
                          .read(settingsProvider.notifier)
                          .setAllowLocalNetwork(value);
                      // Android 17 also gates extension sockets to LAN hosts.
                      if (value) {
                        LocalNetworkAccess.instance.ensureGranted().ignore();
                      }
                    },
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.sectionSearchSource,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  const _MetadataSourceSelector(),
                  const _DefaultSearchTabSelector(),
                  SettingsSwitchItem(
                    icon: Icons.sync,
                    title: context.l10n.optionsAutoFallback,
                    subtitle: context.l10n.optionsAutoFallbackSubtitle,
                    value: settings.autoFallback,
                    onChanged: (v) =>
                        ref.read(settingsProvider.notifier).setAutoFallback(v),
                  ),
                  SettingsItem(
                    icon: Icons.extension_outlined,
                    title: context.l10n.downloadFallbackExtensions,
                    subtitle: context.l10n.downloadFallbackExtensionsSubtitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const DownloadFallbackExtensionsPage(),
                      ),
                    ),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.sectionDownload),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.public,
                    title: context.l10n.downloadSongLinkRegion,
                    subtitle: _getSongLinkRegionLabel(
                      context,
                      settings.songLinkRegion,
                    ),
                    onTap: () => _showSongLinkRegionPicker(
                      context,
                      ref,
                      settings.songLinkRegion,
                    ),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.file_download_outlined,
                    title: context.l10n.settingsAutoExportFailed,
                    subtitle: context.l10n.settingsAutoExportFailedSubtitle,
                    value: settings.autoExportFailedDownloads,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAutoExportFailedDownloads(value),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  String _regionCountryName(BuildContext context, String code) {
    final l10n = context.l10n;
    switch (code) {
      case 'US':
        return l10n.regionCountryUS;
      case 'GB':
        return l10n.regionCountryGB;
      case 'FR':
        return l10n.regionCountryFR;
      case 'DE':
        return l10n.regionCountryDE;
      case 'JP':
        return l10n.regionCountryJP;
      case 'KR':
        return l10n.regionCountryKR;
      case 'IN':
        return l10n.regionCountryIN;
      case 'ID':
        return l10n.regionCountryID;
      case 'BR':
        return l10n.regionCountryBR;
      case 'MX':
        return l10n.regionCountryMX;
      case 'AU':
        return l10n.regionCountryAU;
      case 'CA':
        return l10n.regionCountryCA;
      case 'XK':
        return l10n.regionCountryXK;
      default:
        return code;
    }
  }

  String _getSongLinkRegionLabel(BuildContext context, String code) {
    final normalized = code.trim().toUpperCase();
    final effective = normalized.isEmpty ? 'US' : normalized;
    final name = _regionCountryName(context, effective);
    return name == effective ? effective : '$effective - $name';
  }

  IconData _qualityIcon(String qualityId) {
    final normalized = qualityId.toUpperCase();
    if (normalized.startsWith('MP3_') || normalized == 'MP3') {
      return Icons.audiotrack;
    }
    if (normalized.startsWith('OPUS_') || normalized == 'OPUS') {
      return Icons.graphic_eq;
    }

    switch (normalized) {
      case 'HI_RES_LOSSLESS':
        return Icons.four_k;
      case 'HI_RES':
        return Icons.high_quality;
      case 'LOSSLESS':
        return Icons.music_note;
      default:
        return Icons.music_note;
    }
  }

  String _localizedQualityLabel(BuildContext context, QualityOption quality) {
    switch (quality.id.toUpperCase()) {
      case 'LOSSLESS':
        return context.l10n.qualityFlacLossless;
      case 'HI_RES':
        return context.l10n.qualityHiResFlac;
      case 'HI_RES_LOSSLESS':
        return context.l10n.qualityHiResFlacMax;
      default:
        return quality.label;
    }
  }

  String _localizedQualityDescription(
    BuildContext context,
    QualityOption quality,
  ) {
    switch (quality.id.toUpperCase()) {
      case 'LOSSLESS':
        return context.l10n.qualityFlacLosslessSubtitle;
      case 'HI_RES':
        return context.l10n.qualityHiResFlacSubtitle;
      case 'HI_RES_LOSSLESS':
        return context.l10n.qualityHiResFlacMaxSubtitle;
      default:
        return quality.description ?? '';
    }
  }

  void _showAutoConvertFormatPicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    final normalizedCurrent = normalizeAutoConvertFormat(current);
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.downloadAutoConvertFormat,
      subtitle: context.l10n.downloadAutoConvertFormatSubtitle,
      builder: (sheetContext, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final format in autoConvertFormats)
              AppSheetOption.choice(
                leading: AppIcon(
                  format == 'opus'
                      ? Icons.graphic_eq
                      : format == 'aac'
                      ? Icons.album_outlined
                      : Icons.audiotrack,
                ),
                title: Text(autoConvertFormatLabel(format)),
                subtitle: Text(switch (format) {
                  'aac' => context.l10n.downloadAutoConvertM4aSubtitle,
                  'opus' => context.l10n.downloadAutoConvertOpusSubtitle,
                  _ => context.l10n.downloadAutoConvertMp3Subtitle,
                }),
                selected: normalizedCurrent == format,
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setAutoConvertFormat(format);
                  Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showAutoConvertBitratePicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    final normalizedCurrent = normalizeAutoConvertBitrate(current);
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.downloadAutoConvertBitrate,
      subtitle: context.l10n.downloadAutoConvertBitrateSubtitle,
      builder: (sheetContext, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final bitrate in autoConvertBitrates)
              AppSheetOption.choice(
                leading: const AppIcon(Icons.speed_outlined),
                title: Text(bitrate.replaceAll('k', ' kbps')),
                selected: normalizedCurrent == bitrate,
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setAutoConvertBitrate(bitrate);
                  Navigator.pop(sheetContext);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showNetworkModePicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.settingsDownloadNetwork,
      subtitle: context.l10n.settingsDownloadNetworkSubtitle,
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption.choice(
              leading: const AppIcon(Icons.signal_cellular_alt),
              title: Text(context.l10n.settingsDownloadNetworkAny),
              subtitle: Text(context.l10n.downloadNetworkAnySubtitle),
              selected: current == 'any',
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setDownloadNetworkMode('any');
                Navigator.pop(context);
              },
            ),
            AppSheetOption.choice(
              leading: const AppIcon(Icons.wifi),
              title: Text(context.l10n.settingsDownloadNetworkWifiOnly),
              subtitle: Text(context.l10n.downloadNetworkWifiOnlySubtitle),
              selected: current == 'wifi_only',
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setDownloadNetworkMode('wifi_only');
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showConcurrentDownloadsPicker(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) {
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.settingsConcurrentDownloads,
      subtitle: context.l10n.settingsConcurrentDownloadsSubtitle,
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final count in const [1, 2, 3])
              AppSheetOption.choice(
                leading: AppIcon(
                  count == 1
                      ? Icons.looks_one_outlined
                      : count == 2
                      ? Icons.looks_two_outlined
                      : Icons.looks_3_outlined,
                ),
                title: Text(
                  count == 1
                      ? context.l10n.concurrentDownloadsOne
                      : context.l10n.concurrentDownloadsCount(count),
                ),
                selected: current == count,
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setConcurrentDownloads(count);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showSongLinkRegionPicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) {
    const regions = [
      'AD',
      'AE',
      'AG',
      'AL',
      'AM',
      'AO',
      'AR',
      'AT',
      'AU',
      'AZ',
      'BA',
      'BB',
      'BD',
      'BE',
      'BF',
      'BG',
      'BH',
      'BI',
      'BJ',
      'BN',
      'BO',
      'BR',
      'BS',
      'BT',
      'BW',
      'BZ',
      'CA',
      'CD',
      'CG',
      'CH',
      'CI',
      'CL',
      'CM',
      'CO',
      'CR',
      'CV',
      'CW',
      'CY',
      'CZ',
      'DE',
      'DJ',
      'DK',
      'DM',
      'DO',
      'DZ',
      'EC',
      'EE',
      'EG',
      'ES',
      'ET',
      'FI',
      'FJ',
      'FM',
      'FR',
      'GA',
      'GB',
      'GD',
      'GE',
      'GH',
      'GM',
      'GN',
      'GQ',
      'GR',
      'GT',
      'GW',
      'GY',
      'HK',
      'HN',
      'HR',
      'HT',
      'HU',
      'ID',
      'IE',
      'IL',
      'IN',
      'IQ',
      'IS',
      'IT',
      'JM',
      'JO',
      'JP',
      'KE',
      'KG',
      'KH',
      'KI',
      'KM',
      'KN',
      'KR',
      'KW',
      'KZ',
      'LA',
      'LB',
      'LC',
      'LI',
      'LK',
      'LR',
      'LS',
      'LT',
      'LU',
      'LV',
      'LY',
      'MA',
      'MC',
      'MD',
      'ME',
      'MG',
      'MH',
      'MK',
      'ML',
      'MN',
      'MO',
      'MR',
      'MT',
      'MU',
      'MV',
      'MW',
      'MX',
      'MY',
      'MZ',
      'NA',
      'NE',
      'NG',
      'NI',
      'NL',
      'NO',
      'NP',
      'NR',
      'NZ',
      'OM',
      'PA',
      'PE',
      'PG',
      'PH',
      'PK',
      'PL',
      'PS',
      'PT',
      'PW',
      'PY',
      'QA',
      'RO',
      'RS',
      'RW',
      'SA',
      'SB',
      'SC',
      'SE',
      'SG',
      'SI',
      'SK',
      'SL',
      'SM',
      'SN',
      'SR',
      'ST',
      'SV',
      'SZ',
      'TD',
      'TG',
      'TH',
      'TJ',
      'TL',
      'TN',
      'TO',
      'TR',
      'TT',
      'TV',
      'TW',
      'TZ',
      'UA',
      'UG',
      'US',
      'UY',
      'UZ',
      'VC',
      'VE',
      'VN',
      'VU',
      'WS',
      'XK',
      'ZA',
      'ZM',
      'ZW',
    ];
    final normalizedCurrent = current.trim().toUpperCase();
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.downloadSongLinkRegion,
      subtitle: context.l10n.downloadSongLinkRegionDesc,
      builder: (context, controller) => _RegionPickerSheet(
        scrollController: controller,
        regions: regions,
        selected: normalizedCurrent,
        countryNameOf: (context, code) => _regionCountryName(context, code),
        onSelected: (code) {
          ref.read(settingsProvider.notifier).setSongLinkRegion(code);
          Navigator.pop(context);
        },
      ),
    );
  }
}
