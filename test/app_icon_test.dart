import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mornye/theme/material_symbols.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';

Widget _host(Widget child, {bool mornye = false, bool reduceMotion = false}) {
  return MaterialApp(
    theme: ThemeData(extensions: [if (mornye) const MornyeTheme()]),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

Icon _drawnIcon(WidgetTester tester) =>
    tester.widget<Icon>(find.byType(Icon).first);

void main() {
  test('legacy icons keep their filled or outlined meaning', () {
    expect(materialSymbolFor(Icons.favorite), (
      icon: Symbols.favorite_rounded,
      filled: true,
    ));
    expect(materialSymbolFor(Icons.favorite_border), (
      icon: Symbols.favorite_rounded,
      filled: false,
    ));
    expect(materialSymbolFor(Icons.delete_outline)?.filled, isFalse);
    expect(materialSymbolFor(Icons.home_outlined)?.filled, isFalse);
    expect(materialSymbolFor(Icons.album_rounded)?.filled, isTrue);
    expect(materialSymbolFor(Icons.warning_amber_rounded)?.filled, isFalse);
  });

  test('unmapped and non-Material icons have no symbol', () {
    expect(materialSymbolFor(null), isNull);
    expect(materialSymbolFor(Icons.telegram), isNull);
    expect(materialSymbolFor(CupertinoIcons.heart), isNull);
  });

  testWidgets('Material draws the rounded symbol with the legacy fill', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const AppIcon(Icons.favorite_border)));
    final icon = _drawnIcon(tester);
    expect(icon.icon, Symbols.favorite_rounded);
    expect(icon.fill, 0);

    await tester.pumpWidget(_host(const AppIcon(Icons.favorite, size: 18)));
    final filled = _drawnIcon(tester);
    expect(filled.fill, 1);
    expect(filled.opticalSize, 20);
  });

  testWidgets('Mornye keeps the original glyph or its Cupertino mapping', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const AppIcon(Icons.favorite_border), mornye: true),
    );
    expect(_drawnIcon(tester).icon, Icons.favorite_border);

    await tester.pumpWidget(
      _host(const AppIcon.adaptive(Icons.favorite), mornye: true),
    );
    await tester.pumpAndSettle();
    expect(_drawnIcon(tester).icon, CupertinoIcons.heart_fill);
  });

  testWidgets('symbolIconWidget converts plain icons only', (tester) async {
    const plain = Icon(Icons.close, size: 20);
    expect(symbolIconWidget(plain), isA<AppIcon>());
    const other = SizedBox();
    expect(identical(symbolIconWidget(other), other), isTrue);
  });

  testWidgets('AppIconButton uses the expressive button for default sizes', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        AppIconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => taps++,
        ),
      ),
    );
    expect(find.byType(M3EIconButton), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
    expect(_drawnIcon(tester).icon, Symbols.close_rounded);
    await tester.tap(find.byType(M3EIconButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('AppIconButton keeps IconButton for dense, Mornye and reduced '
      'motion layouts', (tester) async {
    Widget button({EdgeInsets? padding}) => AppIconButton(
      tooltip: 'Close',
      icon: const Icon(Icons.close),
      padding: padding,
      onPressed: () {},
    );

    await tester.pumpWidget(_host(button(padding: EdgeInsets.zero)));
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byType(M3EIconButton), findsNothing);

    // MaterialApp animates theme changes; settle before reading the theme.
    await tester.pumpWidget(_host(button(), mornye: true));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsOneWidget);
    expect(_drawnIcon(tester).icon, Icons.close);

    await tester.pumpWidget(_host(button(), reduceMotion: true));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsOneWidget);
  });
}
