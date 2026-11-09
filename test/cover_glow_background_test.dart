import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

void main() {
  testWidgets('MornyePlayerBackground renders ambient glow when ambientGlow is true', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MornyePlayerBackground(
            artUri: null,
            ambientGlow: true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('mornye-ambient-glow')), findsOneWidget);
  });

  testWidgets('MornyePlayerBackground omits ambient glow when ambientGlow is false', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MornyePlayerBackground(
            artUri: null,
            ambientGlow: false,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('mornye-ambient-glow')), findsNothing);
  });
}
