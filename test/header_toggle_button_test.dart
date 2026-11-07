import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';

Widget _app(Widget child, {bool reduced = false}) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

Widget _love(bool loved) => HeaderCircleButton(
  icon: loved ? Icons.favorite : Icons.favorite_border,
  selected: loved,
  tonal: true,
  tooltip: 'Love',
  onPressed: () {},
);

void main() {
  testWidgets('the Material Love button is an expressive toggle', (
    tester,
  ) async {
    final loved = ValueNotifier(false);
    addTearDown(loved.dispose);
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: loved,
          builder: (context, value, _) => _love(value),
        ),
      ),
    );
    expect(
      tester.widget<M3EIconButton>(find.byType(M3EIconButton)).isSelected,
      isFalse,
    );

    loved.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      tester.widget<M3EIconButton>(find.byType(M3EIconButton)).isSelected,
      isTrue,
    );
    // The two glyphs crossfade on the effects spring.
    expect(
      find.descendant(
        of: find.byType(AnimatedSwitcher),
        matching: find.byKey(const ValueKey(Icons.favorite_border)),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey(Icons.favorite_border)), findsNothing);
    expect(find.byKey(const ValueKey(Icons.favorite)), findsOneWidget);
  });

  testWidgets('reduced motion keeps a static toggle', (tester) async {
    await tester.pumpWidget(_app(_love(true), reduced: true));
    expect(find.byType(M3EIconButton), findsNothing);
    expect(tester.widget<IconButton>(find.byType(IconButton)).isSelected, true);
  });

  testWidgets('plain actions stay plain', (tester) async {
    await tester.pumpWidget(
      _app(
        HeaderCircleButton(
          icon: Icons.playlist_add,
          tonal: true,
          tooltip: 'Add',
          onPressed: () {},
        ),
      ),
    );
    expect(
      tester.widget<M3EIconButton>(find.byType(M3EIconButton)).isSelected,
      isNull,
    );
    expect(find.byType(AnimatedSwitcher), findsNothing);
  });
}
