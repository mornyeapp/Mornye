import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/app_menu_button.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';

// Wider than the menu's usual 224dp beside an icon button, as on a phone.
const _long = 'Sembunyikan Terjemahan';

Future<void> _openMenu(WidgetTester tester, List<String> labels) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomRight,
          child: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () => showAppMenuPopup<String>(
                context: context,
                preferAbove: true,
                items: [
                  for (final label in labels)
                    AppMenuItem(
                      value: label,
                      label: label,
                      leading: const Icon(Icons.translate),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

bool _cut(WidgetTester tester, String label) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
  return paragraph.didExceedMaxLines;
}

void main() {
  testWidgets('a long label widens the menu instead of being cut', (
    tester,
  ) async {
    await _openMenu(tester, ['Edit lyrics', _long]);
    expect(find.text(_long), findsOneWidget);
    expect(_cut(tester, _long), isFalse);
  });

  testWidgets('a context menu widens to a long label too', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () => showContextMenu(
                  context,
                  position: const Offset(200, 200),
                  groups: [
                    [
                      ContextMenuAction(
                        icon: Icons.translate,
                        label: _long,
                        onSelected: () {},
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text(_long), findsOneWidget);
    expect(_cut(tester, _long), isFalse);
  });

  testWidgets('short labels keep the menu at its usual width', (tester) async {
    await _openMenu(tester, ['Edit', 'Share']);
    final width = tester.getSize(find.text('Share')).width;
    expect(_cut(tester, 'Share'), isFalse);
    expect(width, lessThan(120));
  });
}
