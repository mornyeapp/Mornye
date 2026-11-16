import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

class LyricsSizeSetting extends ConsumerWidget {
  const LyricsSizeSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(
      themeProvider.select((theme) => theme.lyricsTextScale),
    );
    final notifier = ref.read(themeProvider.notifier);
    final percent = '${(scale * 100).round()}%';
    final reset = AppIconButton(
      tooltip: context.l10n.libraryFilterReset,
      onPressed: scale == 1 ? null : () => notifier.setLyricsTextScale(1),
      icon: const Icon(Icons.restart_alt),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (context.isMornye)
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.lyricsTextSize,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(percent),
                reset,
              ],
            )
          else
            SliderValueHeader(
              title: context.l10n.lyricsTextSize,
              value: percent,
              trailing: reset,
            ),
          LyricsTextScale(
            child: Text(
              context.l10n.lyricsTextPreview,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          AppSlider(
            value: scale,
            min: 0.8,
            max: 1.4,
            divisions: 12,
            label: percent,
            semanticLabel: context.l10n.lyricsTextSize,
            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
            onChanged: (value) =>
                notifier.setLyricsTextScale(value, persist: false),
            onChangeEnd: notifier.setLyricsTextScale,
          ),
        ],
      ),
    );
  }
}

/// A lyrics timing offset as the sliders show it, such as `In sync` or
/// `0.5 s later`.
String lyricsOffsetLabel(AppLocalizations l10n, num value) {
  final ms = value.round();
  if (ms == 0) return l10n.lyricsOffsetNone;
  final seconds = (ms.abs() / 1000).toStringAsFixed(1);
  return ms > 0
      ? l10n.lyricsOffsetLater(seconds)
      : l10n.lyricsOffsetEarlier(seconds);
}

/// How much later (or earlier) synced lyrics follow playback, for audio that
/// reaches the listener late, such as over Bluetooth. It applies to every
/// song on this device and never syncs. [title] and [subtitle] default to
/// the settings page's.
class LyricsOffsetSetting extends ConsumerWidget {
  const LyricsOffsetSetting({super.key, this.title, this.subtitle});

  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offsetMs = ref.watch(
      themeProvider.select((theme) => theme.lyricsOffsetMs),
    );
    final notifier = ref.read(themeProvider.notifier);
    return _LyricsOffsetSlider(
      key: const ValueKey('lyrics-offset-all-songs'),
      title: title ?? context.l10n.lyricsOffset,
      subtitle: subtitle ?? context.l10n.lyricsOffsetSubtitle,
      offsetMs: offsetMs,
      onChanged: (value, {required persist}) =>
          notifier.setLyricsOffsetMs(value, persist: persist),
    );
  }
}

/// The playing song's own lyrics timing, for lyrics that are early or late
/// on that song whatever plays it. Added to [LyricsOffsetSetting]'s.
class SongLyricsOffsetSetting extends ConsumerWidget {
  const SongLyricsOffsetSetting({
    super.key,
    required this.songKey,
    this.subtitle,
  });

  /// The song's [songLyricsOffsetKey].
  final String songKey;

  /// The song's title, so it reads which song this is.
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offsetMs = ref.watch(songLyricsOffsetMsProvider(songKey));
    final notifier = ref.read(songLyricsOffsetsProvider.notifier);
    return _LyricsOffsetSlider(
      key: const ValueKey('lyrics-offset-this-song'),
      title: context.l10n.lyricsOffsetThisSong,
      subtitle: subtitle,
      offsetMs: offsetMs,
      onChanged: (value, {required persist}) =>
          notifier.setOffsetMs(songKey, value, persist: persist),
    );
  }
}

/// One lyrics timing slider: the title row with the value and a reset
/// button, a description, and the slider, which previews while dragging and
/// saves on release.
class _LyricsOffsetSlider extends StatelessWidget {
  const _LyricsOffsetSlider({
    super.key,
    required this.title,
    required this.subtitle,
    required this.offsetMs,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final int offsetMs;
  final void Function(int value, {required bool persist}) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String format(double value) => lyricsOffsetLabel(l10n, value);
    final value = format(offsetMs.toDouble());
    final reset = AppIconButton(
      tooltip: l10n.libraryFilterReset,
      onPressed: offsetMs == 0 ? null : () => onChanged(0, persist: true),
      icon: const Icon(Icons.restart_alt),
    );
    // "This song" alone does not say what it adjusts.
    final semanticLabel = title == l10n.lyricsOffset
        ? title
        : '${l10n.lyricsOffset}, $title';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (context.isMornye)
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(value),
                reset,
              ],
            )
          else
            SliderValueHeader(title: title, value: value, trailing: reset),
          if (subtitle != null)
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          AppSlider(
            value: offsetMs.toDouble(),
            min: -kMaxLyricsOffsetMs.toDouble(),
            max: kMaxLyricsOffsetMs.toDouble(),
            divisions: kMaxLyricsOffsetMs * 2 ~/ 100,
            label: value,
            semanticLabel: semanticLabel,
            semanticFormatterCallback: format,
            onChanged: (value) => onChanged(value.round(), persist: false),
            onChangeEnd: (value) => onChanged(value.round(), persist: true),
          ),
        ],
      ),
    );
  }
}

/// Opens the lyrics timing of the playing song from the player: "This song"
/// (the song under [songKey], titled [songTitle]) above "All songs" (the
/// app-wide offset of this device). Without a [songKey] only the second
/// shows. A sheet on phones, a compact dialog on desktop.
Future<void> showLyricsTimingSheet(
  BuildContext context, {
  required String songKey,
  String? songTitle,
}) {
  final l10n = context.l10n;
  return showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    title: l10n.lyricsOffset,
    maxHeightFactor: 0.85,
    dialogSize: AppDialogSize.compact,
    builder: (_) => SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: SettingsGroup(
        connected: true,
        children: [
          if (songKey.isNotEmpty)
            SongLyricsOffsetSetting(
              songKey: songKey,
              subtitle: songTitle?.trim().isEmpty ?? true ? null : songTitle,
            ),
          LyricsOffsetSetting(title: l10n.lyricsOffsetAllSongs),
        ],
      ),
    ),
  );
}

/// How strongly Mornye blurs the lyric lines around the current one. The
/// preview's second line blurs as much as the line next to the current one.
class LyricsBlurSetting extends ConsumerWidget {
  const LyricsBlurSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strength = ref.watch(
      themeProvider.select((theme) => theme.lyricsBlur),
    );
    final notifier = ref.read(themeProvider.notifier);
    String format(double value) =>
        value == 0 ? context.l10n.lyricsBlurOff : '${(value * 100).round()}%';
    final style = Theme.of(context).textTheme.headlineSmall;
    final sigma = strength * 2.4;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.lyricsBlur,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(format(strength)),
              AppIconButton(
                tooltip: context.l10n.libraryFilterReset,
                onPressed: strength == 1
                    ? null
                    : () => notifier.setLyricsBlur(1),
                icon: const Icon(Icons.restart_alt),
              ),
            ],
          ),
          Text(
            context.l10n.lyricsBlurSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: LyricsTextScale(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.lyricsTextPreview, style: style),
                  ImageFiltered(
                    enabled: sigma > 0,
                    imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: Text(
                      context.l10n.lyricsTextPreview,
                      style: style?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AppSlider(
            value: strength,
            max: 1.5,
            divisions: 6,
            label: format(strength),
            semanticLabel: context.l10n.lyricsBlur,
            semanticFormatterCallback: format,
            onChanged: (value) => notifier.setLyricsBlur(value, persist: false),
            onChangeEnd: notifier.setLyricsBlur,
          ),
        ],
      ),
    );
  }
}
