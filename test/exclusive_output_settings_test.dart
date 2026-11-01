import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/preview_button.dart';
import 'package:mornye/widgets/settings_group.dart';

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required bool mornye,
  AppSettings settings = const AppSettings(autoMix: true),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(settings)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: mornye
            ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
            : AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const PlaybackSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

SettingsSwitchItem _switch(WidgetTester tester, String title) =>
    tester.widget<SettingsSwitchItem>(
      find.byWidgetPredicate(
        (widget) => widget is SettingsSwitchItem && widget.title == title,
      ),
    );

Future<void> _scrollTo(WidgetTester tester, Finder finder, double delta) async {
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => debugDesktopPlatformOverride = true);
  tearDown(() {
    debugDesktopPlatformOverride = null;
    playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'Windows offers WASAPI exclusive mode ($mornye)',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final container = await _pumpPage(tester, mornye: mornye);
        expect(_switch(tester, 'AutoMix').enabled, isTrue);
        const title = 'WASAPI exclusive mode';
        await _scrollTo(tester, find.text(title), 300);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).exclusiveOutput, isTrue);
        expect(
          find.textContaining('Takes the device when a track plays.'),
          findsOneWidget,
        );
        expect(find.text('Output device'), findsNothing);

        playbackExclusiveStatus.value = ExclusiveOutputStatus.unavailable;
        await tester.pump();
        expect(
          find.textContaining('The device refused exclusive access'),
          findsOneWidget,
        );

        // AutoMix needs a second deck, which the held device refuses.
        await _scrollTo(tester, find.text('AutoMix'), -300);
        expect(_switch(tester, 'AutoMix').enabled, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'macOS offers hog mode with its status',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pumpPage(
        tester,
        mornye: true,
        settings: const AppSettings(exclusiveOutput: true),
      );
      const title = 'Exclusive access (hog mode)';
      await _scrollTo(tester, find.text(title), 300);
      expect(find.textContaining('Core Audio does not resample'), findsOne);

      playbackExclusiveStatus.value = ExclusiveOutputStatus.active;
      await tester.pump();
      expect(find.textContaining('Playing in exclusive mode.'), findsOne);

      playbackExclusiveStatus.value = ExclusiveOutputStatus.unavailable;
      await tester.pump();
      expect(find.textContaining('Another app holds the output'), findsOne);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Linux offers direct ALSA output with a device choice',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final container = await _pumpPage(tester, mornye: false);
      const title = 'Direct ALSA output';
      await _scrollTo(tester, find.text(title), 300);
      expect(find.text('Output device'), findsNothing);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).exclusiveOutput, isTrue);
      expect(find.text('Output device'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the option is desktop only', (tester) async {
    debugDesktopPlatformOverride = false;
    await _pumpPage(tester, mornye: false);
    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('WASAPI exclusive mode'), findsNothing);
    }
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    bool listed() => SettingsSearchCatalog(
      l10n,
    ).playback.any((entry) => entry.title == l10n.exclusiveOutputWindows);
    expect(listed(), isFalse);
    debugDesktopPlatformOverride = true;
    expect(listed(), isTrue);
  });

  testWidgets('exclusive mode hides track previews', (tester) async {
    const track = Track(
      id: 'track-1',
      name: 'Track',
      artistName: 'Artist',
      albumName: 'Album',
      previewUrl: 'https://example.com/preview.mp3',
      duration: 180,
    );
    Future<void> pump(bool exclusive) async {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(exclusive),
          overrides: [
            initialSettingsProvider.overrideWithValue(
              AppSettings(exclusiveOutput: exclusive),
            ),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream<MediaItem?>.value(null),
            ),
            playbackPlayingProvider.overrideWith((ref) => false),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: PreviewButton(track: track)),
          ),
        ),
      );
      await tester.pump();
    }

    await pump(false);
    expect(find.byTooltip('Play preview'), findsOneWidget);
    await pump(true);
    expect(find.byTooltip('Play preview'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
