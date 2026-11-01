import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/priority_settings_scaffold.dart';
import 'package:mornye/widgets/reorderable_priority_item.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/constants/music_services.dart';

class LyricsProviderPriorityPage extends ConsumerStatefulWidget {
  const LyricsProviderPriorityPage({super.key});

  @override
  ConsumerState<LyricsProviderPriorityPage> createState() =>
      _LyricsProviderPriorityPageState();
}

class _LyricsProviderPriorityPageState
    extends ConsumerState<LyricsProviderPriorityPage> {
  static const _builtInProviderIds = [
    'lrclib',
    'netease',
    'musixmatch',
    'apple_music',
    'mornye_lyrics',
    'qqmusic',
    'spotify',
    'deezer',
    'youtube',
    'kugou',
    'genius',
    'lyricsplus',
    'lrcred',
    'betterlyrics',
  ];

  late List<String> _enabledProviders;
  late List<String> _initialProviders;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _enabledProviders = List.from(settings.lyricsProviders);
    _initialProviders = List.from(settings.lyricsProviders);
  }

  void _markChanged() {
    final changed =
        _enabledProviders.length != _initialProviders.length ||
        !_enabledProviders.asMap().entries.every(
          (e) =>
              e.key < _initialProviders.length &&
              _initialProviders[e.key] == e.value,
        );
    setState(() => _hasChanges = changed);
  }

  @override
  Widget build(BuildContext context) {
    final extensions = ref.watch(extensionProvider).extensions;
    final extensionNames = <String, String>{
      for (final extension in extensions)
        if (extension.enabled && extension.hasLyricsProvider)
          'extension:${extension.id.toLowerCase()}': extension.displayName,
    };
    final allProviderIds = <String>[
      ..._builtInProviderIds,
      ...extensionNames.keys.where((id) => !_builtInProviderIds.contains(id)),
    ];
    final disabled = allProviderIds
        .where((id) => !_enabledProviders.contains(id))
        .toList();

    return PrioritySettingsScaffold(
      hasChanges: _hasChanges,
      title: context.l10n.lyricsProvidersTitle,
      description: context.l10n.lyricsProvidersDescription,
      infoText: context.l10n.lyricsProvidersInfoText,
      onSave: _saveChanges,
      onConfirmDiscard: (ctx) => showDiscardChangesDialog(
        ctx,
        content: ctx.l10n.lyricsProvidersDiscardContent,
      ),
      slivers: [
        if (_enabledProviders.isNotEmpty)
          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.lyricsProvidersEnabledSection(
                _enabledProviders.length,
              ),
            ),
          ),
        if (_enabledProviders.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: 16 + wideListInset(context),
            ),
            sliver: SliverReorderableList(
              itemCount: _enabledProviders.length,
              itemBuilder: (context, index) {
                final id = _enabledProviders[index];
                final info = _getLyricsProviderInfo(
                  id,
                  context,
                  extensionNames[id],
                );
                return ReorderablePriorityItem(
                  key: ValueKey(id),
                  index: index,
                  isFirst: index == 0,
                  icon: info.icon,
                  iconColor: Theme.of(context).colorScheme.primary,
                  name: info.name,
                  subtitle: info.description,
                  trailing: AppSwitch(
                    value: true,
                    semanticLabel: info.name,
                    onChanged: (_) => _disableProvider(id),
                  ),
                );
              },
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  final item = _enabledProviders.removeAt(oldIndex);
                  _enabledProviders.insert(newIndex, item);
                });
                _markChanged();
              },
            ),
          ),
        if (disabled.isNotEmpty)
          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.lyricsProvidersDisabledSection(
                disabled.length,
              ),
            ),
          ),
        if (disabled.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: 16 + wideListInset(context),
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final id = disabled[index];
                final info = _getLyricsProviderInfo(
                  id,
                  context,
                  extensionNames[id],
                );
                return _DisabledProviderItem(
                  key: ValueKey(id),
                  info: info,
                  onToggle: () => _enableProvider(id),
                );
              }, childCount: disabled.length),
            ),
          ),
      ],
    );
  }

  void _enableProvider(String id) {
    setState(() => _enabledProviders.add(id));
    _markChanged();
  }

  void _disableProvider(String id) {
    if (_enabledProviders.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.lyricsProvidersAtLeastOne)),
      );
      return;
    }
    setState(() => _enabledProviders.remove(id));
    _markChanged();
  }

  Future<void> _saveChanges() async {
    final settingsNotifier = ref.read(settingsProvider.notifier);
    settingsNotifier.setLyricsProviders(List<String>.from(_enabledProviders));
    await settingsNotifier.syncLyricsSettingsToBackend();
    if (!mounted) return;
    setState(() {
      _initialProviders = List.from(_enabledProviders);
      _hasChanges = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.lyricsProvidersSaved)));
  }

  static _LyricsProviderInfo _getLyricsProviderInfo(
    String id,
    BuildContext context,
    String? extensionDisplayName,
  ) {
    switch (id) {
      case 'lrclib':
        return _LyricsProviderInfo(
          name: 'LRCLIB',
          description: context.l10n.lyricsProviderLrclibDesc,
          icon: Icons.subtitles_outlined,
        );
      case 'netease':
        return _LyricsProviderInfo(
          name: 'Netease',
          description: context.l10n.lyricsProviderNeteaseDesc,
          icon: Icons.cloud_outlined,
        );
      case 'musixmatch':
        return _LyricsProviderInfo(
          name: 'Musixmatch',
          description: context.l10n.lyricsProviderMusixmatchDesc,
          icon: Icons.translate,
        );
      case 'apple_music':
        return _LyricsProviderInfo(
          name: 'Apple Music',
          description: context.l10n.lyricsProviderAppleMusicDesc,
          icon: Icons.music_note,
        );
      case 'mornye_lyrics':
        return _LyricsProviderInfo(
          name: 'Zarz-LRC',
          description: context.l10n.lyricsProviderZarzLrcDesc,
          icon: Icons.verified_outlined,
        );
      case 'qqmusic':
        return _LyricsProviderInfo(
          name: 'QQ Music',
          description: context.l10n.lyricsProviderQqMusicDesc,
          icon: Icons.queue_music,
        );
      case MusicServices.spotify:
        return _LyricsProviderInfo(
          name: 'Spotify',
          description: context.l10n.lyricsProviderExtensionDesc,
          icon: Icons.graphic_eq,
        );
      case MusicServices.deezer:
        return _LyricsProviderInfo(
          name: 'Deezer',
          description: context.l10n.lyricsProviderExtensionDesc,
          icon: Icons.album_outlined,
        );
      case 'youtube':
        return _LyricsProviderInfo(
          name: 'YouTube',
          description: context.l10n.lyricsProviderExtensionDesc,
          icon: Icons.smart_display_outlined,
        );
      case 'kugou':
        return _LyricsProviderInfo(
          name: 'Kugou',
          description: context.l10n.lyricsProviderExtensionDesc,
          icon: Icons.library_music_outlined,
        );
      case 'genius':
        return _LyricsProviderInfo(
          name: 'Genius',
          description: context.l10n.lyricsProviderExtensionDesc,
          icon: Icons.auto_awesome_outlined,
        );
      case 'lyricsplus':
        return _LyricsProviderInfo(
          name: 'LyricsPlus',
          description: context.l10n.lyricsProviderLyricsPlusDesc,
          icon: Icons.lyrics_outlined,
        );
      case 'lrcred':
        return _LyricsProviderInfo(
          name: 'lrc.red',
          description: context.l10n.lyricsProviderLrcRedDesc,
          icon: Icons.fingerprint,
        );
      case 'betterlyrics':
        return _LyricsProviderInfo(
          name: 'BetterLyrics',
          description: context.l10n.lyricsProviderBetterLyricsDesc,
          icon: Icons.local_fire_department_outlined,
        );
      default:
        return _LyricsProviderInfo(
          name:
              extensionDisplayName ??
              (id.startsWith('extension:')
                  ? id.substring('extension:'.length)
                  : id),
          description: context.l10n.lyricsProviderExtensionDesc,
          icon: Icons.extension,
        );
    }
  }
}

class _DisabledProviderItem extends StatelessWidget {
  final _LyricsProviderInfo info;
  final VoidCallback onToggle;

  const _DisabledProviderItem({
    super.key,
    required this.info,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final backgroundColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.03),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerLow;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: 0.6,
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const SizedBox(width: 28),
                  const SizedBox(width: 16),
                  AppIcon(info.icon, color: colorScheme.outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.name,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: colorScheme.onSurfaceVariant,
                              ),
                        ),
                        Text(
                          info.description,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.outline),
                        ),
                      ],
                    ),
                  ),
                  AppSwitch(
                    value: false,
                    semanticLabel: info.name,
                    onChanged: (_) => onToggle(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricsProviderInfo {
  final String name;
  final String description;
  final IconData icon;

  const _LyricsProviderInfo({
    required this.name,
    required this.description,
    required this.icon,
  });
}
