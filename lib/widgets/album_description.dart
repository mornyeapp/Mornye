import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:html/dom.dart' as dom;
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

/// A short editorial preview below the album controls, with a full reading sheet.
class AlbumDescription extends StatefulWidget {
  const AlbumDescription({
    super.key,
    required this.title,
    required this.description,
    this.underSheetEdge = false,
  });

  final String title;
  final String description;

  /// Whether it is the first thing on the sheet a Material header rounds
  /// off. The round edge is its space above, so it adds none of its own.
  final bool underSheetEdge;

  @override
  State<AlbumDescription> createState() => _AlbumDescriptionState();
}

class _AlbumDescriptionState extends State<AlbumDescription> {
  static final _horizontalWhitespace = RegExp(r'[\t\f\v ]+');

  String? _parsedSource;
  late TextSpan _parsedSpan;
  bool _isEmpty = true;

  Object? _measureKey;
  bool _hasMore = false;

  void _ensureParsed() {
    if (_parsedSource == widget.description) return;
    _parsedSource = widget.description;
    _measureKey = null;
    final fragment = parseEditorialNotes(widget.description);
    final formatted = fragment.children.isNotEmpty;
    List<InlineSpan> spans(List<dom.Node> nodes) => [
      for (final node in nodes)
        if (node is dom.Text)
          TextSpan(
            text: formatted
                // Catalog notes can mix inline markup with literal paragraph
                // breaks. Only collapse horizontal whitespace.
                ? node.data.replaceAll(_horizontalWhitespace, ' ')
                : node.data,
          )
        else if (node is dom.Element)
          if (node.localName == 'br')
            const TextSpan(text: '\n')
          else ...[
            TextSpan(
              style: switch (node.localName) {
                'b' || 'strong' => const TextStyle(fontWeight: FontWeight.bold),
                'i' || 'em' => const TextStyle(fontStyle: FontStyle.italic),
                _ => null,
              },
              children: spans(node.nodes),
            ),
            if (node.localName == 'p' || node.localName == 'div')
              const TextSpan(text: '\n\n'),
          ],
    ];
    TextSpan trimEnd(TextSpan span) {
      final children = List<InlineSpan>.of(span.children ?? const []);
      while (children.isNotEmpty) {
        final last = trimEnd(children.last as TextSpan);
        if (last.toPlainText().isNotEmpty) {
          children[children.length - 1] = last;
          return TextSpan(
            text: span.text,
            style: span.style,
            children: children,
          );
        }
        children.removeLast();
      }
      return TextSpan(text: span.text?.trimRight(), style: span.style);
    }

    // Paragraph separators at the end are not hidden editorial content.
    _parsedSpan = trimEnd(TextSpan(children: spans(fragment.nodes)));
    _isEmpty = _parsedSpan.toPlainText().trim().isEmpty;
  }

  void _showFullDescription(BuildContext context, TextSpan text) {
    showAppModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      builder: (context) {
        final theme = Theme.of(context);
        // As tall as the text, up to most of the screen.
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      HeaderCircleButton(
                        buttonSize: 48,
                        icon: context.isMornye
                            ? CupertinoIcons.xmark
                            : Icons.close,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    child: SelectionArea(
                      child: Text.rich(
                        text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: context.isMornye ? 18 : 16,
                          height: 1.45,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _measureHasMore(
    BuildContext context,
    double maxWidth,
    TextStyle? previewStyle,
  ) {
    final defaultStyle = DefaultTextStyle.of(context).style;
    final boldText = MediaQuery.boldTextOf(context);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final key = (
      maxWidth,
      defaultStyle,
      previewStyle,
      boldText,
      direction,
      scaler,
      locale,
    );
    if (_measureKey == key) return _hasMore;
    var effectiveStyle = defaultStyle.merge(previewStyle);
    if (boldText) {
      effectiveStyle = effectiveStyle.merge(
        const TextStyle(fontWeight: FontWeight.bold),
      );
    }
    final painter = TextPainter(
      text: TextSpan(style: effectiveStyle, children: [_parsedSpan]),
      maxLines: 2,
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: maxWidth);
    _hasMore = painter.didExceedMaxLines;
    painter.dispose();
    _measureKey = key;
    return _hasMore;
  }

  @override
  Widget build(BuildContext context) {
    _ensureParsed();
    if (_isEmpty) return const SizedBox.shrink();
    final text = _parsedSpan;
    final theme = Theme.of(context);
    final more = MaterialLocalizations.of(context).moreButtonTooltip;
    final previewStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: context.isMornye ? 17 : 16,
      height: 1.4,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final hasMore = _measureHasMore(
            context,
            constraints.maxWidth,
            previewStyle,
          );
          return Column(
            children: [
              InkWell(
                onTap: hasMore
                    ? () => _showFullDescription(context, text)
                    : null,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: widget.underSheetEdge ? 0 : 8,
                    bottom: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text.rich(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: previewStyle,
                          // The line's own space above would add to the edge.
                          textHeightBehavior: widget.underSheetEdge
                              ? const TextHeightBehavior(
                                  applyHeightToFirstAscent: false,
                                )
                              : null,
                        ),
                      ),
                      if (hasMore) ...[
                        const SizedBox(width: 8),
                        Text(
                          context.isMornye ? more.toUpperCase() : more,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Divider(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
              ),
            ],
          );
        },
      ),
    );
  }
}
