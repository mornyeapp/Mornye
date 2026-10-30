import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/app.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/desktop_player_bar.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';

import 'support/fixed_settings.dart';

class _Player implements MusicPlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlayerUi extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool enabled) => state = enabled;
}

final _playerUi = NotifierProvider<_PlayerUi, bool>(_PlayerUi.new);

const _window = MethodChannel('com.zarz.mornye/window');

final _macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

/// Every label in a `Menu.setMenus` payload, in menu order.
List<String> _labels(MethodCall call) {
  final labels = <String>[];
  void visit(Object? node) {
    if (node is List) {
      node.forEach(visit);
    } else if (node is Map) {
      if (node['label'] case final String label) labels.add(label);
      visit(node['children']);
    }
  }

  visit((call.arguments as Map)['0']);
  return labels;
}

int _idOf(MethodCall call, String label) {
  int? found;
  void visit(Object? node) {
    if (node is List) {
      node.forEach(visit);
    } else if (node is Map) {
      if (node['label'] == label) found = node['id'] as int;
      visit(node['children']);
    }
  }

  visit((call.arguments as Map)['0']);
  return found!;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final en = lookupAppLocalizations(const Locale('en'));
  final id = lookupAppLocalizations(const Locale('id'));
  late List<MethodCall> sent;

  setUp(() {
    debugDesktopPlatformOverride = true;
    debugDesktopTitleBarInContentOverride = false;
    desktopWindowMode.value = DesktopWindowMode.windowed;
    desktopWindowFullScreen.value = false;
    desktopMiniPlayerOpen.value = false;
    sent = [];
    messenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
      if (call.method == 'Menu.setMenus') sent.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(_window, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.menu, null);
    messenger.setMockMethodCallHandler(_window, null);
    desktopWindowMode.value = DesktopWindowMode.windowed;
    desktopWindowFullScreen.value = false;
    desktopMiniPlayerOpen.value = false;
    debugDesktopPlatformOverride = null;
    debugDesktopTitleBarInContentOverride = null;
  });

  final overrides = [
    settingsProvider.overrideWith(FixedSettingsNotifier.new),
    playerUiEnabledProvider.overrideWith((ref) => ref.watch(_playerUi)),
    musicPlayerControllerProvider.overrideWithValue(_Player()),
    playbackStateProvider.overrideWith((_) => Stream.value(PlaybackState())),
    systemVolumeProvider.overrideWith((_) => Stream.value(0.5)),
  ];

  Widget app({ThemeMode themeMode = ThemeMode.light, Locale? locale}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          navigatorKey: AppNavigationService.rootNavigatorKey,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeMode,
          themeAnimationDuration: const Duration(milliseconds: 300),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              buildAppContent(context, child, heroAnimationsEnabled: true),
          home: const Scaffold(body: Text('content')),
        ),
      );

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  /// Ten frames of a live resize, then ten of the mini player shrinking the
  /// window.
  Future<void> resize(WidgetTester tester) async {
    for (var step = 1; step <= 10; step++) {
      tester.view.physicalSize = Size(1200 - step * 30, 800 - step * 10);
      await tester.pump();
    }
    desktopMiniPlayerOpen.value = true;
    for (var step = 1; step <= 10; step++) {
      tester.view.physicalSize = Size(900 - step * 50, 700 - step * 50);
      await tester.pump();
    }
  }

  Shortcuts shortcutLayer(WidgetTester tester) => tester.widget<Shortcuts>(
    find
        .descendant(
          of: find.byType(DesktopShortcuts),
          matching: find.byType(Shortcuts),
        )
        .first,
  );

  List<PlatformMenuItem> menuItems(WidgetTester tester) =>
      tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar)).menus;

  Future<void> select(WidgetTester tester, String label) async {
    await messenger.handlePlatformMessage(
      SystemChannels.menu.name,
      SystemChannels.menu.codec.encodeMethodCall(
        MethodCall('Menu.selectedCallback', _idOf(sent.last, label)),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('window resizes and the mini player keep the macOS menu bar', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(sent, isNotEmpty);
    final mounted = sent.length;
    // Escape reads the window width to decide whether a layer can close.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    final layer = shortcutLayer(tester);

    await resize(tester);

    expect(sent, hasLength(mounted));
    expect(shortcutLayer(tester), same(layer));
    expect(tester.takeException(), isNull);
  }, variant: _macOS);

  testWidgets('a theme change keeps the menu items and key bindings', (
    tester,
  ) async {
    await pumpApp(tester);
    final items = menuItems(tester);
    final bindings = shortcutLayer(tester).shortcuts;
    final mounted = sent.length;

    await tester.pumpWidget(app(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    // PlatformMenuBar sends once more on its first update after mounting,
    // even when nothing changed, because it never records what it mounted.
    expect(sent.length, lessThanOrEqualTo(mounted + 1));
    final afterFirst = sent.length;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(sent, hasLength(afterFirst));
    expect(menuItems(tester), same(items));
    expect(shortcutLayer(tester).shortcuts, same(bindings));
  }, variant: _macOS);

  testWidgets(
    'locale, window mode and player changes resend the menu bar once',
    (tester) async {
      final requested = <ShellTab>[];
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: requested.add,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await pumpApp(tester);
      expect(
        _labels(sent.last),
        containsAll([
          en.desktopMenuFile,
          en.desktopWindowBorderless,
          en.desktopMenuControls,
        ]),
      );

      var before = sent.length;
      await tester.pumpWidget(app(locale: const Locale('id')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(before + 1));
      expect(_labels(sent.last), contains(id.desktopMenuFile));
      expect(_labels(sent.last), isNot(contains(en.desktopMenuFile)));

      before = sent.length;
      desktopWindowMode.value = DesktopWindowMode.borderless;
      await tester.pump();
      expect(sent, hasLength(before + 1));
      expect(_labels(sent.last), contains(id.desktopWindowed));
      expect(_labels(sent.last), isNot(contains(id.desktopWindowBorderless)));

      before = sent.length;
      ProviderScope.containerOf(
        tester.element(find.byType(DesktopShortcuts)),
      ).read(_playerUi.notifier).set(false);
      await tester.pump();
      expect(sent, hasLength(before + 1));
      expect(_labels(sent.last), isNot(contains(id.desktopMenuControls)));
      expect(_labels(sent.last), isNot(contains(id.nowPlayingTabLyrics)));

      await resize(tester);
      await select(tester, id.desktopMenuSettings);
      expect(requested, [ShellTab.settings]);
      expect(tester.takeException(), isNull);
    },
    variant: _macOS,
  );

  testWidgets('resizes reuse the app fade and still fade at the rail', (
    tester,
  ) async {
    await pumpApp(tester);
    Animation<double> fade() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(AppScaffoldMessenger),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity;
    final opacity = fade();

    await resize(tester);
    expect(fade(), same(opacity));

    tester.view.physicalSize = const Size(1500, 800);
    await tester.pump();
    expect(fade(), same(opacity));
    expect(opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(opacity.value, 1);
  });

  testWidgets(
    'Windows and Linux keep their key bindings across resizes',
    (tester) async {
      final requested = <ShellTab>[];
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: requested.add,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await pumpApp(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      final layer = shortcutLayer(tester);

      await resize(tester);

      expect(shortcutLayer(tester), same(layer));
      expect(find.byType(PlatformMenuBar), findsNothing);
      expect(sent, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();
      expect(requested, [ShellTab.settings]);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
