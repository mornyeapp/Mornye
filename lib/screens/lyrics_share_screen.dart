import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EShapeKind;
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/page_transitions.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:mornye/utils/text_direction.dart';
import 'package:mornye/utils/widget_capture.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Story-sized lyric cards stay short, like quoting a song rather than
/// reproducing its lyrics.
const lyricsShareMaxLines = 5;

typedef LyricsShareLine = ({String text, bool background});

enum LyricsCardBackground { artwork, color, dark, light }

/// The card's logical size and the scale it is captured at, so the image is
/// 1080 wide (1920 for the wide card) on every device.
enum LyricsCardShape {
  story(Size(360, 640), 3),
  square(Size(360, 360), 3),
  wide(Size(480, 270), 4);

  const LyricsCardShape(this.size, this.pixelRatio);

  final Size size;
  final double pixelRatio;
}

/// Scales the type the card picks for the length of its quote.
enum LyricsCardTextSize {
  small(0.82),
  auto(1),
  large(1.22);

  const LyricsCardTextSize(this.scale);

  final double scale;
}

/// Lines start at the side they read from, or sit centered.
enum LyricsCardAlign { start, center }

/// How the card looks. The last look used is kept for the next share.
class LyricsCardStyle {
  const LyricsCardStyle({
    this.background = LyricsCardBackground.artwork,
    this.shape = LyricsCardShape.story,
    this.textSize = LyricsCardTextSize.auto,
    this.align = LyricsCardAlign.start,
  });

  final LyricsCardBackground background;
  final LyricsCardShape shape;
  final LyricsCardTextSize textSize;
  final LyricsCardAlign align;

  static const _key = 'lyrics_card_style';

  LyricsCardStyle copyWith({
    LyricsCardBackground? background,
    LyricsCardShape? shape,
    LyricsCardTextSize? textSize,
    LyricsCardAlign? align,
  }) => LyricsCardStyle(
    background: background ?? this.background,
    shape: shape ?? this.shape,
    textSize: textSize ?? this.textSize,
    align: align ?? this.align,
  );

  String encode() =>
      [background.name, shape.name, textSize.name, align.name].join(',');

  /// Unknown or missing parts fall back to the default look.
  factory LyricsCardStyle.decode(String? saved) {
    final parts = (saved ?? '').split(',');
    String? part(int index) => index < parts.length ? parts[index] : null;
    const fallback = LyricsCardStyle();
    return LyricsCardStyle(
      background:
          LyricsCardBackground.values.asNameMap()[part(0)] ??
          fallback.background,
      shape: LyricsCardShape.values.asNameMap()[part(1)] ?? fallback.shape,
      textSize:
          LyricsCardTextSize.values.asNameMap()[part(2)] ?? fallback.textSize,
      align: LyricsCardAlign.values.asNameMap()[part(3)] ?? fallback.align,
    );
  }

  static Future<LyricsCardStyle> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return LyricsCardStyle.decode(prefs.getString(_key));
    } catch (_) {
      return const LyricsCardStyle();
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, encode());
    } catch (_) {}
  }
}

/// Writes the card's PNG where the user chooses. False when they cancel.
typedef LyricsCardSaver = Future<bool> Function(String fileName, Uint8List png);

/// Asks where to save a card image; the default [LyricsCardSaver].
Future<bool> saveShareCardWithSystemDialog(
  String fileName,
  Uint8List png,
) async =>
    await FilePicker.saveFile(
      fileName: fileName,
      bytes: png,
      mimeType: 'image/png',
    ) !=
    null;

/// Reduced motion: the pickers change at once.
const _still = AppMotionSpec(Duration.zero, Curves.linear);

/// Lines a card can quote: timed lines in order, or the plain text's lines.
List<LyricsShareLine> lyricsShareLines(ParsedLyrics lyrics) {
  if (lyrics.lines.isNotEmpty) {
    return [
      for (final line in lyrics.lines)
        if (line.text.trim().isNotEmpty)
          (text: line.text.trim(), background: line.isBackground),
    ];
  }
  return [
    for (final line in lyrics.plainText.split(RegExp(r'\r\n|\r|\n')))
      if (line.trim().isNotEmpty) (text: line.trim(), background: false),
  ];
}

/// The row in [lyricsShareLines] of the line the player highlights at
/// [position], the position it draws synced lyrics for (display lead
/// included), with the listener's timing [offset]. Lines go through the
/// player's own timeline, so an instrumental gap after a line ends selects
/// nothing, and a backing vocal selects the line it backs. -1 for plain
/// lyrics, before the first line and during a gap.
int lyricsShareRowAt(
  ParsedLyrics lyrics,
  Duration position, {
  Duration offset = Duration.zero,
}) {
  if (!lyrics.synced || lyrics.lines.isEmpty) return -1;
  final timeline = lyricsWithDisplayEnds(
    lyricsTimelineWithGaps(lyricsShiftedBy(lyrics.lines, offset)),
  );
  var active = LyricsParser.activeIndex(timeline, position);
  if (active < 0) return -1;
  if (timeline[active].isBackground) {
    active = LyricDisplayLayout(timeline).leadForLine[active];
  }
  if (timeline[active].text.trim().isEmpty) return -1;
  var row = 0;
  for (var i = 0; i < active; i++) {
    if (timeline[i].text.trim().isNotEmpty) row++;
  }
  return row;
}

/// Opens the lyric card editor. [initial] preselects the line the user
/// long-pressed in the player. Without it, [position] (see
/// [lyricsShareRowAt]) preselects the line being sung, so sharing it takes
/// one tap.
Future<void> openLyricsShare(
  BuildContext context, {
  required MediaItem mediaItem,
  required ParsedLyrics lyrics,
  LyricLine? initial,
  Duration? position,
  Duration offset = Duration.zero,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final style = await LyricsCardStyle.load();
  final lines = lyricsShareLines(lyrics);
  var selected = initial == null && position != null
      ? lyricsShareRowAt(lyrics, position, offset: offset)
      : -1;
  if (initial != null) {
    var row = 0;
    for (final line in lyrics.lines) {
      if (line.text.trim().isEmpty) continue;
      if (line.time == initial.time &&
          line.text.trim() == initial.text.trim()) {
        selected = row;
        break;
      }
      row++;
    }
  }
  if (!navigator.mounted) return;
  await navigator.push(
    SteadyPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LyricsShareScreen(
        mediaItem: mediaItem,
        lines: lines,
        initialSelection: {if (selected >= 0) selected},
        style: style,
      ),
    ),
  );
}

class LyricsShareScreen extends StatefulWidget {
  const LyricsShareScreen({
    super.key,
    required this.mediaItem,
    required this.lines,
    this.initialSelection = const {},
    this.style = const LyricsCardStyle(),
    this.saveImage = saveShareCardWithSystemDialog,
  });

  final MediaItem mediaItem;
  final List<LyricsShareLine> lines;
  final Set<int> initialSelection;

  /// The look the card opens with.
  final LyricsCardStyle style;
  final LyricsCardSaver saveImage;

  @override
  State<LyricsShareScreen> createState() => _LyricsShareScreenState();
}

class _LyricsShareScreenState extends State<LyricsShareScreen> {
  final _cardKey = GlobalKey();
  final _shareButtonKey = GlobalKey();
  late final Set<int> _selected = {...widget.initialSelection};
  final _initialRow = GlobalKey();

  /// Made at the list's first layout, which gives the viewport height the
  /// preselected line is centered in.
  ScrollController? _list;
  late LyricsCardStyle _style = widget.style;

  /// The lower pane shows the style choices in place of the lines.
  bool _styling = false;
  bool _sharing = false;

  /// A one-line row: 56dp tall with a 2dp gap below.
  static const _rowExtent = 58.0;

  @override
  void initState() {
    super.initState();
    if (widget.initialSelection.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Lines that wrap make the estimate short; the built row corrects it.
        final row = _initialRow.currentContext;
        if (!mounted || row == null) return;
        Scrollable.ensureVisible(row, alignment: 0.5);
      });
    }
  }

  @override
  void dispose() {
    _list?.dispose();
    super.dispose();
  }

  /// Centers the preselected line in a [viewport] tall list, estimating
  /// rows at one line each so it opens there without a visible jump.
  double _initialOffset(double viewport) {
    if (widget.initialSelection.isEmpty || !viewport.isFinite) return 0;
    final row = widget.initialSelection.first;
    final content = widget.lines.length * _rowExtent - 2;
    final centered = (row + 0.5) * _rowExtent - viewport / 2;
    return centered.clamp(0, (content - viewport).clamp(0, double.infinity));
  }

  void _toggle(int index) {
    setState(() {
      if (_selected.remove(index)) return;
      if (_selected.length >= lyricsShareMaxLines) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(context.l10n.lyricsShareLimit(lyricsShareMaxLines)),
            ),
          );
        return;
      }
      _selected.add(index);
    });
  }

  List<LyricsShareLine> get _quoted => [
    for (final index in _selected.toList()..sort()) widget.lines[index],
  ];

  void _restyle(LyricsCardStyle style) {
    setState(() => _style = style);
    unawaited(style.save());
  }

  /// The card as a PNG file, or null when the screen closed meanwhile.
  Future<File?> _capture() async {
    // A selection or style change can still be waiting for paint when a
    // button is tapped. Capture the current card after that frame finishes.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;
    final file = await captureBoundaryToPngFile(
      _cardKey,
      pixelRatio: _style.shape.pixelRatio,
      fileName: 'mornye_lyrics.png',
    );
    if (file == null) throw StateError('Card could not be captured');
    return file;
  }

  Future<void> _save() async {
    if (_sharing || _selected.isEmpty) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final name = widget.mediaItem.title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    setState(() => _sharing = true);
    try {
      final file = await _capture();
      if (file == null) return;
      final saved = await widget.saveImage(
        '${name.isEmpty ? 'lyrics' : '$name lyrics'}.png',
        await file.readAsBytes(),
      );
      if (saved) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.lyricsShareSaved)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.lyricsShareError)));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _share() async {
    if (_sharing || _selected.isEmpty) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final origin = _originOf(_shareButtonKey.currentContext);
    setState(() => _sharing = true);
    try {
      final file = await _capture();
      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: [
            widget.mediaItem.title,
            if ((widget.mediaItem.artist ?? '').trim().isNotEmpty)
              widget.mediaItem.artist!.trim(),
          ].join(' · '),
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.lyricsShareError)));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  static Rect? _originOf(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = context.tokens;
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        leading: AppIconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const AppIcon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.lyricsShareTitle),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              flex: 6,
              child: Padding(
                // The wide card is limited by the width: keep it off the edges.
                padding: EdgeInsets.symmetric(
                  vertical: tokens.gapSm,
                  horizontal: tokens.gapMd,
                ),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _style.shape.size.aspectRatio,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: colors.shadow.withValues(alpha: 0.22),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: FittedBox(
                          child: CoverSourceColorBuilder(
                            imageSource: widget.mediaItem.artUri?.toString(),
                            builder: (context, coverColor) => RepaintBoundary(
                              key: _cardKey,
                              child: LyricsShareCard(
                                title: widget.mediaItem.title,
                                artist: widget.mediaItem.artist ?? '',
                                artUri: widget.mediaItem.artUri?.toString(),
                                lines: _quoted,
                                background: _style.background,
                                shape: _style.shape,
                                textSize: _style.textSize,
                                align: _style.align,
                                coverColor: coverColor,
                                placeholder: l10n.lyricsShareSelectHint(
                                  lyricsShareMaxLines,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapLg,
                tokens.gapSm,
                tokens.gapLg,
                tokens.gapSm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SettingsSegmentedChoice<bool>(
                      options: [
                        SettingsSegmentOption(
                          value: false,
                          label: l10n.lyricsSharePaneLines,
                          icon: Icons.lyrics_outlined,
                        ),
                        SettingsSegmentOption(
                          value: true,
                          label: l10n.lyricsSharePaneStyle,
                          icon: Icons.palette_outlined,
                        ),
                      ],
                      selected: _styling,
                      onChanged: (styling) =>
                          setState(() => _styling = styling),
                    ),
                  ),
                  SizedBox(width: tokens.gapMd),
                  _SelectionCount(count: _selected.length),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              // The list keeps its scroll position while the style shows.
              child: IndexedStack(
                index: _styling ? 1 : 0,
                children: [
                  _lineList(tokens),
                  _StylePane(style: _style, onChanged: _restyle),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.gapMd,
                tokens.gapSm,
                tokens.gapMd,
                tokens.gapMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ExpressiveButton(
                      tonal: true,
                      icon: const AppIcon(Icons.download_outlined),
                      style: _actionStyle(theme),
                      onPressed: _selected.isEmpty || _sharing ? null : _save,
                      child: Text(l10n.lyricsShareSave),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ExpressiveButton(
                      key: _shareButtonKey,
                      icon: const AppIcon(Icons.ios_share),
                      style: _actionStyle(theme),
                      onPressed: _selected.isEmpty || _sharing ? null : _share,
                      child: Text(l10n.lyricsShareAction),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static ButtonStyle _actionStyle(ThemeData theme) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(64, 56)),
    textStyle: WidgetStatePropertyAll(theme.textTheme.titleMedium),
  );

  Widget _lineList(AppTokens tokens) => LayoutBuilder(
    builder: (context, constraints) => ListView.builder(
      controller: _list ??= ScrollController(
        initialScrollOffset: _initialOffset(constraints.maxHeight),
      ),
      padding: EdgeInsets.symmetric(horizontal: tokens.gapMd),
      itemCount: widget.lines.length,
      itemBuilder: (context, index) => _LineChoice(
        key: index == widget.initialSelection.firstOrNull ? _initialRow : null,
        line: widget.lines[index],
        selected: _selected.contains(index),
        first: index == 0,
        last: index == widget.lines.length - 1,
        onTap: () => _toggle(index),
      ),
    ),
  );
}

/// The card's look: background, shape, text size and alignment.
class _StylePane extends StatelessWidget {
  const _StylePane({required this.style, required this.onChanged});

  final LyricsCardStyle style;
  final ValueChanged<LyricsCardStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final label = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    Widget group(String title, Widget choice) => Padding(
      padding: EdgeInsets.only(bottom: tokens.gapMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, bottom: 8),
            child: Text(title, style: label),
          ),
          choice,
        ],
      ),
    );
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: tokens.gapMd),
      children: [
        group(
          l10n.lyricsShareBackground,
          ShareCardBackgroundPicker(
            value: style.background,
            onChanged: (value) => onChanged(style.copyWith(background: value)),
          ),
        ),
        group(
          l10n.lyricsShareShape,
          SettingsSegmentedChoice<LyricsCardShape>(
            semanticLabel: l10n.lyricsShareShape,
            options: [
              SettingsSegmentOption(
                value: LyricsCardShape.story,
                label: l10n.lyricsShareShapeStory,
                icon: Icons.crop_portrait,
              ),
              SettingsSegmentOption(
                value: LyricsCardShape.square,
                label: l10n.lyricsShareShapeSquare,
                icon: Icons.crop_square,
              ),
              SettingsSegmentOption(
                value: LyricsCardShape.wide,
                label: l10n.lyricsShareShapeWide,
                icon: Icons.crop_landscape,
              ),
            ],
            selected: style.shape,
            onChanged: (value) => onChanged(style.copyWith(shape: value)),
          ),
        ),
        group(
          l10n.lyricsShareTextSize,
          SettingsSegmentedChoice<LyricsCardTextSize>(
            semanticLabel: l10n.lyricsShareTextSize,
            options: [
              SettingsSegmentOption(
                value: LyricsCardTextSize.small,
                label: l10n.lyricsShareTextSmall,
              ),
              SettingsSegmentOption(
                value: LyricsCardTextSize.auto,
                label: l10n.lyricsShareTextAuto,
              ),
              SettingsSegmentOption(
                value: LyricsCardTextSize.large,
                label: l10n.lyricsShareTextLarge,
              ),
            ],
            selected: style.textSize,
            onChanged: (value) => onChanged(style.copyWith(textSize: value)),
          ),
        ),
        group(
          l10n.lyricsShareAlign,
          SettingsSegmentedChoice<LyricsCardAlign>(
            semanticLabel: l10n.lyricsShareAlign,
            options: [
              SettingsSegmentOption(
                value: LyricsCardAlign.start,
                label: l10n.lyricsShareAlignSide,
                icon: Icons.format_align_left,
              ),
              SettingsSegmentOption(
                value: LyricsCardAlign.center,
                label: l10n.lyricsShareAlignCenter,
                icon: Icons.format_align_center,
              ),
            ],
            selected: style.align,
            onChanged: (value) => onChanged(style.copyWith(align: value)),
          ),
        ),
      ],
    );
  }
}

/// The card backgrounds as swatches in one row, for every share card.
class ShareCardBackgroundPicker extends StatelessWidget {
  const ShareCardBackgroundPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final LyricsCardBackground value;
  final ValueChanged<LyricsCardBackground> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final labels = {
      LyricsCardBackground.artwork: l10n.lyricsShareBackgroundArtwork,
      LyricsCardBackground.color: l10n.lyricsShareBackgroundColor,
      LyricsCardBackground.dark: l10n.lyricsShareBackgroundDark,
      LyricsCardBackground.light: l10n.lyricsShareBackgroundLight,
    };
    final swatches = {
      LyricsCardBackground.artwork: const LinearGradient(
        colors: [Color(0xFF8E6BBF), Color(0xFF2C5E8C)],
      ),
      LyricsCardBackground.color: LinearGradient(
        colors: [colors.primary, colors.primaryContainer],
      ),
      LyricsCardBackground.dark: const LinearGradient(
        colors: [Color(0xFF2A2A2A), Color(0xFF0E0E0E)],
      ),
      LyricsCardBackground.light: const LinearGradient(
        colors: [Color(0xFFFFFFFF), Color(0xFFE8E4DC)],
      ),
    };
    // A small control: the fast spatial spring overshoots by itself in
    // Material, Mornye settles without a bounce, reduced motion jumps.
    final morph = AppMotion.spatialFast(
      context,
      _still,
      mornye: MornyeMotion.fast,
    );
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: ShapeDecoration(
        color: colors.surfaceContainerHigh,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final option in LyricsCardBackground.values)
            Expanded(
              child: Semantics(
                button: true,
                selected: option == value,
                inMutuallyExclusiveGroup: true,
                label: labels[option],
                child: Tooltip(
                  message: labels[option],
                  excludeFromSemantics: true,
                  // The whole cell stays tappable; the ripple lives inside
                  // the swatch so it takes the swatch's shape.
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(option),
                    child: SizedBox(
                      height: 52,
                      child: Center(
                        // The chosen swatch morphs from a circle into a larger
                        // rounded square, the Expressive selection cue.
                        child: AnimatedContainer(
                          duration: morph.duration,
                          curve: morph.curve,
                          width: option == value ? 42 : 32,
                          height: option == value ? 42 : 32,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              option == value ? 14 : 17,
                            ),
                            gradient: swatches[option],
                            border: Border.all(
                              color: option == value
                                  ? colors.primary
                                  : colors.outlineVariant,
                              width: option == value ? 2.5 : 1,
                            ),
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              onTap: () => onChanged(option),
                              child: Center(
                                child: option == value
                                    ? AppIcon(
                                        Icons.check_rounded,
                                        size: 20,
                                        color:
                                            option == LyricsCardBackground.light
                                            ? const Color(0xFF111111)
                                            : Colors.white,
                                      )
                                    : option == LyricsCardBackground.artwork
                                    ? const AppIcon(
                                        Icons.image_outlined,
                                        size: 16,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectionCount extends StatelessWidget {
  const _SelectionCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = count > 0;
    final tint = AppMotion.effectsFast(
      context,
      _still,
      mornye: MornyeMotion.effectsFast,
    );
    return AnimatedContainer(
      duration: tint.duration,
      curve: tint.curve,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: ShapeDecoration(
        color: active ? colors.primaryContainer : colors.surfaceContainerHigh,
        shape: const StadiumBorder(),
      ),
      child: Text(
        '$count/$lyricsShareMaxLines',
        style: theme.textTheme.labelLarge?.copyWith(
          color: active ? colors.onPrimaryContainer : colors.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _LineChoice extends StatelessWidget {
  const _LineChoice({
    super.key,
    required this.line,
    required this.selected,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final LyricsShareLine line;
  final bool selected;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Segmented list: rows sit 2dp apart with large outer corners and small
    // inner ones; a selected row rounds fully and turns tonal.
    const outer = Radius.circular(20);
    const inner = Radius.circular(6);
    final radius = selected
        ? const BorderRadius.all(outer)
        : BorderRadius.vertical(
            top: first ? outer : inner,
            bottom: last ? outer : inner,
          );
    // The row reshapes on the default spatial spring and its check on the
    // fast one; reduced motion jumps.
    final reshape = AppMotion.spatial(
      context,
      _still,
      mornye: MornyeMotion.standard,
    );
    final check = AppMotion.spatialFast(
      context,
      _still,
      mornye: MornyeMotion.fast,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 2),
      child: MergeSemantics(
        child: Semantics(
          checked: selected,
          // The container clips its own ink, so the press highlight follows
          // the corners while they animate.
          child: AnimatedContainer(
            duration: reshape.duration,
            curve: reshape.curve,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: selected
                  ? colors.secondaryContainer
                  : colors.surfaceContainerLow,
              borderRadius: radius,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: check.duration,
                          curve: check.curve,
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: selected ? colors.primary : null,
                            borderRadius: BorderRadius.circular(
                              selected ? 8 : 12,
                            ),
                            border: selected
                                ? null
                                : Border.all(color: colors.outline, width: 2),
                          ),
                          child: selected
                              ? AppIcon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: colors.onPrimary,
                                )
                              : null,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            line.text,
                            textDirection: strongTextDirection(line.text),
                            style:
                                (line.background
                                        ? theme.textTheme.bodyMedium
                                        : theme.textTheme.bodyLarge)
                                    ?.copyWith(
                                      color: selected
                                          ? colors.onSecondaryContainer
                                          : colors.onSurface,
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared image: quoted lines over a background derived from the cover.
/// It has a fixed logical size so the export never depends on the device.
class LyricsShareCard extends StatelessWidget {
  const LyricsShareCard({
    super.key,
    required this.title,
    required this.artist,
    required this.artUri,
    required this.lines,
    required this.background,
    this.shape = LyricsCardShape.story,
    this.textSize = LyricsCardTextSize.auto,
    this.align = LyricsCardAlign.start,
    this.coverColor,
    this.placeholder,
  });

  final String title;
  final String artist;
  final String? artUri;
  final List<LyricsShareLine> lines;
  final LyricsCardBackground background;
  final LyricsCardShape shape;
  final LyricsCardTextSize textSize;
  final LyricsCardAlign align;

  /// Average cover color for [LyricsCardBackground.color].
  final Color? coverColor;

  /// Shown faintly in the preview while no line is selected.
  final String? placeholder;

  /// Larger type for short quotes, smaller for long ones, so every selection
  /// fills the card comfortably.
  static double fontSizeFor(List<LyricsShareLine> lines) {
    final length = lines.fold<int>(0, (sum, line) => sum + line.text.length);
    if (length <= 40) return 36;
    if (length <= 90) return 31;
    if (length <= 160) return 26;
    return 22;
  }

  @override
  Widget build(BuildContext context) {
    final light = background == LyricsCardBackground.light;
    final foreground = light ? const Color(0xFF111111) : Colors.white;
    final secondary = foreground.withValues(alpha: 0.7);
    final scheme = Theme.of(context).colorScheme;
    // A card shrunk to fit keeps the side its first line reads from. Each
    // line reads in its own direction.
    final cardDirection =
        lines
            .map((line) => strongTextDirection(line.text))
            .nonNulls
            .firstOrNull ??
        Directionality.of(context);
    final song = _song(scheme, foreground, secondary);
    final brand = ShareCardBrand(foreground: foreground, light: light);
    // Centered lines sit in the middle; others at the side they read from.
    final side = align == LyricsCardAlign.center
        ? Alignment.center
        : AlignmentDirectional.centerStart.resolve(cardDirection);
    return MediaQuery.withNoTextScaling(
      child: SizedBox.fromSize(
        size: shape.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ShareCardBackdrop(
              background: background,
              artUri: artUri,
              coverColor: coverColor,
            ),
            if (shape != LyricsCardShape.story)
              // The square and wide cards have no room for the story's inner
              // panel: the quote takes what the song and the mark leave.
              Padding(
                padding: EdgeInsets.all(
                  shape == LyricsCardShape.wide ? 22 : 26,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: song),
                        if (shape == LyricsCardShape.wide) ...[
                          const SizedBox(width: 12),
                          brand,
                        ],
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: Align(
                        alignment: side,
                        child: _quote(
                          foreground,
                          secondary,
                          cardDirection,
                          width:
                              shape.size.width -
                              (shape == LyricsCardShape.wide ? 44 : 52),
                          alignment: side,
                        ),
                      ),
                    ),
                    if (shape == LyricsCardShape.square) ...[
                      const SizedBox(height: 12),
                      Align(alignment: side, child: brand),
                    ],
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 40, 28, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: foreground.withValues(
                          alpha: light ? 0.06 : 0.12,
                        ),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          song,
                          const SizedBox(height: 22),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 380),
                            child: _quote(
                              foreground,
                              secondary,
                              cardDirection,
                              width: shape.size.width - 100,
                              alignment: align == LyricsCardAlign.center
                                  ? Alignment.topCenter
                                  : AlignmentDirectional.topStart.resolve(
                                      cardDirection,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Center(child: brand),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The cover with the song's title and artist.
  Widget _song(ColorScheme scheme, Color foreground, Color secondary) {
    final cover = shape == LyricsCardShape.story ? 52.0 : 44.0;
    return Row(
      children: [
        AppShapeClip(
          kind: M3EShapeKind.cookie4Sided,
          fallbackRadius: BorderRadius.circular(10),
          child: SizedBox.square(
            dimension: cover,
            child: PlayerArtwork(
              artUri: artUri,
              colorScheme: scheme,
              iconSize: 24,
              cacheWidth: 156,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (artist.isNotEmpty)
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondary, fontSize: 13),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The quoted lines, [width] wide and shrunk to fit the room they get.
  Widget _quote(
    Color foreground,
    Color secondary,
    TextDirection cardDirection, {
    required double width,
    required Alignment alignment,
  }) {
    final wanted = fontSizeFor(lines) * textSize.scale;
    final textAlign = align == LyricsCardAlign.center ? TextAlign.center : null;
    TextStyle style(LyricsShareLine line, double size) => TextStyle(
      color: line.background ? secondary : foreground,
      fontSize: line.background ? size * 0.72 : size,
      height: 1.2,
      fontWeight: line.background ? FontWeight.w400 : FontWeight.w500,
      letterSpacing: -0.2,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final base = DefaultTextStyle.of(context).style;
        final directions = [
          for (final line in lines)
            strongTextDirection(line.text) ?? cardDirection,
        ];
        final painter = TextPainter();
        double heightAt(double size) {
          var height = 0.0;
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            painter
              ..text = TextSpan(
                text: line.text,
                style: base.merge(style(line, size)),
              )
              ..textDirection = directions[i]
              ..layout(maxWidth: width);
            height += painter.height + 6;
          }
          return height;
        }

        // A long quote takes smaller type before the block is shrunk as a
        // whole, so its lines keep the card's full width. Binary search the
        // exact 1-pt step where the block fits instead of stepping linearly.
        final rawSteps = (wanted - wanted * 0.5).ceil();
        final maxSteps = rawSteps > 0 ? rawSteps : 0;
        var fontSize = wanted;
        if (lines.isNotEmpty &&
            maxSteps > 0 &&
            heightAt(wanted) > constraints.maxHeight) {
          var low = 1;
          var high = maxSteps;
          while (low < high) {
            final mid = (low + high) >> 1;
            if (heightAt(wanted - mid) <= constraints.maxHeight) {
              high = mid;
            } else {
              low = mid + 1;
            }
          }
          fontSize = wanted - low;
        }
        painter.dispose();
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignment,
          child: SizedBox(
            width: width,
            child: lines.isEmpty
                ? Text(
                    placeholder ?? '',
                    textAlign: textAlign,
                    style: TextStyle(
                      color: foreground.withValues(alpha: 0.4),
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final line in lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            line.text,
                            textAlign: textAlign,
                            textDirection:
                                strongTextDirection(line.text) ?? cardDirection,
                            style: style(line, fontSize),
                          ),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// The app's mark and name on a share card.
class ShareCardBrand extends StatelessWidget {
  const ShareCardBrand({
    super.key,
    required this.foreground,
    required this.light,
  });

  final Color foreground;

  /// The card is on [LyricsCardBackground.light].
  final bool light;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 14, 6),
    decoration: ShapeDecoration(
      color: foreground.withValues(alpha: light ? 0.06 : 0.14),
      shape: const StadiumBorder(),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The asset is the bare mark, so it only needs the card's text
        // color.
        Image.asset(
          'assets/images/logo-transparent.png',
          width: 26,
          height: 26,
          color: foreground,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        const SizedBox(width: 8),
        Text(
          context.l10n.appName,
          style: TextStyle(
            color: foreground,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
      ],
    ),
  );
}

/// A share card's [background], filling the card.
class ShareCardBackdrop extends StatelessWidget {
  const ShareCardBackdrop({
    super.key,
    required this.background,
    this.artUri,
    this.coverColor,
  });

  final LyricsCardBackground background;

  /// The cover that [LyricsCardBackground.artwork] blurs.
  final String? artUri;

  /// Average cover color for [LyricsCardBackground.color].
  final Color? coverColor;

  static final _artworkBlur = ImageFilter.blur(
    sigmaX: 36,
    sigmaY: 36,
    tileMode: TileMode.mirror,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (background) {
      case LyricsCardBackground.artwork:
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF1B1B1F)),
              ImageFiltered(
                imageFilter: _artworkBlur,
                child: Transform.scale(
                  scale: 1.3,
                  child: PlayerArtwork(
                    artUri: artUri,
                    colorScheme: scheme,
                    cacheWidth: 360,
                  ),
                ),
              ),
              const ColoredBox(color: Color(0x47000000)),
            ],
          ),
        );
      case LyricsCardBackground.color:
        final hsl = HSLColor.fromColor(coverColor ?? scheme.primary);
        final base = hsl.withSaturation(hsl.saturation.clamp(0.25, 0.6));
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                base.withLightness(0.44).toColor(),
                base.withLightness(0.2).toColor(),
              ],
            ),
          ),
        );
      case LyricsCardBackground.dark:
        return const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF26262B), Color(0xFF0B0B0D)],
            ),
          ),
        );
      case LyricsCardBackground.light:
        return const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFFFF), Color(0xFFEDE9E1)],
            ),
          ),
        );
    }
  }
}
