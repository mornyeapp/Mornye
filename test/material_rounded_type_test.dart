import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

const _rounded = [FontVariation('ROND', AppTheme.brandRoundness)];

Map<String, TextStyle?> _roles(TextTheme t) => {
  'displayLarge': t.displayLarge,
  'displayMedium': t.displayMedium,
  'displaySmall': t.displaySmall,
  'headlineLarge': t.headlineLarge,
  'headlineMedium': t.headlineMedium,
  'headlineSmall': t.headlineSmall,
  'titleLarge': t.titleLarge,
  'titleMedium': t.titleMedium,
  'titleSmall': t.titleSmall,
  'bodyLarge': t.bodyLarge,
  'bodyMedium': t.bodyMedium,
  'bodySmall': t.bodySmall,
  'labelLarge': t.labelLarge,
  'labelMedium': t.labelMedium,
  'labelSmall': t.labelSmall,
};

bool _isBrandRole(String role) =>
    role.startsWith('display') ||
    role.startsWith('headline') ||
    role.startsWith('title');

/// The axes of the font's `fvar` table as tag to (min, default, max).
Map<String, (double, double, double)> _fvarAxes(ByteData font) {
  double fixed(int offset) => font.getInt32(offset) / 65536;
  String tag(int offset) =>
      String.fromCharCodes(font.buffer.asUint8List(offset, 4));
  final tables = font.getUint16(4);
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    if (tag(record) != 'fvar') continue;
    final fvar = font.getUint32(record + 8);
    final axesStart = fvar + font.getUint16(fvar + 4);
    final count = font.getUint16(fvar + 8);
    final size = font.getUint16(fvar + 10);
    return {
      for (var a = 0; a < count; a++)
        tag(axesStart + a * size): (
          fixed(axesStart + a * size + 4),
          fixed(axesStart + a * size + 8),
          fixed(axesStart + a * size + 12),
        ),
    };
  }
  return const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Material type', () {
    final plain = ThemeData(
      useMaterial3: true,
      fontFamily: AppTheme.bundledFontFamily,
    );

    test('brand roles are rounded and keep their weight', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        for (final (text, base) in [
          (theme.textTheme, plain.textTheme),
          (theme.primaryTextTheme, plain.primaryTextTheme),
        ]) {
          final baseRoles = _roles(base);
          for (final MapEntry(key: role, value: style) in _roles(
            text,
          ).entries) {
            final reason = '${theme.brightness} $role';
            expect(style!.fontFamily, AppTheme.bundledFontFamily);
            expect(style.fontWeight, baseRoles[role]!.fontWeight);
            expect(style.fontSize, baseRoles[role]!.fontSize);
            if (_isBrandRole(role)) {
              // No wght entry: the engine derives it from fontWeight.
              expect(style.fontVariations, _rounded, reason: reason);
            } else {
              expect(style.fontVariations, isNull, reason: reason);
            }
          }
        }
      }
    });

    test('a weight override keeps the rounded terminals', () {
      final title = AppTheme.light().textTheme.titleMedium!.copyWith(
        fontWeight: FontWeight.w700,
      );
      expect(title.fontWeight, FontWeight.w700);
      expect(title.fontVariations, _rounded);
    });

    test('system and imported fonts get no axes', () {
      for (final theme in [
        AppTheme.light(useSystemFont: true),
        AppTheme.dark(fontFamily: 'ImportedFont_test'),
      ]) {
        for (final style in _roles(theme.textTheme).values) {
          expect(style!.fontVariations, isNull);
        }
      }
    });
  });

  test('Mornye type does not change', () {
    for (final brightness in Brightness.values) {
      for (final style in _roles(
        MornyeTheme.build(brightness).textTheme,
      ).values) {
        expect(style!.fontVariations, isNull);
        expect(style.fontFamily, isNot(AppTheme.bundledFontFamily));
      }
    }
  });

  group('bundled Google Sans Flex', () {
    late ByteData font;

    setUpAll(() async {
      font = await rootBundle.load('assets/fonts/GoogleSansFlex.ttf');
      await (FontLoader(
        AppTheme.bundledFontFamily,
      )..addFont(Future.value(font))).load();
    });

    test('keeps the weight, width and rounded axes', () {
      final axes = _fvarAxes(font);
      expect(axes.keys, unorderedEquals(['wght', 'wdth', 'ROND']));
      expect(axes['wght']!.$2, 400);
      expect(axes['wdth']!.$2, 100);
      expect(axes['ROND'], (0, 0, 100));
    });

    test('ROND keeps advances and the weight still varies', () {
      double width(FontWeight weight, {List<FontVariation>? axes}) {
        final painter = TextPainter(
          text: TextSpan(
            text: 'Expressive 0123456789',
            style: TextStyle(
              fontFamily: AppTheme.bundledFontFamily,
              fontSize: 20,
              fontWeight: weight,
              fontVariations: axes,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        addTearDown(painter.dispose);
        return painter.width;
      }

      final regular = width(FontWeight.w400);
      expect(width(FontWeight.w400, axes: _rounded), regular);
      final bold = width(FontWeight.w700, axes: _rounded);
      expect(bold, greaterThan(regular));
      expect(
        bold,
        width(
          FontWeight.w400,
          axes: [..._rounded, const FontVariation('wght', 700)],
        ),
        reason: 'fontWeight drives wght when only ROND is set',
      );
    });
  });
}
