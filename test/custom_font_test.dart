import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/custom_font_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'import persists a private copy, restores after restart, rejects damage',
    () async {
      final directory = await Directory.systemTemp.createTemp('font-import-');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = await File('assets/fonts/InterVariable.ttf').readAsBytes();
      var loads = 0;
      CustomFontService service() => CustomFontService(
        directory: () async => directory,
        loadFont: (_, data) async {
          loads++;
          expect(data, bytes);
        },
      );
      final importer = service();
      final id = await importer.import(bytes);
      expect(await importer.restore(id), 'ImportedFont_$id');
      expect(loads, 1);
      expect(await service().restore(id), 'ImportedFont_$id');
      expect(loads, 2);
      await File('${directory.path}/$id.font').writeAsBytes([1, 2]);
      expect(await service().restore(id), isNull);
      expect(await service().restore('../outside'), isNull);
      expect(
        () => CustomFontService.validate(Uint8List(12)),
        throwsFormatException,
      );
      expect(
        () => CustomFontService.validate(bytes.sublist(0, 32)),
        throwsFormatException,
      );
    },
  );

  test(
    'restore validates and hashes a large font off the UI isolate',
    () async {
      final directory = await Directory.systemTemp.createTemp('font-restore-');
      addTearDown(() => directory.delete(recursive: true));
      final font = await File('assets/fonts/InterVariable.ttf').readAsBytes();
      // Trailing bytes keep the table directory valid.
      final bytes = Uint8List(CustomFontService.maxBytes)..setAll(0, font);
      final hashing = Stopwatch()..start();
      final id = sha256.convert(bytes).toString();
      hashing.stop();
      await File('${directory.path}/$id.font').writeAsBytes(bytes);
      final service = CustomFontService(
        directory: () async => directory,
        loadFont: (_, data) async => expect(data.length, bytes.length),
      );

      var longestStall = Duration.zero;
      final ticks = Stopwatch()..start();
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (ticks.elapsed > longestStall) longestStall = ticks.elapsed;
        ticks.reset();
      });
      addTearDown(timer.cancel);
      expect(await service.restore(id), 'ImportedFont_$id');
      // A tick after the last stall records it.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      timer.cancel();

      // On the UI isolate the stall was the whole hash (110 of 123 ms here).
      expect(longestStall * 3, lessThan(hashing.elapsed));
    },
  );

  test('font choice survives bootstrap, export and reset', () async {
    SharedPreferences.setMockInitialValues({kUseSystemFontKey: true});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(themeProvider.notifier);
    await notifier.setCustomFont('selected-font', 'My font.ttf');
    final prefs = await SharedPreferences.getInstance();
    final theme = loadBootstrapThemeSettings(prefs);
    expect(theme.customFontId, 'selected-font');
    expect(theme.customFontName, 'My font.ttf');
    expect(ThemeSettings.fromJson(theme.toJson()), theme);
    await notifier.setCustomFont('', '');
    expect(loadBootstrapThemeSettings(prefs).customFontId, isEmpty);
    expect(loadBootstrapThemeSettings(prefs).useSystemFont, isTrue);
  });

  testWidgets(
    'custom typography survives Mornye local surface reconstruction',
    (tester) async {
      final theme = MornyeTheme.build(
        Brightness.dark,
        fontFamily: 'ImportedFont_test',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              final surface = MornyeTheme.fromContext(
                context,
                chromeSurface: Colors.red,
              );
              expect(
                surface.textTheme.bodyLarge!.fontFamily,
                'ImportedFont_test',
              );
              expect(
                surface.textTheme.headlineSmall!.fontFamily,
                'ImportedFont_test',
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        AppTheme.light(
          fontFamily: 'ImportedFont_test',
        ).textTheme.bodyMedium!.fontFamily,
        'ImportedFont_test',
      );
      expect(
        AppTheme.dark(
          fontFamily: 'ImportedFont_test',
        ).textTheme.bodyMedium!.fontFamily,
        'ImportedFont_test',
      );
      expect(
        MornyeTheme.build(Brightness.dark).textTheme.bodyLarge!.fontFamily,
        isNot('ImportedFont_test'),
      );
    },
  );
}
