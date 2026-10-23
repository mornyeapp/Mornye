import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/extension_row.dart';

const _buttonKey = ValueKey('extension-row-button');

Widget _row({
  required double width,
  double buttonWidth = 140,
  bool measured = true,
  double textScale = 1,
}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: ExtensionRow(
          showDivider: false,
          avatar: const ExtensionAvatar(fallbackIcon: Icons.extension),
          title: const Text('Extension name'),
          subtitle: const Text('Description'),
          trailingWidth: measured ? buttonWidth : null,
          trailing: SizedBox(
            key: _buttonKey,
            width: buttonWidth,
            height: 40,
            child: FilledButton(onPressed: () {}, child: const Text('Install')),
          ),
        ),
      ),
    ),
  ),
);

bool _buttonBelow(WidgetTester tester) =>
    tester.getRect(find.byKey(_buttonKey)).top >
    tester.getRect(find.text('Description')).bottom;

void main() {
  testWidgets('a row too narrow for its button puts it under the description', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 360));

    final title = tester.getRect(find.text('Extension name'));
    final button = tester.getRect(find.byKey(_buttonKey));
    expect(_buttonBelow(tester), isTrue);
    expect(button.left, title.left);
    // The title keeps the whole text column.
    final column = find
        .ancestor(
          of: find.text('Extension name'),
          matching: find.byType(Column),
        )
        .first;
    expect(tester.getSize(column).width, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone row keeps a short button beside the text', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 380, buttonWidth: 116));

    final title = tester.getRect(find.text('Extension name'));
    final button = tester.getRect(find.byKey(_buttonKey));
    expect(button.left, greaterThan(title.right));
    expect(
      button.center.dy,
      closeTo(tester.getRect(find.byType(Row).first).center.dy, 1),
    );

    // A longer label on the same row would squeeze the title.
    await tester.pumpWidget(_row(width: 380, buttonWidth: 150));
    expect(_buttonBelow(tester), isTrue);
  });

  testWidgets('a wide row keeps the button beside the text', (tester) async {
    await tester.pumpWidget(_row(width: 700));

    final title = tester.getRect(find.text('Extension name'));
    expect(
      tester.getRect(find.byKey(_buttonKey)).left,
      greaterThan(title.right),
    );
  });

  testWidgets('large text needs a wider title beside the button', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 420));
    expect(_buttonBelow(tester), isFalse);

    await tester.pumpWidget(_row(width: 420, textScale: 1.3));
    expect(_buttonBelow(tester), isTrue);
  });

  testWidgets('a row without a trailing width keeps its control beside', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 360, measured: false));

    final title = tester.getRect(find.text('Extension name'));
    expect(
      tester.getRect(find.byKey(_buttonKey)).left,
      greaterThan(title.left + 100),
    );
  });
}
