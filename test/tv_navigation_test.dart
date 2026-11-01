import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/mornye_level_slider.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/tv_navigation.dart';
import 'package:mornye/widgets/tv_shell.dart';

class _Controller implements MusicPlayerController {
  final calls = <String>[];

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Controller controller;

  setUp(() {
    debugAndroidTvOverride = true;
    controller = _Controller();
  });
  tearDown(() => debugAndroidTvOverride = null);

  Future<void> pumpTv(
    WidgetTester tester,
    Widget child, {
    bool mornye = false,
    bool productionMetrics = false,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicPlayerControllerProvider.overrideWithValue(controller),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(PlaybackState()),
          ),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(navigationMode: NavigationMode.directional),
            child: productionMetrics
                ? AdaptiveUiScaler(
                    child: SafeArea(
                      minimum: const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 24,
                      ),
                      child: TvNavigation(child: child!),
                    ),
                  )
                : TvNavigation(child: child!),
          ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets('remote enters a touch tile, opens its menu and activates once', (
    tester,
  ) async {
    var taps = 0;
    var menus = 0;
    await pumpTv(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: TvTapTarget(
          onTap: () => taps++,
          onLongPress: () => menus++,
          child: const SizedBox(width: 160, height: 160, child: Text('Album')),
        ),
      ),
    );
    await key(tester, LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(taps, 1);
    await key(tester, LogicalKeyboardKey.contextMenu);
    expect(menus, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested button keeps its action instead of activating its tile', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var tileTaps = 0;
    var playTaps = 0;
    await pumpTv(
      tester,
      TvTapTarget(
        onTap: () => tileTaps++,
        child: IconButton(
          focusNode: focus,
          onPressed: () => playTaps++,
          icon: const Icon(Icons.play_arrow),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await key(tester, LogicalKeyboardKey.select);
    expect(playTaps, 1);
    expect(tileTaps, 0);
  });

  testWidgets('remote scrolls a lazy list beyond its initial viewport', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    int? selected;
    await pumpTv(
      tester,
      ListView.builder(
        controller: scroll,
        itemCount: 50,
        itemBuilder: (context, index) =>
            ListTile(title: Text('Song $index'), onTap: () => selected = index),
      ),
    );
    for (var i = 0; i < 24; i++) {
      await key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await key(tester, LogicalKeyboardKey.select);
    expect(selected, greaterThan(15));
    expect(scroll.offset, greaterThan(500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('media keys work without activating the selected control', (
    tester,
  ) async {
    var activated = 0;
    await pumpTv(
      tester,
      TextButton(onPressed: () => activated++, child: const Text('Settings')),
    );
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.mediaPlayPause);
    await key(tester, LogicalKeyboardKey.mediaTrackNext);
    await key(tester, LogicalKeyboardKey.mediaTrackPrevious);
    expect(controller.calls, ['play', 'next', 'previous']);
    expect(activated, 0);
  });

  testWidgets('Back closes a dialog and restores remote activation', (
    tester,
  ) async {
    await pumpTv(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Options'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    );
    await key(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Options'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Options'), findsNothing);
    await key(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Options'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets('TV shell keeps destinations reachable, Mornye: $mornye', (
      tester,
    ) async {
      int? selected;
      await pumpTv(
        tester,
        TvShell(
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(
              icon: Icon(Icons.library_music),
              label: 'Library',
            ),
            NavigationDestination(icon: Icon(Icons.extension), label: 'Repo'),
            NavigationDestination(
              icon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
          selectedIndex: 0,
          onSelected: (value) => selected = value,
          child: const Center(child: Text('Content')),
        ),
        mornye: mornye,
        productionMetrics: true,
      );
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(selected, 1);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'shared cards, settings and actions accept OK, Mornye: $mornye',
      (tester) async {
        final calls = <String>[];
        await pumpTv(
          tester,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppContentCard(
                onTap: () => calls.add('song'),
                child: const SizedBox(height: 64, child: Text('Song')),
              ),
              SettingsItem(
                title: 'Library',
                onTap: () => calls.add('settings'),
              ),
              ExpressiveButton(
                onPressed: () => calls.add('action'),
                child: const Text('Open'),
              ),
            ],
          ),
          mornye: mornye,
        );
        for (var i = 0; i < 3; i++) {
          if (i != 0) await key(tester, LogicalKeyboardKey.arrowDown);
          await key(tester, LogicalKeyboardKey.select);
        }
        expect(calls, ['song', 'settings', 'action']);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('seek can be adjusted and left with Down, Mornye: $mornye', (
      tester,
    ) async {
      Duration? seek;
      var below = 0;
      await pumpTv(
        tester,
        Column(
          children: [
            PlaybackSeekSlider(
              position: const Duration(seconds: 10),
              duration: const Duration(minutes: 3),
              onSeek: (value) async => seek = value,
            ),
            TextButton(onPressed: () => below++, child: const Text('Next')),
          ],
        ),
        mornye: mornye,
      );
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(seek, greaterThan(const Duration(seconds: 10)));
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(below, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye level slider adjusts by remote and releases focus', (
    tester,
  ) async {
    var value = 0.5;
    var below = 0;
    await pumpTv(
      tester,
      Column(
        children: [
          MornyeLevelSlider(value: value, onChanged: (next) => value = next),
          TextButton(onPressed: () => below++, child: const Text('Next')),
        ],
      ),
      mornye: true,
    );
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(value, 0.51);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(below, 1);
  });
}
