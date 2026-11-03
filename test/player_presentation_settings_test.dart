import 'dart:convert';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('cover style and music haptics keep their defaults', () {
    final restored = AppSettings.fromJson(const {});
    // Unchosen, Material shows the cover full screen and Mornye a card.
    expect(restored.playerCoverStyle, isEmpty);
    expect(restored.playerCoverStyleFor(mornye: false), 'fullscreen');
    expect(restored.playerCoverStyleFor(mornye: true), 'default');
    // A choice holds in both styles.
    final card = restored.copyWith(playerCoverStyle: 'default');
    expect(card.playerCoverStyleFor(mornye: false), 'default');
    final full = restored.copyWith(playerCoverStyle: 'fullscreen');
    expect(full.playerCoverStyleFor(mornye: true), 'fullscreen');
    expect(restored.musicHaptics, isFalse);
    expect(restored.landscapeLyricsArtwork, isFalse);
    expect(restored.autoHideLyricsControls, isTrue);
  });

  test('cover style and music haptics survive a round trip', () {
    final settings = const AppSettings().copyWith(
      playerCoverStyle: 'default',
      musicHaptics: true,
      landscapeLyricsArtwork: true,
      autoHideLyricsControls: false,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.playerCoverStyle, 'default');
    expect(restored.musicHaptics, isTrue);
    expect(restored.landscapeLyricsArtwork, isTrue);
    expect(restored.autoHideLyricsControls, isFalse);
    expect(
      restored.copyWith(autoHideLyricsControls: true).autoHideLyricsControls,
      isTrue,
    );
    expect(
      restored.copyWith(landscapeLyricsArtwork: false).landscapeLyricsArtwork,
      isFalse,
    );
  });

  test('invalid cover styles preserve the rest of the saved settings', () {
    for (final value in [null, '', 'unknown', 42, <String, String>{}]) {
      final restored = AppSettings.fromJson({
        'playerCoverStyle': value,
        'musicHaptics': true,
      });
      expect(restored.playerCoverStyle, isEmpty);
      expect(restored.musicHaptics, isTrue);
    }
  });

  testWidgets('landscape artwork is selectable, saved and searchable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(const AppSettings()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PlaybackSettingsPage(),
        ),
      ),
    );
    final option = find.text('Album art beside lyrics');
    await tester.scrollUntilVisible(
      option,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).landscapeLyricsArtwork, isTrue);
    final prefs = await SharedPreferences.getInstance();
    final restored = AppSettings.fromJson(
      jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
    );
    expect(restored.landscapeLyricsArtwork, isTrue);
    final l10n = AppLocalizations.of(tester.element(option));
    expect(
      SettingsSearchCatalog(l10n).playback.where(
        (entry) =>
            entry.title == l10n.landscapeLyricsArtwork &&
            entry.matches(SettingsSearchQuery('landscape lyrics')),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'automatic fullscreen lyrics is saved and searchable (Mornye: $mornye)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        debugDesktopPlatformOverride = false;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            initialSettingsProvider.overrideWithValue(const AppSettings()),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const PlaybackSettingsPage(),
            ),
          ),
        );
        final option = find.byKey(const ValueKey('auto-hide-lyrics-controls'));
        await tester.scrollUntilVisible(
          option,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).autoHideLyricsControls, isTrue);
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).autoHideLyricsControls,
          isFalse,
        );
        final prefs = await SharedPreferences.getInstance();
        final restored = AppSettings.fromJson(
          jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
        );
        expect(restored.autoHideLyricsControls, isFalse);
        final l10n = AppLocalizations.of(tester.element(option));
        expect(
          SettingsSearchCatalog(l10n).playback.where(
            (entry) =>
                entry.title == l10n.autoHideLyricsControls &&
                entry.matches(SettingsSearchQuery('fullscreen lyrics')),
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('full-screen Material cover keeps the entire app bar readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.reset);
    const key = ValueKey('backdrop');
    final colors = ColorScheme.fromSeed(
      seedColor: Colors.blue,
    ).copyWith(surface: Colors.white, surfaceContainerHighest: Colors.white);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: MaterialPlayerBackdrop(
            mediaItem: const MediaItem(id: 'bright-cover', title: 'Track'),
            colorScheme: colors,
            showArtwork: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        double luminanceAt(int y) {
          final offset = (y * image.width + 20) * 4;
          return Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          ).computeLuminance();
        }

        // The shade is darkest under the status bar, eases out across the
        // app bar, stays light enough not to hide the cover, and is gone
        // below the bar (24 inset + 56 toolbar + 32 fade).
        final top = luminanceAt(2);
        final bar = luminanceAt(52);
        final below = luminanceAt(130);
        expect(top, lessThan(bar));
        expect(bar, lessThan(below));
        expect(top, greaterThan(below * 0.5));
        expect(below, closeTo(luminanceAt(200), 0.01));
      } finally {
        image.dispose();
      }
    });
  });
}
