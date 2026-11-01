import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

class DownloadServicePicker extends ConsumerStatefulWidget {
  final String? trackName;
  final String? artistName;
  final String? coverUrl;
  final void Function(String quality, String service) onSelect;
  final String? recommendedService;

  const DownloadServicePicker({
    super.key,
    this.trackName,
    this.artistName,
    this.coverUrl,
    required this.onSelect,
    this.recommendedService,
  });

  @override
  ConsumerState<DownloadServicePicker> createState() =>
      _DownloadServicePickerState();

  static void show(
    BuildContext context, {
    String? trackName,
    String? artistName,
    String? coverUrl,
    String? recommendedService,
    required void Function(String quality, String service) onSelect,
  }) {
    final mornye = context.isMornye;

    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: !mornye,
      // Phones float the glass above the home indicator; the desktop dialog
      // draws its own glass around the picker.
      mornyeGlass: isDesktopPlatform,
      // Explicit constraints replace the theme's, so repeat its tablet width.
      constraints: BoxConstraints(
        maxWidth: 640,
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      builder: (context) {
        final picker = DownloadServicePicker(
          trackName: trackName,
          artistName: artistName,
          coverUrl: coverUrl,
          onSelect: onSelect,
          recommendedService: recommendedService,
        );
        if (!context.isMornye) return picker;
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSheetHandle(),
            Flexible(child: picker),
          ],
        );
        if (isDesktopPlatform) return content;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: MornyeGlassPanel.overlay(child: content),
        );
      },
    );
  }
}

class _DownloadServicePickerState extends ConsumerState<DownloadServicePicker> {
  late String _selectedService;

  List<Extension> _downloadExtensions() {
    final extensionState = ref.read(extensionProvider);
    return extensionState.extensions
        .where((ext) => ext.enabled && ext.hasDownloadProvider)
        .toList(growable: false);
  }

  bool _serviceExists(String serviceId, List<Extension> downloadExtensions) {
    if (serviceId.isEmpty) return false;
    return downloadExtensions.any((ext) => ext.id == serviceId);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(extensionProvider.notifier);
      for (final extension in _downloadExtensions()) {
        if (extension.hasServiceHealth) {
          unawaited(notifier.checkExtensionHealth(extension.id));
        }
      }
    });
    final downloadExtensions = _downloadExtensions();
    final recommended = widget.recommendedService;
    if (recommended != null &&
        _serviceExists(recommended, downloadExtensions)) {
      _selectedService = recommended;
    } else {
      _selectedService = ref.read(settingsProvider).defaultService;
    }
    if (!_serviceExists(_selectedService, downloadExtensions)) {
      _selectedService = downloadExtensions.isNotEmpty
          ? downloadExtensions.first.id
          : '';
    }
  }

  List<QualityOption> _getQualityOptions(List<Extension> downloadExtensions) {
    final ext = downloadExtensions
        .where((e) => e.id == _selectedService)
        .firstOrNull;
    if (ext != null && ext.qualityOptions.isNotEmpty) {
      return ext.qualityOptions;
    }

    return const [];
  }

  void _selectService(Extension extension) {
    if (_selectedService == extension.id) return;
    setState(() => _selectedService = extension.id);
    if (extension.hasServiceHealth) {
      unawaited(
        ref.read(extensionProvider.notifier).checkExtensionHealth(extension.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final extensions = ref.watch(
      extensionProvider.select((state) => state.extensions),
    );
    final downloadExtensions = extensions
        .where((ext) => ext.enabled && ext.hasDownloadProvider)
        .toList(growable: false);
    final hasProviders = downloadExtensions.isNotEmpty;
    final qualityOptions = _getQualityOptions(downloadExtensions);
    final qualityRows = [
      for (final quality in qualityOptions)
        if (qualityOptionDisplay(context, quality) case final display)
          _QualityOption(
            title: display.label,
            subtitle: display.description,
            icon: display.icon,
            onTap: () {
              Navigator.pop(context);
              widget.onSelect(quality.id, _selectedService);
            },
          ),
    ];

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.trackName != null) ...[
              _TrackInfoHeader(
                trackName: widget.trackName!,
                artistName: widget.artistName,
                coverUrl: widget.coverUrl,
              ),
              if (context.isMornye)
                Divider(
                  height: 1,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
            ],

            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text(
                context.l10n.downloadFrom,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: hasProviders
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final ext in downloadExtensions)
                          _ServiceChip(
                            key: ValueKey(ext.id),
                            label: ext.displayName,
                            isRecommended: widget.recommendedService == ext.id,
                            healthServiceId: ext.hasServiceHealth
                                ? ext.id
                                : null,
                            isSelected: _selectedService == ext.id,
                            onTap: () => _selectService(ext),
                            iconPath: ext.iconPath,
                          ),
                      ],
                    )
                  : _NoDownloadProviderHint(
                      primaryText: context.l10n.extensionsNoDownloadProvider,
                      secondaryText: context.l10n.storeAddRepoDescription,
                    ),
            ),
            if (hasProviders) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  context.isMornye ? 24 : 16,
                  24,
                  context.isMornye ? 12 : 8,
                ),
                child: Text(
                  context.l10n.downloadSelectQuality,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (context.isMornye)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: RepaintBoundary(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < qualityRows.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 0.5,
                              indent: 52,
                              endIndent: 16,
                              color: MornyeTheme.metadataDividerColor(context),
                            ),
                          qualityRows[i],
                        ],
                      ],
                    ),
                  ),
                )
              else
                ...qualityRows,
            ],

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// Icon, localized label and description of a download quality option.
({IconData icon, String label, String description}) qualityOptionDisplay(
  BuildContext context,
  QualityOption quality,
) {
  final l10n = context.l10n;
  final id = quality.id.toUpperCase();
  return switch (id) {
    'LOSSLESS' => (
      icon: Icons.music_note,
      label: l10n.qualityFlacLossless,
      description: l10n.qualityFlacLosslessSubtitle,
    ),
    'HI_RES' => (
      icon: Icons.high_quality,
      label: l10n.qualityHiResFlac,
      description: l10n.qualityHiResFlacSubtitle,
    ),
    'HI_RES_LOSSLESS' => (
      icon: Icons.four_k,
      label: l10n.qualityHiResFlacMax,
      description: l10n.qualityHiResFlacMaxSubtitle,
    ),
    _ => (
      icon: id.startsWith('MP3_') || id == 'MP3'
          ? Icons.audiotrack
          : id.startsWith('OPUS_') || id == 'OPUS'
          ? Icons.graphic_eq
          : Icons.music_note,
      label: quality.label,
      description: quality.description ?? '',
    ),
  };
}

class _QualityOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _QualityOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (context.isMornye) {
      return CupertinoButton(
        padding: const EdgeInsets.all(16),
        onPressed: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Icon(
                mornyeIconFor(icon),
                color: colorScheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              CupertinoIcons.right_chevron,
              size: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: colorScheme.onPrimaryContainer, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: subtitle.isNotEmpty
          ? Text(
              subtitle,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            )
          : null,
      onTap: onTap,
    );
  }
}

class _ServiceChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final bool isRecommended;
  final VoidCallback? onTap;
  final String? iconPath;
  final String? healthServiceId;

  const _ServiceChip({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.isRecommended = false,
    this.iconPath,
    this.healthServiceId,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accessibleLabel = isRecommended ? '$label (Recommended)' : label;
    Widget serviceIcon(Widget fallback) {
      final cacheSize = (18 * MediaQuery.devicePixelRatioOf(context)).ceil();
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(iconPath!),
          width: 18,
          height: 18,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }

    if (context.isMornye) {
      final foreground = isSelected
          ? colorScheme.primary
          : colorScheme.onSurface;
      return Semantics(
        button: true,
        selected: isSelected,
        hint: isRecommended ? 'Recommended' : null,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          borderRadius: BorderRadius.circular(24),
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.14)
              : colorScheme.onSurface.withValues(alpha: 0.05),
          onPressed: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                Icon(CupertinoIcons.checkmark, color: foreground, size: 18),
                const SizedBox(width: 8),
              ],
              if (iconPath != null) ...[
                serviceIcon(
                  Icon(
                    CupertinoIcons.square_grid_2x2,
                    size: 18,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isRecommended) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: accessibleLabel,
                  excludeFromSemantics: true,
                  child: Icon(
                    CupertinoIcons.star_fill,
                    size: 12,
                    color: foreground,
                  ),
                ),
              ],
              if (healthServiceId != null) ...[
                const SizedBox(width: 8),
                _ServiceHealthDot(serviceId: healthServiceId!),
              ],
            ],
          ),
        ),
      );
    }
    // The chip stays compact; the tap area around it is the 48dp minimum.
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: isSelected
            ? null
            : Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (healthServiceId != null) ...[
            _ServiceHealthDot(serviceId: healthServiceId!),
            const SizedBox(width: 8),
          ],
          if (iconPath != null) ...[
            serviceIcon(
              Icon(
                Icons.extension,
                size: 18,
                color: isSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            accessibleLabel,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: context.tokens.minTouchTarget),
        child: Center(widthFactor: 1, heightFactor: 1, child: chip),
      ),
    );
  }
}

class _ServiceHealthDot extends ConsumerWidget {
  final String serviceId;

  const _ServiceHealthDot({required this.serviceId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(
          extensionProvider.select(
            (state) => state.healthStatuses[serviceId]?.status,
          ),
        ) ??
        'unknown';
    final color = _serviceHealthColor(status);
    return Tooltip(
      message: _serviceHealthTooltip(context, status),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

Color _serviceHealthColor(String status) {
  switch (status) {
    case 'online':
      return const Color(0xFF24D47A);
    case 'degraded':
    case 'unknown':
      return const Color(0xFFFFC247);
    case 'offline':
      return const Color(0xFFFF5A66);
    default:
      return const Color(0xFFFFC247);
  }
}

String _serviceHealthTooltip(BuildContext context, String status) {
  switch (status) {
    case 'online':
      return context.l10n.extensionHealthServiceOnline;
    case 'degraded':
      return context.l10n.extensionHealthServiceDegraded;
    case 'offline':
      return context.l10n.extensionHealthServiceOffline;
    default:
      return context.l10n.extensionHealthServiceUnknown;
  }
}

class _NoDownloadProviderHint extends StatelessWidget {
  final String primaryText;
  final String secondaryText;

  const _NoDownloadProviderHint({
    required this.primaryText,
    required this.secondaryText,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.extension_outlined,
            size: 18,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primaryText,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  secondaryText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackInfoHeader extends StatefulWidget {
  final String trackName;
  final String? artistName;
  final String? coverUrl;

  const _TrackInfoHeader({
    required this.trackName,
    this.artistName,
    this.coverUrl,
  });

  @override
  State<_TrackInfoHeader> createState() => _TrackInfoHeaderState();
}

class _TrackInfoHeaderState extends State<_TrackInfoHeader> {
  bool _expanded = false;
  bool _isOverflowing = false;
  (double, TextStyle?, TextScaler, TextDirection, Locale?)? _titleLayout;
  bool _titleOverflows = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isOverflowing
            ? () => setState(() => _expanded = !_expanded)
            : null,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: widget.coverUrl != null
                        ? Image.network(
                            widget.coverUrl!,
                            width: 56,
                            height: 56,
                            cacheWidth:
                                (56 * MediaQuery.devicePixelRatioOf(context))
                                    .ceil(),
                            cacheHeight:
                                (56 * MediaQuery.devicePixelRatioOf(context))
                                    .ceil(),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Container(
                                  width: 56,
                                  height: 56,
                                  color: colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.music_note,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                          )
                        : Container(
                            width: 56,
                            height: 56,
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.music_note,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final titleStyle = Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600);
                        final titleLayout = (
                          constraints.maxWidth,
                          titleStyle,
                          MediaQuery.textScalerOf(context),
                          Directionality.of(context),
                          Localizations.maybeLocaleOf(context),
                        );
                        if (_titleLayout != titleLayout) {
                          _titleLayout = titleLayout;
                          final painter = TextPainter(
                            text: TextSpan(
                              text: widget.trackName,
                              style: titleStyle,
                            ),
                            maxLines: 1,
                            textScaler: titleLayout.$3,
                            textDirection: titleLayout.$4,
                            locale: titleLayout.$5,
                          )..layout(maxWidth: constraints.maxWidth);
                          _titleOverflows = painter.didExceedMaxLines;
                          painter.dispose();
                        }
                        if (_isOverflowing != _titleOverflows) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _isOverflowing != _titleOverflows) {
                              setState(() => _isOverflowing = _titleOverflows);
                            }
                          });
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.trackName,
                              style: titleStyle,
                              maxLines: _expanded ? 10 : 1,
                              overflow: _expanded
                                  ? TextOverflow.visible
                                  : TextOverflow.ellipsis,
                            ),
                            if (widget.artistName != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.artistName!,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                maxLines: _expanded ? 3 : 1,
                                overflow: _expanded
                                    ? TextOverflow.visible
                                    : TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  if (_isOverflowing || _expanded)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _TrackInfoHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackName != widget.trackName) {
      _titleLayout = null;
      _expanded = false;
    }
  }
}
