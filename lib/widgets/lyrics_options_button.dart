import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/lyrics_editor_sheet.dart';
import 'package:mornye/widgets/lyrics_options_activity.dart';
import 'package:mornye/widgets/lyrics_size_setting.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/player_lyrics_controls.dart';

final _log = AppLogger('LyricsOptions');

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

/// The player's lyrics menu: pronunciation and translation toggles, AI
/// translation once a provider is set up, and the timing of synced lyrics.
/// Hidden when it would offer nothing.
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
  bool _hidden = false;
  bool _hovered = false;
  bool _focused = false;
  bool _canHide = false;
  Timer? _hideTimer;
  ValueListenable<(int, bool)>? _activity;
  ParsedLyrics? _lastLyrics;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final activity = LyricsOptionsActivity.maybeOf(context);
    if (identical(activity, _activity)) return;
    _activity?.removeListener(_reveal);
    _activity = activity;
    _activity?.addListener(_reveal);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _activity?.removeListener(_reveal);
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_canHide ||
        _hidden ||
        _open ||
        _hovered ||
        _focused ||
        _activity?.value.$2 == true) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      setState(() => _hidden = true);
    });
  }

  void _reveal() {
    if (_hidden) setState(() => _hidden = false);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(lyricsTranslationProvider.select((s) => s.job));
    ref.watch(lyricsTranslationProvider.select((s) => s.results));
    final settings = ref.watch(settingsProvider);
    final apiKey =
        ref.watch(lyricsAiKeyProvider(settings.lyricsAiProvider)).value ?? '';
    final ready = lyricsAiReady(settings, apiKey);
    // The button sits over lyric text, so it fades whether or not the
    // player's own controls stay. Accessible navigation keeps it unless
    // hiding was chosen there.
    final autoHide =
        !isAndroidTv &&
        (!MediaQuery.accessibleNavigationOf(context) ||
            settings.autoHideLyricsControlsWithAccessibility);
    return ListenableBuilder(
      listenable: widget.metadata,
      builder: (context, _) {
        final button = _buildButton(context, job, ready);
        final canHide = autoHide && button != null && _activity != null;
        final lyrics = widget.metadata.lyrics;
        if (_canHide != canHide || !identical(_lastLyrics, lyrics)) {
          _canHide = canHide;
          _lastLyrics = lyrics;
          _hidden = false;
          _scheduleHide();
        }
        if (button == null) return const SizedBox.shrink();
        return Focus(
          onFocusChange: (focused) {
            _focused = focused;
            _reveal();
          },
          child: MouseRegion(
            onEnter: (_) {
              _hovered = true;
              _reveal();
            },
            onExit: (_) {
              _hovered = false;
              _scheduleHide();
            },
            child: PlayerLyricsControlsVisibility(
              hidden: _hidden,
              child: button,
            ),
          ),
        );
      },
    );
  }

  Widget? _buildButton(
    BuildContext context,
    LyricsTranslationJob? job,
    bool ready,
  ) {
    final metadata = widget.metadata;
    if (metadata.loading || metadata.lyrics.isEmpty) return null;
    final canEdit = canEditPlayerLyrics(metadata);
    final original = metadata.lyrics;
    final lyrics = ref
        .read(lyricsTranslationProvider.notifier)
        .display(original);
    final source = LyricsTranslationSource.cached(original);
    // The offline romanization can be hidden too, though it is never saved.
    final pronunciation = ref
        .read(lyricsTranslationProvider.notifier)
        .shown(original)
        .lines
        .any((line) => line.romanization?.trim().isNotEmpty == true);
    final translation = lyricsHaveTranslation(lyrics);
    final translating = job != null && job.sourceHash == source.hash;
    final canTranslate = ready && !source.isEmpty && job == null;
    final canSaveTranslation =
        metadata.canSaveTranslations &&
        !translating &&
        lyricsTranslationUnsaved(original, lyrics);
    // Synced lyrics can always be timed, for this song or every song.
    final timing = original.synced;
    if (canSaveTranslation &&
        ref.read(settingsProvider).lyricsTranslationAutoSave) {
      _scheduleAutoSave(lyrics);
    }
    final language =
        pronunciation || translation || canTranslate || translating;
    if (!language && !timing) {
      return canEdit ? _editButton(context) : null;
    }
    final colorScheme = widget.colorScheme;
    final foreground = _open ? colorScheme.surface : colorScheme.onSurface;
    final percent = ((job?.progress ?? 0) * 100).round();
    return Builder(
      builder: (buttonContext) => AppIconButton.filledTonal(
        // Without language choices the menu holds timing (and editing), so
        // a language glyph would mislead.
        key: ValueKey(language ? 'lyrics-language-options' : 'lyrics-options'),
        tooltip: translating
            ? context.l10n.nowPlayingTranslatingLyrics(percent)
            : language
            ? context.l10n.nowPlayingLyricsLanguageOptions
            : context.l10n.lyricsOffsetOptions,
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
            : language
            ? const AppIcon(Icons.translate_rounded)
            : const AppIcon.adaptive(Icons.tune_rounded),
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
          canSaveTranslation: canSaveTranslation,
          canEdit: canEdit,
          timing: timing,
        ),
      ),
    );
  }

  /// The button alone when editing is the only option, as for plain lyrics.
  Widget _editButton(BuildContext context) {
    final colorScheme = widget.colorScheme;
    final foreground = _open ? colorScheme.surface : colorScheme.onSurface;
    return AppIconButton.filledTonal(
      key: const ValueKey('lyrics-edit'),
      tooltip: context.l10n.lyricsEditTitle,
      icon: const AppIcon.adaptive(Icons.edit_note),
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: colorScheme.onSurface.withValues(
          alpha: _open ? 0.85 : 0.16,
        ),
      ),
      onPressed: _edit,
    );
  }

  Future<void> _edit() async {
    _setOpen(true);
    try {
      await openLyricsEditor(context, widget.metadata);
    } finally {
      _setOpen(false);
    }
  }

  void _setOpen(bool open) {
    if (!mounted) return;
    setState(() => _open = open);
    _reveal();
    widget.onOpenChanged?.call(open);
  }

  Future<void> _showMenu(
    BuildContext buttonContext, {
    required ParsedLyrics original,
    required bool pronunciation,
    required bool translation,
    required bool canTranslate,
    required bool translating,
    required bool canSaveTranslation,
    required bool canEdit,
    required bool timing,
  }) async {
    final settings = ref.read(settingsProvider);
    final l10n = context.l10n;
    final translations = ref.read(lyricsTranslationProvider.notifier);
    final target = translations.targetFor(original);
    final inTarget = translations.inTargetLanguage(original);
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
        // for another language. Lyrics already in it, or translated into
        // it, only offer the picker.
        if (!inTarget)
          (
            'translate',
            l10n.nowPlayingTranslateLyricsTo(target.nativeName),
            Icons.auto_awesome_outlined,
          ),
        (
          'translateInto',
          inTarget
              ? l10n.nowPlayingTranslateInto
              : l10n.nowPlayingTranslateOtherLanguage,
          Icons.language_rounded,
        ),
      ],
      if (canSaveTranslation)
        ('saveTranslation', l10n.nowPlayingSaveTranslation, Icons.save_alt),
      if (timing) ('timing', l10n.lyricsOffset, Icons.timer_outlined),
      if (canEdit) ('edit', l10n.lyricsEditTitle, Icons.edit_note),
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
        case 'saveTranslation':
          unawaited(_saveTranslation());
      }
    } finally {
      // The language sheet, the timing sheet and the editor keep controls
      // visible until they close.
      if (action != 'translateInto' && action != 'edit' && action != 'timing') {
        _setOpen(false);
      }
    }
    if (action == 'timing') {
      try {
        final item = widget.metadata.item;
        if (mounted) {
          await showLyricsTimingSheet(
            context,
            songKey: songLyricsOffsetKeyOf(item),
            songTitle: item?.title,
          );
        }
      } finally {
        _setOpen(false);
      }
    }
    if (action == 'edit') {
      try {
        if (mounted) await openLyricsEditor(context, widget.metadata);
      } finally {
        _setOpen(false);
      }
    }
    if (action == 'translate' || action == 'translateInto') {
      try {
        await _translate(original, choose: action == 'translateInto');
      } finally {
        _setOpen(false);
      }
    }
  }

  /// Songs a save is writing to, across every player view: two views of one
  /// song must not both save the same translation.
  static final _savingSources = <String>{};

  /// Translations already saved automatically here, or tried once.
  final _autoSaved = <(String, ParsedLyrics)>{};

  /// Saves [shown] once it is on screen, when the settings ask for that.
  void _scheduleAutoSave(ParsedLyrics shown) {
    final source = widget.metadata.source;
    if (source == null || _savingSources.contains(source)) return;
    if (_autoSaved.length > 32) _autoSaved.clear();
    if (!_autoSaved.add((source, shown))) return;
    scheduleMicrotask(() {
      if (mounted) unawaited(_saveTranslation(automatic: true));
    });
  }

  /// Saves the translation and pronunciation the player shows with the
  /// song, so they play offline and travel with it: in the song's own lyrics
  /// or a `.mlrc` file next to it, as the settings choose. An automatic save
  /// stays quiet; one that fails is only logged.
  Future<void> _saveTranslation({bool automatic = false}) async {
    final metadata = widget.metadata;
    final source = metadata.source;
    if (source == null || !_savingSources.add(source)) return;
    final l10n = context.l10n;
    final saveTo = ref.read(settingsProvider).lyricsTranslationSaveTo;
    final shown = ref
        .read(lyricsTranslationProvider.notifier)
        .display(metadata.lyrics);
    String message;
    try {
      // Only SMB and WebDAV network songs can be rewritten in place.
      if (source.startsWith('network://') &&
          !await NetworkStorageService.instance.canEditFile(source)) {
        message = l10n.lyricsEditReadOnly;
      } else {
        final target = await metadata.saveShownLyrics(
          shown,
          preferSidecar: saveTo == lyricsTranslationSaveToMlrc,
        );
        message = target == LyricsSaveTarget.sidecar
            ? l10n.nowPlayingTranslationSavedMlrc
            : l10n.nowPlayingTranslationSaved;
      }
    } on LyricsSaveUnsupported {
      message = l10n.lyricsEditReadOnly;
    } catch (error) {
      _log.w('Could not save the lyrics translation: $error');
      message = l10n.lyricsEditSaveFailed;
    } finally {
      _savingSources.remove(source);
    }
    if (!automatic && mounted) {
      showAppSnackBar(context, content: Text(message));
    }
  }

  /// Translates into the song's language, or into one picked now when
  /// [choose] is set. A picked language stays with this song alone.
  Future<void> _translate(ParsedLyrics lyrics, {required bool choose}) async {
    final l10n = context.l10n;
    final settings = ref.read(settingsProvider);
    final translations = ref.read(lyricsTranslationProvider.notifier);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    if (choose) {
      final provider = LyricsAiProvider.fromId(settings.lyricsAiProvider);
      final picked = await showLyricsLanguagePicker(
        context,
        title: l10n.lyricsTranslateSheetTitle,
        subtitle: l10n.lyricsTranslateSheetSubtitle(
          lyricsAiProviderName(l10n, provider),
        ),
        selected: translations.songLanguage(lyrics) ?? '',
        appDefaultLabel: l10n.lyricsTranslateSongDefault(
          translations.settingsTargetFor(lyrics).nativeName,
        ),
      );
      if (picked == null || !mounted) return;
      translations.chooseSongLanguage(lyrics, picked);
    }
    final code = translations.targetFor(lyrics).code;
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
