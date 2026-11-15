import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/scroll_edge_fade.dart';

void main() {
  Future<void> pumpFade(WidgetTester tester, {required bool fadeContent}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ScrollEdgeFade(
                fadeContent: fadeContent,
                size: 48,
                child: ListView(
                  children: [
                    for (var i = 0; i < 30; i++)
                      SizedBox(height: 40, child: Text('Line $i')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('fadeContent masks the content instead of overlaying it', (
    tester,
  ) async {
    await pumpFade(tester, fadeContent: true);
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.byType(DecoratedBox), findsNothing);
  });

  testWidgets('the default fade paints the background over the edge', (
    tester,
  ) async {
    await pumpFade(tester, fadeContent: false);
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNothing);
  });
}
