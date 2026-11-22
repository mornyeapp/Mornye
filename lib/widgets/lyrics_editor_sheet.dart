import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_draft.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/text_direction.dart';
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
  if (!canEditPlayerLyrics(metadata)) return;
  final edit = metadata.beginLyricsEdit();
  if (edit == null) return;
  final source = edit.source;
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
    builder: (_) => LyricsEditorSheet(metadata: metadata, edit: edit),
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
    required this.edit,
  });

  final PlayerMetadataController metadata;
  final PlayerLyricsEdit edit;
  MediaItem get item => edit.item;

  @override
  ConsumerState<LyricsEditorSheet> createState() => _LyricsEditorSheetState();
}

class _EditorLine {
  _EditorLine(this.base) : time = base.time {
    text.text = base.text;
    direction.value = strongTextDirection(base.text);
    text.addListener(_updateDirection);
  }

  final LyricsDraftLine base;
  final text = TextEditingController();
  final focus = FocusNode();
  final key = GlobalKey();
  Duration? time;

  /// The line's own direction, by its first letter; null follows the
  /// editor's. It changes only when that letter's script does, so typing
  /// does not rebuild the field.
  final direction = ValueNotifier<TextDirection?>(null);

  void _updateDirection() => direction.value = strongTextDirection(text.text);

  LyricsDraftLine get draft =>
      base.copyWith(time: time, clearTime: time == null, text: text.text);

  void dispose() {
    text.dispose();
    direction.dispose();
    focus.dispose();
  }
}

class _LyricsEditorSheetState extends ConsumerState<LyricsEditorSheet> {
  static const _nudgeStep = Duration(milliseconds: 100);

  late final LyricsDraft _original = LyricsDraft.parse(widget.edit.rawLyrics);
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
    widget.metadata.addListener(_onMetadataChanged);
    // Start where syncing would: the first line without a time.
    final untimed = _lines.indexWhere((line) => line.time == null);
    _selected = untimed < 0 ? 0 : untimed;
  }

  @override
  void dispose() {
    widget.metadata.removeListener(_onMetadataChanged);
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  bool get _editingCurrentTrack =>
      widget.metadata.isCurrentLyricsEdit(widget.edit);

  void _onMetadataChanged() {
    if (mounted) setState(() {});
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
      // The list moves as content, on a spring that stops at its place
      // instead of scrolling past it: Material's slow spatial spring is
      // critically damped, and Mornye's standard one has no bounce.
      final motion = AppMotion.spatialSlow(
        context,
        const AppMotionSpec(Duration.zero, Curves.linear),
        mornye: MornyeMotion.standard,
      );
      Scrollable.ensureVisible(
        context,
        alignment: 0.4,
        duration: motion.duration,
        curve: motion.curve,
      );
    });
  }

  /// Where playback is now, extrapolated between position updates.
  Duration get _position => _editingCurrentTrack
      ? ref.read(playbackStateProvider).value?.position ?? Duration.zero
      : Duration.zero;

  void _setTime() {
    if (!_editingCurrentTrack) return;
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
    if (time != null && _editingCurrentTrack) {
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
      await widget.metadata.saveEditedLyrics(_draft.toLrc(), edit: widget.edit);
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
    // keyboard; isolate viewInsets so keyboard animation frames do not rebuild
    // the lyric line list.
    if (!isDesktopPlatform) {
      final inner = body;
      body = SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.92,
        child: Builder(
          builder: (context) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: inner,
          ),
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
      if (!_editingCurrentTrack || time == null || time > position) continue;
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
            onSeek: _editingCurrentTrack ? () => _seekTo(index) : null,
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
    final active = _editingCurrentTrack;
    final playing = ref.watch(playbackPlayingProvider) && active;
    final position = ref.watch(playbackPositionProvider);
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
      onPressed: active ? () => controller.togglePlayPause(playing) : null,
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
        onPressed: _saving || !active ? null : _setTime,
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
            Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                children: [
                  Text(
                    formatClock(active ? position.inSeconds : 0),
                    style: timeStyle,
                  ),
                  Expanded(
                    child: PlaybackSeekSlider(
                      key: ValueKey(widget.item.id),
                      position: active ? position : Duration.zero,
                      duration: active ? duration : Duration.zero,
                      onSeek: (position) async {
                        if (_editingCurrentTrack) {
                          await controller.seek(position);
                        }
                      },
                      playing: playing,
                    ),
                  ),
                  Text(formatClock(duration.inSeconds), style: timeStyle),
                ],
              ),
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
                          child: AppLoadingIndicator(
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
  final VoidCallback? onSeek;
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
          : onSeek == null
          ? timeLabel
          : l10n.lyricsEditPlayFrom(timeLabel),
      child: Semantics(
        button: time != null,
        label: time == null ? l10n.lyricsEditNoTime : null,
        child: Material(
          color: playing ? scheme.primaryContainer : Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: time == null || onSeek == null ? onSelect : onSeek,
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
                  child: ValueListenableBuilder<TextDirection?>(
                    valueListenable: line.direction,
                    builder: (context, direction, _) => TextField(
                      controller: line.text,
                      focusNode: line.focus,
                      textDirection: direction,
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
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
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
