import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/text_direction.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/expressive_button.dart';

final _log = AppLogger('LyricsTranslationEditor');

/// Opens the translation editor for [metadata]'s track: one field per
/// lyric line, filled with the translation the player shows, if any. No AI
/// provider is needed: a song with no translation at all can get one
/// written by hand here. Saving writes the edited translation with the
/// song, the same way Save Translation does, and updates the AI cache so
/// the old AI text does not come back over it.
Future<void> openLyricsTranslationEditor(
  BuildContext context,
  PlayerMetadataController metadata,
) async {
  if (!metadata.canSaveTranslations) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final translations = container.read(lyricsTranslationProvider.notifier);
  // A translation in flight would overwrite the edit as soon as it lands.
  translations.cancel();
  final original = metadata.lyrics;
  final source = LyricsTranslationSource.cached(original);
  if (source.isEmpty) return;
  final songSource = metadata.source;
  // Only SMB and WebDAV network songs can be rewritten in place.
  if (songSource != null &&
      songSource.startsWith('network://') &&
      !await NetworkStorageService.instance.canEditFile(songSource)) {
    if (context.mounted) {
      showAppSnackBar(context, content: Text(context.l10n.lyricsEditReadOnly));
    }
    return;
  }
  if (!context.mounted) return;
  final shown = translations.display(original);
  final saved = await showAppModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    enableDrag: false,
    dialogSize: AppDialogSize.wide,
    builder: (_) => LyricsTranslationEditorSheet(
      metadata: metadata,
      original: original,
      shown: shown,
      target: translations.targetFor(original),
    ),
  );
  if (saved == true && context.mounted) {
    showAppSnackBar(
      context,
      content: Text(context.l10n.lyricsTranslationEditSaved),
    );
  }
}

/// Edits the playing track's lyrics translation line by line, by hand.
/// Repeated lines share one translation, so each distinct line is edited
/// once and every repeat shows the same edit.
class LyricsTranslationEditorSheet extends ConsumerStatefulWidget {
  const LyricsTranslationEditorSheet({
    super.key,
    required this.metadata,
    required this.original,
    required this.shown,
    required this.target,
  });

  final PlayerMetadataController metadata;

  /// The lyrics as stored, without any AI overlay.
  final ParsedLyrics original;

  /// The lyrics as the player shows them: the translation to edit.
  final ParsedLyrics shown;

  /// The language the translation is written in.
  final LyricsTranslationLanguage target;

  @override
  ConsumerState<LyricsTranslationEditorSheet> createState() =>
      _LyricsTranslationEditorSheetState();
}

class _TranslationLine {
  _TranslationLine({required this.segment, required this.original})
    : translation = ValueNotifier<String?>(null) {
    text.text = '';
  }

  /// Index into [LyricsTranslationSource.texts].
  final int segment;

  /// The original line, timing tags removed.
  final String original;

  final text = TextEditingController();
  final focus = FocusNode();
  final key = GlobalKey();

  /// The translation this line had when the editor opened, or null.
  final ValueNotifier<String?> translation;

  /// The line's own direction, by its first letter; null follows the
  /// editor's. It changes only when that letter's script does, so typing
  /// does not rebuild the field.
  final direction = ValueNotifier<TextDirection?>(null);

  void init(String? value) {
    translation.value = value;
    text.text = value ?? '';
    direction.value = strongTextDirection(text.text);
    text.addListener(_updateDirection);
  }

  void _updateDirection() => direction.value = strongTextDirection(text.text);

  void dispose() {
    text.dispose();
    direction.dispose();
    focus.dispose();
    translation.dispose();
  }
}

class _LyricsTranslationEditorSheetState
    extends ConsumerState<LyricsTranslationEditorSheet> {
  late final String _source = widget.metadata.source ?? '';
  late final String _itemId = widget.metadata.item?.id ?? '';
  late final List<_TranslationLine> _lines = _buildTranslationLines();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _dirty = false;
  bool _saving = false;

  List<_TranslationLine> _buildTranslationLines() {
    final source = LyricsTranslationSource.cached(widget.original);
    final shown = lyricsWithPlainLines(widget.shown).lines;
    final lines = <_TranslationLine>[];
    final seen = <int>{};
    for (var i = 0; i < shown.length && i < source.lineSegments.length; i++) {
      final segment = source.lineSegments[i];
      if (segment == null || !seen.add(segment)) continue;
      final line = _TranslationLine(
        segment: segment,
        original: translatableLyricText(shown[i].text),
      );
      line.init(shown[i].translation);
      lines.add(_track(line));
    }
    return lines;
  }

  _TranslationLine _track(_TranslationLine line) {
    line.text.addListener(_markChanged);
    return line;
  }

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  bool get _editingCurrentTrack =>
      widget.metadata.source == _source && widget.metadata.item?.id == _itemId;

  void _markChanged() {
    if (!mounted) return;
    final dirty = _lines.any(
      (line) => line.text.text.trim() != (line.translation.value ?? '').trim(),
    );
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  /// [widget.shown] with the edited translations on its lines. An empty
  /// field clears that line's translation; a line left alone keeps its
  /// word timing, an edited one loses it, as `withTranslation` does.
  ParsedLyrics get _edited {
    final shown = lyricsWithPlainLines(widget.shown);
    final source = LyricsTranslationSource.cached(widget.original);
    final bySegment = <int, String?>{
      for (final line in _lines)
        line.segment: line.text.text.trim().isEmpty
            ? null
            : line.text.text.trim(),
    };
    final lines = <LyricLine>[];
    for (var i = 0; i < shown.lines.length; i++) {
      final line = shown.lines[i];
      final segment = i < source.lineSegments.length
          ? source.lineSegments[i]
          : null;
      if (segment == null || !bySegment.containsKey(segment)) {
        lines.add(line);
        continue;
      }
      lines.add(line.withTranslation(bySegment[segment]));
    }
    return ParsedLyrics(
      synced: shown.synced,
      wordSynced: shown.wordSynced,
      lines: lines,
      plainText: shown.plainText,
      writers: shown.writers,
      provider: shown.provider,
    );
  }

  Future<void> _close() async {
    if (_saving) return;
    if (_dirty && !await showDiscardChangesDialog(context)) return;
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _save() async {
    if (_saving || !_dirty || !_editingCurrentTrack) return;
    setState(() => _saving = true);
    final edited = _edited;
    // A field the user emptied clears that line's translation from the
    // song's file too, instead of leaving its old tag behind.
    final cleared = _lines.any(
      (line) =>
          line.text.text.trim().isEmpty &&
          (line.translation.value ?? '').trim().isNotEmpty,
    );
    try {
      // The file first: if it fails, the cache must not claim the edit.
      await widget.metadata.saveShownLyrics(
        edited,
        preferSidecar:
            ref.read(settingsProvider).lyricsTranslationSaveTo ==
            lyricsTranslationSaveToMlrc,
        clearMissingTranslations: cleared,
      );
      await ref
          .read(lyricsTranslationProvider.notifier)
          .saveManualTranslation(widget.original, edited);
      ref.read(settingsProvider.notifier).setPlayerShowTranslation(true);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on LyricsSaveUnsupported {
      if (!mounted) return;
      setState(() => _saving = false);
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.lyricsEditReadOnly)),
        );
    } catch (error) {
      _log.w('Could not save the edited lyrics translation: $error');
      if (!mounted) return;
      setState(() => _saving = false);
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.lyricsEditSaveFailed)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    Widget body = AppScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Column(
          children: [
            _buildHeader(context),
            Expanded(child: _buildLines(context)),
            _buildFooter(context),
          ],
        ),
      ),
    );
    // On phones the sheet takes most of the screen and rises with the
    // keyboard; the desktop dialog brings its own height cap.
    if (!isDesktopPlatform) {
      body = SizedBox(
        height: media.size.height * 0.92,
        child: Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: body,
        ),
      );
    }
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: body,
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final hasTranslation = _lines.any(
      (line) => (line.translation.value ?? '').trim().isNotEmpty,
    );
    final subtitle = [
      widget.metadata.item?.title ?? '',
      if ((widget.metadata.item?.artist ?? '').trim().isNotEmpty)
        widget.metadata.item!.artist!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(24, 20, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasTranslation
                          ? l10n.lyricsTranslationEditTitle
                          : l10n.lyricsTranslationAddTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                    Text(
                      l10n.lyricsTranslationEditSubtitle(
                        widget.target.nativeName,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              AppIconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: _saving ? null : _close,
                icon: const AppIcon.adaptive(Icons.close),
              ),
            ],
          ),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10n.lyricsTranslationEditWordTimingNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLines(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = context.tokens;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      itemCount: _lines.length,
      itemBuilder: (context, index) {
        final line = _lines[index];
        return Padding(
          key: line.key,
          padding: EdgeInsets.only(top: index == 0 ? 0 : tokens.gapMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.original,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              ValueListenableBuilder<TextDirection?>(
                valueListenable: line.direction,
                builder: (context, direction, _) => TextField(
                  key: ValueKey('lyrics-translation-field-${line.segment}'),
                  controller: line.text,
                  focusNode: line.focus,
                  textDirection: direction,
                  minLines: 1,
                  maxLines: null,
                  scrollPhysics: const NeverScrollableScrollPhysics(),
                  textInputAction: TextInputAction.done,
                  style: theme.textTheme.bodyLarge,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: widget.target.nativeName,
                    hintStyle: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mornye = context.isMornye;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            mornye
                ? AppActionButton(
                    outlined: true,
                    glass: false,
                    onPressed: _saving ? null : _close,
                    icon: const SizedBox.shrink(),
                    label: Text(l10n.dialogCancel),
                  )
                : ExpressiveButton(
                    text: true,
                    onPressed: _saving ? null : _close,
                    child: Text(l10n.dialogCancel),
                  ),
            const SizedBox(width: 8),
            AppActionButton(
              key: const ValueKey('lyrics-translation-editor-save'),
              onPressed: _dirty && !_saving && _editingCurrentTrack
                  ? _save
                  : null,
              icon: _saving
                  ? SizedBox.square(
                      dimension: 18,
                      child: mornye
                          ? const CupertinoActivityIndicator()
                          : AppLoadingIndicator(
                              size: 18,
                              color: scheme.onPrimary,
                            ),
                    )
                  : const AppIcon(Icons.check),
              label: Text(l10n.dialogSave),
            ),
          ],
        ),
      ),
    );
  }
}
