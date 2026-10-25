import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';
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
