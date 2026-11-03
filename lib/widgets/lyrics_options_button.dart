import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';

/// The localized message for a translation failure. Raw errors never reach
/// the user.
String lyricsAiErrorMessage(AppLocalizations l10n, LyricsAiErrorKind kind) =>
    switch (kind) {
      LyricsAiErrorKind.notConfigured => l10n.lyricsAiErrorNotConfigured,
      LyricsAiErrorKind.invalidKey => l10n.lyricsAiErrorInvalidKey,
      LyricsAiErrorKind.rateLimited => l10n.lyricsAiErrorRateLimited,
      LyricsAiErrorKind.quota => l10n.lyricsAiErrorQuota,
      LyricsAiErrorKind.network => l10n.lyricsAiErrorNetwork,
      LyricsAiErrorKind.timeout => l10n.lyricsAiErrorTimeout,
      LyricsAiErrorKind.modelNotFound => l10n.lyricsAiErrorModelNotFound,
      LyricsAiErrorKind.refused => l10n.lyricsAiErrorRefused,
      LyricsAiErrorKind.truncated => l10n.lyricsAiErrorTruncated,
      LyricsAiErrorKind.badResponse => l10n.lyricsAiErrorBadResponse,
      LyricsAiErrorKind.service => l10n.lyricsAiErrorService,
      LyricsAiErrorKind.noLyrics => l10n.lyricsAiErrorNoLyrics,
    };

String lyricsAiProviderName(AppLocalizations l10n, LyricsAiProvider provider) =>
    provider.brandName ?? l10n.lyricsAiProviderCustom;

/// Picks a target language: rows that apply on tap. [appDefaultLabel] adds
/// a first row, returned as an empty code, that follows the app language.
Future<String?> showLyricsLanguagePicker(
  BuildContext context, {
  required String title,
  String? subtitle,
  required String selected,
  String? appDefaultLabel,
}) => showAppScrollableBottomSheet<String>(
  context: context,
  title: title,
  subtitle: subtitle,
  builder: (sheetContext, controller) => ListView(
    controller: controller,
    padding: const EdgeInsets.only(bottom: 16),
    children: [
      if (appDefaultLabel != null)
        AppSheetOption.choice(
          title: Text(appDefaultLabel),
          selected: selected.isEmpty,
          onTap: () => Navigator.pop(sheetContext, ''),
        ),
      for (final language in lyricsTranslationLanguages)
        AppSheetOption.choice(
          key: ValueKey('lyrics-language-${language.code}'),
          title: Text(language.nativeName),
          subtitle: language.nativeName == language.englishName
              ? null
              : Text(language.englishName),
          selected: language.code == selected,
          onTap: () => Navigator.pop(sheetContext, language.code),
        ),
    ],
  ),
);

/// The player's lyrics language menu: pronunciation and translation
/// toggles, plus AI translation once a provider is set up. Hidden when it
/// would offer nothing.
class LyricsOptionsButton extends ConsumerStatefulWidget {
  const LyricsOptionsButton({
    super.key,
    required this.metadata,
    required this.colorScheme,
    this.translationOwner,
    this.onOpenChanged,
  });

  final PlayerMetadataController metadata;
  final ColorScheme colorScheme;

  /// The screen that cancels a translation it started when it closes.
  final Object? translationOwner;

  /// Reports the menu opening and closing, so auto-hiding controls wait.
  final ValueChanged<bool>? onOpenChanged;

  @override
  ConsumerState<LyricsOptionsButton> createState() =>
      _LyricsOptionsButtonState();
}

class _LyricsOptionsButtonState extends ConsumerState<LyricsOptionsButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(lyricsTranslationProvider.select((s) => s.job));
    ref.watch(lyricsTranslationProvider.select((s) => s.results));
    final settings = ref.watch(settingsProvider);
    final apiKey =
        ref.watch(lyricsAiKeyProvider(settings.lyricsAiProvider)).value ?? '';
    final ready = lyricsAiReady(settings, apiKey);
    return ListenableBuilder(
      listenable: widget.metadata,
      builder: (context, _) =>
          _buildButton(context, job, ready) ?? const SizedBox.shrink(),
    );
  }

  Widget? _buildButton(
    BuildContext context,
    LyricsTranslationJob? job,
    bool ready,
  ) {
    final metadata = widget.metadata;
    if (metadata.loading || !metadata.lyrics.synced) return null;
    final original = metadata.lyrics;
    final lyrics = ref
        .read(lyricsTranslationProvider.notifier)
        .display(original);
    final source = LyricsTranslationSource.cached(original);
    final pronunciation = lyrics.lines.any(
      (line) => line.romanization?.trim().isNotEmpty == true,
    );
    final translation = lyricsHaveTranslation(lyrics);
    final translating = job != null && job.sourceHash == source.hash;
    final canTranslate = ready && !source.isEmpty && job == null;
    if (!pronunciation && !translation && !canTranslate && !translating) {
      return null;
    }
    final colorScheme = widget.colorScheme;
    final foreground = _open ? colorScheme.surface : colorScheme.onSurface;
    final percent = ((job?.progress ?? 0) * 100).round();
    return Builder(
      builder: (buttonContext) => AppIconButton.filledTonal(
        key: const ValueKey('lyrics-language-options'),
        tooltip: translating
            ? context.l10n.nowPlayingTranslatingLyrics(percent)
            : context.l10n.nowPlayingLyricsLanguageOptions,
        icon: translating
            ? SizedBox.square(
                dimension: 20,
                child: AppProgressIndicator.circular(
                  key: const ValueKey('lyrics-translation-progress'),
                  value: job.done == 0 ? null : job.progress,
                  color: foreground,
                  strokeWidth: 2.5,
                  wavy: false,
                ),
              )
            : const AppIcon(Icons.translate_rounded),
        style: IconButton.styleFrom(
          foregroundColor: foreground,
          backgroundColor: colorScheme.onSurface.withValues(
            alpha: _open ? 0.85 : 0.16,
          ),
        ),
        onPressed: () => _showMenu(
          buttonContext,
          original: original,
          pronunciation: pronunciation,
          translation: translation,
          canTranslate: canTranslate,
          translating: translating,
        ),
      ),
    );
  }

  void _setOpen(bool open) {
    if (!mounted) return;
    setState(() => _open = open);
    widget.onOpenChanged?.call(open);
  }

  Future<void> _showMenu(
    BuildContext buttonContext, {
    required ParsedLyrics original,
    required bool pronunciation,
    required bool translation,
    required bool canTranslate,
    required bool translating,
  }) async {
    final settings = ref.read(settingsProvider);
    final l10n = context.l10n;
    final target = lyricsTranslationTargetFor(settings);
    final actions = <(String, String, IconData)>[
      if (pronunciation)
        (
          'pronunciation',
          settings.playerShowPronunciation
              ? l10n.nowPlayingHidePronunciation
              : l10n.nowPlayingShowPronunciation,
          settings.playerShowPronunciation
              ? Icons.voice_over_off_outlined
              : Icons.record_voice_over_outlined,
        ),
      if (translation)
        (
          'translation',
          settings.playerShowTranslation
              ? l10n.nowPlayingHideTranslation
              : l10n.nowPlayingShowTranslation,
          Icons.translate_rounded,
        ),
      if (translating)
        (
          'cancelTranslation',
          l10n.nowPlayingCancelTranslation,
          Icons.close_rounded,
        )
      else if (canTranslate) ...[
        // The language from settings applies at once; the picker is only
        // for another language.
        (
          'translate',
          l10n.nowPlayingTranslateLyricsTo(target.nativeName),
          Icons.auto_awesome_outlined,
        ),
        (
          'translateInto',
          l10n.nowPlayingTranslateOtherLanguage,
          Icons.language_rounded,
        ),
      ],
    ];
    _setOpen(true);
    String? action;
    try {
      final anchor = mornyeMenuAnchor(buttonContext);
      var menuWidth = 240.0;
      for (final (_, label, _) in actions) {
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontSize: 15),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        if (painter.width + 80 > menuWidth) menuWidth = painter.width + 80;
        painter.dispose();
      }
      action = context.isMornye
          ? await showMornyeContextMenu<String>(
              context: buttonContext,
              anchor: anchor,
              preferAbove: true,
              maxWidth: menuWidth,
              builder: (menuContext) => MornyeContextMenu(
                dense: true,
                groups: [
                  [
                    for (final (value, label, icon) in actions)
                      MornyeMenuAction(
                        icon: icon,
                        label: label,
                        onPressed: () => Navigator.of(menuContext).pop(value),
                      ),
                  ],
                ],
              ),
            )
          : await showMenu<String>(
              context: buttonContext,
              position: RelativeRect.fromRect(
                anchor ?? Rect.zero,
                Offset.zero & MediaQuery.sizeOf(context),
              ),
              items: [
                for (final (value, label, icon) in actions)
                  PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        AppIcon(icon),
                        const SizedBox(width: 12),
                        Flexible(child: Text(label)),
                      ],
                    ),
                  ),
              ],
            );
      if (!mounted) return;
      final notifier = ref.read(settingsProvider.notifier);
      switch (action) {
        case 'pronunciation':
          notifier.setPlayerShowPronunciation(
            !settings.playerShowPronunciation,
          );
        case 'translation':
          notifier.setPlayerShowTranslation(!settings.playerShowTranslation);
        case 'cancelTranslation':
          ref.read(lyricsTranslationProvider.notifier).cancel();
      }
    } finally {
      // The language sheet keeps controls visible until it closes.
      if (action != 'translateInto') _setOpen(false);
    }
    if (action == 'translate' || action == 'translateInto') {
      try {
        await _translate(original, choose: action == 'translateInto');
      } finally {
        _setOpen(false);
      }
    }
  }

  /// Translates into the language from settings, or into one picked now
  /// when [choose] is set. A picked language becomes the new setting.
  Future<void> _translate(ParsedLyrics lyrics, {required bool choose}) async {
    final l10n = context.l10n;
    final settings = ref.read(settingsProvider);
    final target = lyricsTranslationTargetFor(settings).code;
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final String code;
    if (choose) {
      final provider = LyricsAiProvider.fromId(settings.lyricsAiProvider);
      final picked = await showLyricsLanguagePicker(
        context,
        title: l10n.lyricsTranslateSheetTitle,
        subtitle: l10n.lyricsTranslateSheetSubtitle(
          lyricsAiProviderName(l10n, provider),
        ),
        selected: target,
      );
      if (picked == null || picked.isEmpty || !mounted) return;
      code = picked;
      settingsNotifier.setLyricsTranslationLanguage(code);
    } else {
      code = target;
    }
    if (!ref.read(settingsProvider).playerShowTranslation) {
      settingsNotifier.setPlayerShowTranslation(true);
    }
    _setOpen(false);
    final outcome = await ref
        .read(lyricsTranslationProvider.notifier)
        .translate(lyrics, language: code, owner: widget.translationOwner);
    if (!mounted || outcome.cancelled || outcome.busy) return;
    final error = outcome.error;
    final message = error != null
        ? lyricsAiErrorMessage(context.l10n, error)
        : outcome.unchanged
        ? context.l10n.lyricsTranslateAlreadyIn(
            lyricsTranslationLanguageFor(code)?.nativeName ?? code,
          )
        : outcome.missing > 0
        ? context.l10n.lyricsTranslatePartial(outcome.missing)
        : null;
    if (message != null) showAppSnackBar(context, content: Text(message));
  }
}
