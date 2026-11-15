import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:html/dom.dart' as dom;
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

/// A short editorial preview below the album controls, with a full reading sheet.
class AlbumDescription extends StatelessWidget {
  const AlbumDescription({
    super.key,
    required this.title,
    required this.description,
  });

  final String title;
  final String description;

  TextSpan _text() {
    final fragment = parseEditorialNotes(description);
    final formatted = fragment.children.isNotEmpty;
    List<InlineSpan> spans(List<dom.Node> nodes) => [
      for (final node in nodes)
        if (node is dom.Text)
          TextSpan(
            text: formatted
                // Catalog notes can mix inline markup with literal paragraph
                // breaks. Only collapse horizontal whitespace.
                ? node.data.replaceAll(RegExp(r'[\t\f\v ]+'), ' ')
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
            if (['p', 'div'].contains(node.localName))
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
    return trimEnd(TextSpan(children: spans(fragment.nodes)));
  }

  void _showFullDescription(BuildContext context, TextSpan text) {
    showAppModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.9,
          child: SafeArea(
            top: false,
            child: Column(
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
                          title,
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
                Expanded(
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

  @override
  Widget build(BuildContext context) {
    final text = _text();
    if (text.toPlainText().trim().isEmpty) return const SizedBox.shrink();
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
          var effectiveStyle = DefaultTextStyle.of(
            context,
          ).style.merge(previewStyle);
          if (MediaQuery.boldTextOf(context)) {
            effectiveStyle = effectiveStyle.merge(
              const TextStyle(fontWeight: FontWeight.bold),
            );
          }
          final painter = TextPainter(
            text: TextSpan(style: effectiveStyle, children: [text]),
            maxLines: 2,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final hasMore = painter.didExceedMaxLines;
          painter.dispose();
          return Column(
            children: [
              InkWell(
                onTap: hasMore
                    ? () => _showFullDescription(context, text)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text.rich(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: previewStyle,
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
