import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';

class _Settings extends SettingsNotifier {
  _Settings(this._forceBlur);

  final bool _forceBlur;

  @override
  AppSettings build() => AppSettings(forceBackdropBlur: _forceBlur);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openMenu(
    WidgetTester tester, {
    required Rect anchor,
    required ValueChanged<String?> onResult,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool reduceMotion = false,
    bool preferAbove = false,
    bool highContrast = false,
    bool forceBlur = false,
    bool lowEnd = false,
    Color? backgroundColor,
    GlobalKey? capture,
    double glassClarity = kDefaultMornyeGlassClarity,
    bool dense = false,
    Color? chromeSurface,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(forceBlur)),
          lowEndDeviceProvider.overrideWithValue(lowEnd),
          backdropBlurEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(
            brightness,
            glassClarity: glassClarity,
            chromeSurface: chromeSurface,
          ),
          builder: (context, child) => RepaintBoundary(
            key: capture,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.fromLTRB(0, 24, 0, 24),
                textScaler: TextScaler.linear(textScale),
                disableAnimations: reduceMotion,
                highContrast: highContrast,
              ),
              child: child!,
            ),
          ),
          home: Scaffold(
            backgroundColor: backgroundColor,
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    final result = await showMornyeContextMenu<String>(
                      context: context,
                      anchor: anchor,
                      preferAbove: preferAbove,
                      builder: (menuContext) {
                        MornyeMenuAction action(String label, IconData icon) =>
                            MornyeMenuAction(
                              icon: icon,
                              label: label,
                              onPressed: () =>
                                  Navigator.of(menuContext).pop(label),
                            );
                        return MornyeContextMenu(
                          dense: dense,
                          inheritSurface: chromeSurface != null,
                          quickActions: [
                            action(
                              'Download',
                              CupertinoIcons.arrow_down_circle,
                            ),
                            action('Favorite', CupertinoIcons.star),
                            action('Share', CupertinoIcons.share),
                          ],
                          groups: [
                            [
                              action('Play', CupertinoIcons.play),
                              action('Shuffle', CupertinoIcons.shuffle),
                            ],
                            [
                              action(
                                'Add to playlist',
                                CupertinoIcons.text_badge_plus,
                              ),
                              action('Play next', CupertinoIcons.text_insert),
                            ],
                            [action('Remove', CupertinoIcons.trash)],
                          ],
                        );
                      },
                    );
                    onResult(result);
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<List<Color>> samplePixels(
    WidgetTester tester,
    GlobalKey capture,
    List<Offset> positions,
  ) async => (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return positions.map((position) {
        final local = boundary.globalToLocal(position);
        final index = (local.dy.floor() * image.width + local.dx.floor()) * 4;
        return Color.fromARGB(
          pixels.getUint8(index + 3),
          pixels.getUint8(index),
          pixels.getUint8(index + 1),
          pixels.getUint8(index + 2),
        );
      }).toList();
    } finally {
      image.dispose();
    }
  }))!;

  for (final brightness in Brightness.values) {
    for (final clarity in [0.0, kDefaultMornyeGlassClarity, 1.0]) {
      for (final background in [
        Colors.white,
        Colors.black,
        const Color(0xff6c3a22),
      ]) {
        testWidgets(
          'menu labels stay readable over $background ($brightness, clarity: $clarity)',
          (tester) async {
            final originalDisableShadows = debugDisableShadows;
            debugDisableShadows = false;
            try {
              final capture = GlobalKey();
              await openMenu(
                tester,
                anchor: const Rect.fromLTWH(330, 144, 44, 44),
                brightness: brightness,
                glassClarity: clarity,
                backgroundColor: background,
                capture: capture,
                onResult: (_) {},
              );
              final menu = tester.getRect(find.byType(MornyeContextMenu));
              final pixels = await samplePixels(tester, capture, [
                for (final x in [menu.left + 8, menu.right - 8])
                  for (final fraction in [0.25, 0.5, 0.75])
                    Offset(x, menu.top + menu.height * fraction),
              ]);
              final foreground = MornyeTheme.build(
                brightness,
              ).colorScheme.onSurface;
              for (final inside in pixels) {
                // Busy lyrics and bright artwork must not wash out either label.
                for (final textColor in [
                  foreground,
                  Color.alphaBlend(foreground.withValues(alpha: 0.96), inside),
                ]) {
                  final luminances = [
                    inside.computeLuminance(),
                    textColor.computeLuminance(),
                  ]..sort();
                  final contrast =
                      (luminances.last + 0.05) / (luminances.first + 0.05);
                  expect(contrast, greaterThanOrEqualTo(4.5));
                }
                // The panel remains even at both edges without an offset lens.
                expect(inside.r, closeTo(pixels.first.r, 0.015));
                expect(inside.g, closeTo(pixels.first.g, 0.015));
                expect(inside.b, closeTo(pixels.first.b, 0.015));
              }
              expect(tester.takeException(), isNull);
            } finally {
              debugDisableShadows = originalDisableShadows;
            }
          },
        );
      }
    }

    testWidgets('menu stays on screen near a bottom edge ($brightness)', (
      tester,
    ) async {
      String? result;
      const anchor = Rect.fromLTWH(338, 728, 36, 44);
      await openMenu(
        tester,
        anchor: anchor,
        brightness: brightness,
        onResult: (value) => result = value,
      );
      final rect = tester.getRect(find.byType(MornyeContextMenu));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(374));
      expect(rect.top, greaterThanOrEqualTo(40));
      expect(rect.bottom, lessThan(anchor.top));
      expect(find.text('Share').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(result, 'Share');
      expect(find.byType(MornyeContextMenu), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (origin, expected) in [
    (null, const Offset(100, 200)),
    (const Offset(118, 178), const Offset(118, 178)),
  ]) {
    testWidgets('a context menu opens out of ${expected.dx}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [backdropBlurEnabledProvider.overrideWithValue(false)],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.light),
            home: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showContextMenu(
                    context,
                    position: const Offset(100, 200),
                    origin: origin,
                    groups: [
                      [
                        ContextMenuAction(
                          icon: Icons.folder_open_outlined,
                          label: 'Open folder',
                          onSelected: () {},
                        ),
                      ],
                    ],
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final Object flight = tester.widget(
        find.byWidgetPredicate(
          (widget) => '${widget.runtimeType}' == '_MenuFlight',
        ),
      );
      expect((flight as dynamic).anchor, expected);
    });
  }

  testWidgets('frosted glass still carries the artwork color', (tester) async {
    final colors = <Color>[];
    for (final background in [
      const Color(0xff804020),
      const Color(0xff204080),
    ]) {
      final capture = GlobalKey();
      await openMenu(
        tester,
        anchor: const Rect.fromLTWH(330, 144, 44, 44),
        brightness: Brightness.dark,
        backgroundColor: background,
        capture: capture,
        onResult: (_) {},
      );
      final rect = tester.getRect(find.byType(MornyeContextMenu));
      colors.addAll(
        await samplePixels(tester, capture, [
          Offset(rect.left + 8, rect.center.dy),
        ]),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(colors.first.r, greaterThan(colors.last.r + 0.03));
    expect(colors.last.b, greaterThan(colors.first.b + 0.03));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact menus save space while keeping 48 dp touch targets', (
    tester,
  ) async {
    await openMenu(
      tester,
      anchor: const Rect.fromLTWH(330, 144, 44, 44),
      onResult: (_) {},
    );
    final originalHeight = tester
        .getSize(find.byType(MornyeContextMenu))
        .height;
    await tester.pumpWidget(const SizedBox());
    await openMenu(
      tester,
      anchor: const Rect.fromLTWH(330, 144, 44, 44),
      dense: true,
      onResult: (_) {},
    );
    expect(
      tester.getSize(find.byType(MornyeContextMenu)).height,
      lessThan(originalHeight - 30),
    );
    for (final button in find.byType(CupertinoButton).evaluate()) {
      final bounds = tester.getSize(
        find.byElementPredicate((e) => e == button),
      );
      expect(bounds.width, greaterThanOrEqualTo(48));
      expect(bounds.height, greaterThanOrEqualTo(48));
    }
    expect(find.text('Share').hitTestable(), findsOneWidget);
    expect(find.text('Remove').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover-tinted menus preserve their hue and clear text contrast', (
    tester,
  ) async {
    final colors = <Color>[];
    for (final cover in [const Color(0xff5f3a2d), const Color(0xff2d3a5f)]) {
      final capture = GlobalKey();
      await openMenu(
        tester,
        anchor: const Rect.fromLTWH(330, 144, 44, 44),
        brightness: Brightness.dark,
        glassClarity: 1,
        backgroundColor: Colors.white,
        chromeSurface: cover,
        capture: capture,
        dense: true,
        onResult: (_) {},
      );
      final bounds = tester.getRect(find.byType(MornyeContextMenu));
      final pixels = await samplePixels(tester, capture, [
        Offset(bounds.left + 8, bounds.center.dy),
      ]);
      final color = pixels.single;
      colors.add(color);
      expect(
        1.05 / (color.computeLuminance() + 0.05),
        greaterThanOrEqualTo(4.5),
      );
      await tester.pumpWidget(const SizedBox());
    }
    expect(colors.first.r, greaterThan(colors.first.b + 0.03));
    expect(colors.last.b, greaterThan(colors.last.r + 0.03));
    expect(tester.takeException(), isNull);
  });

  for (final highContrast in [false, true]) {
    testWidgets('menu stays readable without blur (contrast: $highContrast)', (
      tester,
    ) async {
      final capture = GlobalKey();
      await openMenu(
        tester,
        anchor: const Rect.fromLTWH(330, 144, 44, 44),
        brightness: Brightness.dark,
        backgroundColor: const Color(0xff6c3a22),
        highContrast: highContrast,
        lowEnd: !highContrast,
        capture: capture,
        onResult: (_) {},
      );
      final menu = find.byType(MornyeContextMenu);
      final rect = tester.getRect(menu);
      final pixels = await samplePixels(tester, capture, [
        Offset(rect.left + 8, rect.center.dy),
      ]);
      final theme = MornyeTheme.build(Brightness.dark);
      expect(pixels.single, theme.colorScheme.surfaceContainerHigh);
      expect(
        find.descendant(of: menu, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('glass override reaches context menu overlays', (tester) async {
    await openMenu(
      tester,
      anchor: const Rect.fromLTWH(330, 144, 44, 44),
      brightness: Brightness.dark,
      highContrast: true,
      forceBlur: true,
      onResult: (_) {},
    );
    final menu = find.byType(MornyeContextMenu);
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(MediaQuery.highContrastOf(tester.element(menu)), isTrue);
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large text in landscape keeps shortcuts and last action usable',
    (tester) async {
      String? result;
      await openMenu(
        tester,
        anchor: const Rect.fromLTWH(600, 200, 24, 44),
        size: const Size(640, 320),
        textScale: 2.5,
        preferAbove: true,
        onResult: (value) => result = value,
      );
      final rect = tester.getRect(find.byType(MornyeContextMenu));
      expect(rect.top, greaterThanOrEqualTo(40));
      expect(rect.bottom, lessThanOrEqualTo(280));
      expect(find.text('Download').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(result, 'Remove');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('outside tap dismisses without selecting in reduced motion', (
    tester,
  ) async {
    final results = <String?>[];
    await openMenu(
      tester,
      anchor: const Rect.fromLTWH(12, 40, 44, 44),
      reduceMotion: true,
      preferAbove: true,
      onResult: results.add,
    );
    expect(
      tester.getRect(find.byType(MornyeContextMenu)).top,
      greaterThanOrEqualTo(84),
    );
    await tester.tapAt(const Offset(8, 800));
    await tester.pump();
    expect(results, [null]);
    expect(find.byType(MornyeContextMenu), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
