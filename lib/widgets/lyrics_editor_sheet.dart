import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

final _log = AppLogger('LyricsEditor');

/// Whether [metadata]'s track offers the lyrics editor: a file the app can
/// write, with LRC or plain lyrics or none. Streams and TTML stay read-only.
bool canEditPlayerLyrics(PlayerMetadataController metadata) {
  final source = metadata.source;
  if (metadata.item == null || source == null || source.isEmpty) return false;
  if (const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)) {
    return false;
  }
  return !metadata.loading && LyricsDraft.canEdit(metadata.rawLyrics);
}

/// Opens the lyrics editor for [metadata]'s track: a full-height sheet on
/// phones, a 720dp editor dialog on desktop.
Future<void> openLyricsEditor(
  BuildContext context,
  PlayerMetadataController metadata,
) async {
  final item = metadata.item;
  final source = metadata.source;
  if (item == null || source == null || !canEditPlayerLyrics(metadata)) {
    return;
  }
  final l10n = context.l10n;
  // Only SMB and WebDAV network songs can be rewritten in place.
  if (source.startsWith('network://') &&
      !await NetworkStorageService.instance.canEditFile(source)) {
    if (context.mounted) {
      showAppSnackBar(context, content: Text(l10n.lyricsEditReadOnly));
    }
    return;
  }
  if (!context.mounted) return;
  final saved = await showAppModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // A swipe would skip the unsaved changes check; Cancel and the close
    // button ask first.
    enableDrag: false,
    dialogSize: AppDialogSize.wide,
    builder: (_) => LyricsEditorSheet(metadata: metadata, item: item),
  );
  if (saved == true && context.mounted) {
    showAppSnackBar(context, content: Text(l10n.lyricsEditSaved));
  }
}

/// Edits the playing track's lyrics line by line and times them against
/// playback: Set time gives the selected line the current position and
/// moves to the next one, so a song can be synced while it plays.
class LyricsEditorSheet extends ConsumerStatefulWidget {
  const LyricsEditorSheet({
    super.key,
    required this.metadata,
    required this.item,
  });

  final PlayerMetadataController metadata;
  final MediaItem item;

  @override
  ConsumerState<LyricsEditorSheet> createState() => _LyricsEditorSheetState();
}

class _EditorLine {
  _EditorLine(this.base) : time = base.time {
    text.text = base.text;
  }

  final LyricsDraftLine base;
  final text = TextEditingController();
  final focus = FocusNode();
  final key = GlobalKey();
  Duration? time;

  LyricsDraftLine get draft =>
      base.copyWith(time: time, clearTime: time == null, text: text.text);

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

class _LyricsEditorSheetState extends ConsumerState<LyricsEditorSheet> {
  static const _nudgeStep = Duration(milliseconds: 100);

  late final LyricsDraft _original = LyricsDraft.parse(
    widget.metadata.rawLyrics,
  );
  late final String _originalLrc = _original.toLrc();
  late final List<_EditorLine> _lines = [
    for (final line in _original.lines) _track(_EditorLine(line)),
    if (_original.lines.isEmpty)
      _track(_EditorLine(const LyricsDraftLine.blank())),
  ];
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  int _selected = 0;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Start where syncing would: the first line without a time.
    final untimed = _lines.indexWhere((line) => line.time == null);
    _selected = untimed < 0 ? 0 : untimed;
  }

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  _EditorLine _track(_EditorLine line) {
    line.text.addListener(_markChanged);
    line.focus.addListener(() {
      if (line.focus.hasFocus) _select(_lines.indexOf(line));
    });
    return line;
  }

  LyricsDraft get _draft => LyricsDraft(
    header: _original.header,
    footer: _original.footer,
    lines: [
      for (final line in _lines)
        if (line.time != null || line.text.text.trim().isNotEmpty) line.draft,
    ],
  );

  void _markChanged() {
    if (!mounted) return;
    final dirty = _draft.toLrc() != _originalLrc;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  void _select(int index) {
    if (index < 0 || index >= _lines.length || index == _selected) return;
    setState(() => _selected = index);
    _reveal(index);
  }

  void _reveal(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _lines[index].key.currentContext;
      if (context == null || !context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.4,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Where playback is now, extrapolated between position updates.
  Duration get _position =>
      ref.read(playbackStateProvider).value?.position ?? Duration.zero;

  void _setTime() {
    final ms = (_position.inMilliseconds / 10).round() * 10;
    setState(() {
      _lines[_selected].time = Duration(milliseconds: ms);
      if (_selected < _lines.length - 1) _selected++;
    });
    HapticFeedback.selectionClick();
    _markChanged();
    _reveal(_selected);
  }

  void _nudge(Duration delta) {
    final line = _lines[_selected];
    final time = line.time;
    if (time == null) return;
    final moved = time + delta;
    setState(() => line.time = moved < Duration.zero ? Duration.zero : moved);
    HapticFeedback.selectionClick();
    _markChanged();
  }

  void _seekTo(int index) {
    final time = _lines[index].time;
    _select(index);
    if (time != null) {
      unawaited(ref.read(musicPlayerControllerProvider).seek(time));
    }
  }

  void _insertBelow(int index) {
    final line = _track(_EditorLine(const LyricsDraftLine.blank()));
    setState(() {
      _lines.insert(index + 1, line);
      _selected = index + 1;
    });
    _markChanged();
    _reveal(index + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.focus.requestFocus();
    });
  }

  void _removeTime(int index) {
    setState(() => _lines[index].time = null);
    _markChanged();
  }

  void _delete(int index) {
    final line = _lines[index];
    setState(() {
      _lines.removeAt(index);
      if (_lines.isEmpty) {
        _lines.add(_track(_EditorLine(const LyricsDraftLine.blank())));
      }
      _selected = _selected.clamp(0, _lines.length - 1);
    });
    // The row's field may still hold focus until this frame ends.
    WidgetsBinding.instance.addPostFrameCallback((_) => line.dispose());
    _markChanged();
  }

  Future<void> _close() async {
    if (_saving) return;
    if (_dirty && !await showDiscardChangesDialog(context)) return;
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      await widget.metadata.saveEditedLyrics(_draft.toLrc());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      _log.w('Could not save edited lyrics: $error');
      if (!mounted) return;
      setState(() => _saving = false);
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.lyricsEditSaveFailed)),
        );
    }
  }

  Future<void> _showLineMenu(int index, Offset position) async {
    _select(index);
    final l10n = context.l10n;
    await showContextMenu(
      context,
      position: position,
      groups: [
        [
          ContextMenuAction(
            icon: Icons.add,
            label: l10n.lyricsEditInsertBelow,
            onSelected: () => _insertBelow(index),
          ),
          ContextMenuAction(
            icon: Icons.timer_off_outlined,
            label: l10n.lyricsEditRemoveTime,
            onSelected: _lines[index].time == null
                ? null
                : () => _removeTime(index),
          ),
        ],
        [
          ContextMenuAction(
            icon: Icons.delete_outline,
            label: l10n.lyricsEditDeleteLine,
            destructive: true,
            onSelected: () => _delete(index),
          ),
        ],
      ],
    );
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
    final subtitle = [
      widget.item.title,
      if ((widget.item.artist ?? '').trim().isNotEmpty) widget.item.artist!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(24, 20, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.lyricsEditTitle,
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  subtitle,
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
    );
  }

  Widget _buildLines(BuildContext context) {
    final position = ref.watch(playbackPositionProvider);
    // The line being sung: the last timed line at or before the position.
    var playing = -1;
    Duration? latest;
    for (var i = 0; i < _lines.length; i++) {
      final time = _lines[i].time;
      if (time == null || time > position) continue;
      if (latest == null || time >= latest) {
        latest = time;
        playing = i;
      }
    }
    final tokens = context.tokens;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      itemCount: _lines.length + 1,
      itemBuilder: (context, index) {
        if (index == _lines.length) {
          return Padding(
            padding: EdgeInsets.only(top: tokens.gapSm),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _textAction(
                context,
                icon: Icons.add,
                label: context.l10n.lyricsEditAddLine,
                onPressed: () => _insertBelow(_lines.length - 1),
              ),
            ),
          );
        }
        Duration? previous;
        for (var i = index - 1; i >= 0 && previous == null; i--) {
          previous = _lines[i].time;
        }
        final time = _lines[index].time;
        return Padding(
          key: _lines[index].key,
          padding: EdgeInsets.only(top: index == 0 ? 0 : 2),
          child: _LyricsEditorRow(
            line: _lines[index],
            first: index == 0,
            last: index == _lines.length - 1,
            selected: index == _selected,
            playing: index == playing,
            outOfOrder: time != null && previous != null && time < previous,
            onSelect: () => _select(index),
            onSeek: () => _seekTo(index),
            onMenu: (position) => _showLineMenu(index, position),
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
    final controller = ref.read(musicPlayerControllerProvider);
    final playing = ref.watch(playbackPlayingProvider);
    final duration = widget.item.duration ?? Duration.zero;
    final timeStyle = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final selectedTimed = _lines[_selected].time != null;

    Widget nudge(String label, String tooltip, Duration delta) =>
        AppIconButton.filledTonal(
          tooltip: tooltip,
          onPressed: selectedTimed ? () => _nudge(delta) : null,
          icon: Text(label, style: theme.textTheme.labelLarge),
        );

    final playButton = AppIconButton.filledTonal(
      tooltip: playing ? l10n.actionPause : l10n.tooltipPlay,
      isSelected: playing,
      onPressed: () => controller.togglePlayPause(playing),
      icon: AppIcon.adaptive(
        mornye ? CupertinoIcons.play_fill : Icons.play_arrow,
      ),
      selectedIcon: AppIcon.adaptive(
        mornye ? CupertinoIcons.pause_fill : Icons.pause,
      ),
    );
    final setTime = Tooltip(
      message: l10n.lyricsEditSetTimeTooltip,
      child: AppActionButton(
        key: const ValueKey('lyrics-editor-set-time'),
        tonal: true,
        outlined: mornye,
        onPressed: _saving ? null : _setTime,
        icon: const AppIcon(Icons.timer_outlined),
        label: Text(l10n.lyricsEditSetTime),
      ),
    );
    final tools = [
      playButton,
      nudge(l10n.lyricsEditEarlier, l10n.lyricsEditEarlierTooltip, -_nudgeStep),
      setTime,
      nudge(l10n.lyricsEditLater, l10n.lyricsEditLaterTooltip, _nudgeStep),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  formatClock(ref.watch(playbackPositionProvider).inSeconds),
                  style: timeStyle,
                ),
                Expanded(
                  child: PlaybackSeekSlider(
                    key: ValueKey(widget.item.id),
                    position: ref.watch(playbackPositionProvider),
                    duration: duration,
                    onSeek: controller.seek,
                    playing: playing,
                  ),
                ),
                Text(formatClock(duration.inSeconds), style: timeStyle),
              ],
            ),
            const SizedBox(height: 4),
            if (mornye)
              Row(
                children: [
                  for (final (index, tool) in tools.indexed) ...[
                    if (index > 0) const SizedBox(width: 8),
                    index == 2 ? Expanded(child: tool) : tool,
                  ],
                ],
              )
            else
              ExpressiveButtonGroup(
                flexible: const {2},
                spacing: 8,
                children: tools,
              ),
            const SizedBox(height: 12),
            Row(
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
                  key: const ValueKey('lyrics-editor-save'),
                  onPressed: _dirty && !_saving ? _save : null,
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
          ],
        ),
      ),
    );
  }

  Widget _textAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => context.isMornye
      ? AppActionButton(
          outlined: true,
          glass: false,
          onPressed: onPressed,
          icon: AppIcon(icon),
          label: Text(label),
        )
      : ExpressiveButton(
          text: true,
          onPressed: onPressed,
          icon: AppIcon(icon),
          child: Text(label),
        );
}

/// One line: its time, which plays from there, the text field, and the
/// line's actions. Rows stack as one connected list; the selected row, the
/// one Set time stamps next, rounds its ends.
class _LyricsEditorRow extends StatelessWidget {
  const _LyricsEditorRow({
    required this.line,
    required this.first,
    required this.last,
    required this.selected,
    required this.playing,
    required this.outOfOrder,
    required this.onSelect,
    required this.onSeek,
    required this.onMenu,
  });

  final _EditorLine line;
  final bool first;
  final bool last;
  final bool selected;
  final bool playing;
  final bool outOfOrder;
  final VoidCallback onSelect;
  final VoidCallback onSeek;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = context.tokens;
    final mornye = context.isMornye;
    final outer = Radius.circular(tokens.radiusCard);
    final inner = Radius.circular(tokens.radiusThumb);
    final radius = selected
        ? BorderRadius.all(outer)
        : BorderRadius.vertical(
            top: first ? outer : inner,
            bottom: last ? outer : inner,
          );
    final fill = selected
        ? scheme.secondaryContainer
        : mornye
        ? MornyeTheme.controlFill(context)
        : scheme.surfaceContainerHighest;
    final onFill = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final time = line.time;
    final timeLabel = time == null ? '--:--' : formatLyricsTime(time);

    final timeChip = Tooltip(
      message: time == null
          ? l10n.lyricsEditNoTime
          : outOfOrder
          ? l10n.lyricsEditOutOfOrder
          : l10n.lyricsEditPlayFrom(timeLabel),
      child: Semantics(
        button: time != null,
        label: time == null ? l10n.lyricsEditNoTime : null,
        child: Material(
          color: playing ? scheme.primaryContainer : Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: time == null ? onSelect : onSeek,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: tokens.minTouchTarget,
                minWidth: 88,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ExcludeSemantics(
                    excluding: time == null,
                    child: Text(
                      timeLabel,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: outOfOrder
                            ? scheme.error
                            : playing
                            ? scheme.onPrimaryContainer
                            : time == null
                            ? onFill.withValues(alpha: 0.6)
                            : onFill,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return DesktopContextMenuRegion(
      onContextMenu: onMenu,
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 2, 0, 2),
            child: Row(
              children: [
                timeChip,
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: line.text,
                    focusNode: line.focus,
                    minLines: 1,
                    maxLines: null,
                    // The field grows with its text, so it never needs to
                    // scroll; a wheel or trackpad over a line then scrolls
                    // the list instead of nudging the text inside its row.
                    scrollPhysics: const NeverScrollableScrollPhysics(),
                    textInputAction: TextInputAction.done,
                    style: theme.textTheme.bodyLarge?.copyWith(color: onFill),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      hintText: l10n.lyricsEditLineHint,
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: onFill.withValues(alpha: 0.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                Builder(
                  builder: (buttonContext) => AppIconButton(
                    tooltip: l10n.lyricsEditLineActions,
                    color: onFill.withValues(alpha: 0.8),
                    onPressed: () => onMenu(
                      contextMenuPositionBelow(buttonContext) ?? Offset.zero,
                    ),
                    icon: AppIcon.adaptive(
                      mornye ? CupertinoIcons.ellipsis : Icons.more_vert,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
