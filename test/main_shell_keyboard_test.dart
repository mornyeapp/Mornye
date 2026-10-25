import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/tv_navigation.dart';
import 'package:mornye/widgets/tv_shell.dart';
import 'package:mornye/widgets/mornye_bottom_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final languageTags = <Object?>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    languageTags.clear();
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'setMetadataLanguage') {
        languageTags.add((call.arguments as Map)['tag']);
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(backend, null));

  Future<ValueNotifier<Locale>> pumpShell(
    WidgetTester tester, {
    bool tv = false,
    bool mornye = true,
  }) async {
    debugAndroidTvOverride = tv;
    addTearDown(() => debugAndroidTvOverride = null);
    tester.view.physicalSize = tv ? const Size(960, 540) : const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final locale = ValueNotifier(const Locale('en'));
    addTearDown(locale.dispose);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const MainShell())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
        ],
        child: ValueListenableBuilder(
          valueListenable: locale,
          builder: (context, value, _) => MaterialApp.router(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.dark(),
            builder: tv
                ? (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(navigationMode: NavigationMode.directional),
                    child: AdaptiveUiScaler(
                      child: SafeArea(
                        minimum: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 24,
                        ),
                        child: TvNavigation(child: child!),
                      ),
                    ),
                  )
                : null,
            locale: value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    return locale;
  }

  bool collapsed(WidgetTester tester) =>
      tester.widget<MornyeBottomBar>(find.byType(MornyeBottomBar)).collapsed;

  void scrollHome(WidgetTester tester, {required double pixels}) {
    ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 2000,
        pixels: pixels,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: tester.element(find.byType(HomeTab).first),
      scrollDelta: 40,
      dragDetails: DragUpdateDetails(globalPosition: Offset.zero),
    ).dispatch(tester.element(find.byType(HomeTab).first));
  }

  testWidgets('keyboard frames do not re-run the shell side effects', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(languageTags, ['en']);
    // A back press at a tab root checks the keyboard too.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Press back again to exit'), findsOneWidget);
    final homeTab = find.byKey(const ValueKey('tab-home')).first;
    final tabs = tester.widget(homeTab);

    for (final inset in [80.0, 160.0, 240.0, 300.0, 150.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(languageTags, ['en']);
    // The shell did not rebuild its tab navigators.
    expect(tester.widget(homeTab), same(tabs));
    // Lets the back press snack bar time out.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locale change still re-runs the shell side effects', (
    tester,
  ) async {
    final locale = await pumpShell(tester);
    locale.value = const Locale('id');
    await tester.pump();
    await tester.pump();

    expect(languageTags, ['en', 'id']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tab bar stays expanded while the keyboard is up', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(collapsed(tester), isFalse);

    scrollHome(tester, pixels: 400);
    await tester.pump();
    expect(collapsed(tester), isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(collapsed(tester), isFalse);

    // Scrolling back to the top with the keyboard up does not reach the bar.
    scrollHome(tester, pixels: 0);
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(collapsed(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'TV remote opens Settings and Back returns Home, Mornye: $mornye',
      (tester) async {
        await pumpShell(tester, tv: true, mornye: mornye);
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(MornyeBottomBar), findsNothing);
        final tvShell = tester.widget<TvShell>(find.byType(TvShell));
        for (var i = 1; i < tvShell.destinations.length; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<TvShell>(find.byType(TvShell)).selectedIndex,
          tvShell.destinations.length - 1,
        );
        final back = tester.binding.handlePopRoute();
        await tester.pump();
        await back;
        await tester.pump();
        expect(tester.widget<TvShell>(find.byType(TvShell)).selectedIndex, 0);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(searchProvider: 'example', hasSearchedBefore: true);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}
