import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/collection_scaffold.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('localized inset preserves collection pixels in $brightness', (
      tester,
    ) async {
      final capture = GlobalKey();
      final inset = ValueNotifier(140.0);
      final scroll = ScrollController();
      addTearDown(inset.dispose);
      addTearDown(scroll.dispose);

      Future<void> pumpPage({required bool explicitInset}) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: MornyeTheme.build(brightness),
            home: ValueListenableBuilder<double>(
              valueListenable: inset,
              builder: (context, value, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: EdgeInsets.only(top: 24, bottom: value)),
                child: child!,
              ),
              child: RepaintBoundary(
                key: capture,
                child: Builder(
                  builder: (context) => CollectionScaffold(
                    scrollController: scroll,
                    isSelectionMode: false,
                    onExitSelectionMode: () {},
                    bottomInset: explicitInset
                        ? context.navBarBottomInset
                        : null,
                    appBar: const SliverToBoxAdapter(
                      child: SizedBox(height: 120, child: Text('Collection')),
                    ),
                    slivers: [
                      SliverFixedExtentList.builder(
                        itemExtent: 56,
                        itemCount: 30,
                        itemBuilder: (_, index) => ListTile(
                          leading: const Icon(Icons.music_note),
                          title: Text('Track $index'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<Uint8List> pixels() async {
        return (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(capture),
          );
          final image = await boundary.toImage();
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return Uint8List.fromList(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        }))!;
      }

      // Compare the previous, parent-owned inset with the localized spacer at
      // intermediate animation heights, including the final scroll position.
      final expected = <double, Uint8List>{};
      final extents = <double, double>{};
      await pumpPage(explicitInset: true);
      for (final height in [140.0, 118.0, 86.0, 64.0, 0.0]) {
        inset.value = height;
        await tester.pumpAndSettle();
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expected[height] = await pixels();
        extents[height] = scroll.position.maxScrollExtent;
      }

      await pumpPage(explicitInset: false);
      for (final height in expected.keys) {
        inset.value = height;
        await tester.pumpAndSettle();
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(scroll.position.maxScrollExtent, extents[height]);
        expect(await pixels(), orderedEquals(expected[height]!));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
