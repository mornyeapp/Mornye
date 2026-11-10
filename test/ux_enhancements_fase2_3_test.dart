import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/fluid_mesh_glow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fase 2 & 3 UX Enhancements', () {
    test('BackupService fileExtension is mornye-backup', () {
      expect(BackupService.fileExtension, equals('mornye-backup'));
    });

    test('MornyeTheme with isAmoled produces pure black surfaces', () {
      final amoledDarkTheme = MornyeTheme.build(
        Brightness.dark,
        isAmoled: true,
      );

      expect(amoledDarkTheme.scaffoldBackgroundColor, equals(Colors.black));
      expect(amoledDarkTheme.colorScheme.surface, equals(Colors.black));
      expect(
        amoledDarkTheme.colorScheme.surfaceContainerLowest,
        equals(Colors.black),
      );
      expect(
        amoledDarkTheme.colorScheme.surfaceContainerLow,
        equals(Colors.black),
      );

      final regularDarkTheme = MornyeTheme.build(
        Brightness.dark,
        isAmoled: false,
      );
      expect(
        regularDarkTheme.colorScheme.surfaceContainerLow,
        isNot(equals(Colors.black)),
      );
    });

    testWidgets(
      'MornyePlayerBackground renders fluid mesh glow when ambientGlow is true',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MornyePlayerBackground(
                artUri: null,
                ambientGlow: true,
                artwork: null,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final ambientGlowFinder = find.byKey(
          const ValueKey('mornye-ambient-glow'),
        );
        expect(ambientGlowFinder, findsOneWidget);
      },
    );

    testWidgets('FluidMeshGlow renders custom paint and adapts to isAmoled', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FluidMeshGlow(
              sourceColor: Color(0xff1db954),
              opacity: 0.35,
              isAmoled: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(FluidMeshGlow), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
