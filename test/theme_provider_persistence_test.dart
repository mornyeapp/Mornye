import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a stored red moves to blue once, and red picked later stays', () async {
    SharedPreferences.setMockInitialValues({kMornyeAccentKey: 'red'});
    final prefs = await SharedPreferences.getInstance();
    expect(loadBootstrapThemeSettings(prefs).mornyeAccent, MornyeAccent.blue);
    expect(prefs.getString(kMornyeAccentKey), 'blue');

    await prefs.setString(kMornyeAccentKey, 'red');
    expect(loadBootstrapThemeSettings(prefs).mornyeAccent, MornyeAccent.red);
    expect(prefs.getString(kMornyeAccentKey), 'red');
  });

  test('the move leaves any other accent alone', () async {
    SharedPreferences.setMockInitialValues({kMornyeAccentKey: 'pink'});
    final prefs = await SharedPreferences.getInstance();
    expect(loadBootstrapThemeSettings(prefs).mornyeAccent, MornyeAccent.pink);
    expect(prefs.getString(kMornyeAccentKey), 'pink');
    expect(prefs.getBool(kMornyeAccentMovedToBlueKey), isTrue);
  });

  test(
    'early theme edits preserve untouched saved settings and await saving',
    () async {
      SharedPreferences.setMockInitialValues({
        kThemeModeKey: 'dark',
        kThemeStyleKey: 'mornye',
        kSeedColorKey: 0xff123456,
        kUseDynamicColorKey: false,
        kUseAmoledKey: true,
        kUseSystemFontKey: true,
        kMornyeAccentKey: 'blue',
        kMornyeGlassClarityKey: 0.2,
      });
      final prefs = await SharedPreferences.getInstance();
      final releaseLoad = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          themeProvider.overrideWith(
            () => ThemeNotifier(preferences: releaseLoad.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(themeProvider.notifier);
      // An explicit edit equal to the bootstrap default still owns this field.
      final savingMode = notifier.setThemeMode(ThemeMode.system);
      final savingAccent = notifier.setMornyeAccent(MornyeAccent.red);
      await notifier.setMornyeGlassClarity(0.8, persist: false);
      var saved = false;
      unawaited(savingAccent.then((_) => saved = true));
      await Future<void>.delayed(Duration.zero);
      expect(saved, isFalse);
      expect(container.read(themeProvider).mornyeGlassClarity, 0.8);
      expect(prefs.getString(kThemeModeKey), 'dark');

      releaseLoad.complete(prefs);
      await Future.wait([savingMode, savingAccent]);
      final state = container.read(themeProvider);
      expect(state.themeMode, ThemeMode.system);
      expect(state.mornyeAccent, MornyeAccent.red);
      expect(state.mornyeGlassClarity, 0.8);
      expect(state.style, AppThemeStyle.mornye);
      expect(state.seedColorValue, 0xff123456);
      expect(state.useDynamicColor, isFalse);
      expect(state.useAmoled, isTrue);
      expect(state.useSystemFont, isTrue);
      expect(loadBootstrapThemeSettings(prefs), state);
    },
  );

  test('early preview remains immediate without writing preferences', () async {
    SharedPreferences.setMockInitialValues({
      kMornyeGlassClarityKey: 0.2,
      kMornyeAccentKey: 'blue',
    });
    final prefs = await SharedPreferences.getInstance();
    final releaseLoad = Completer<SharedPreferences>();
    final loaded = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        themeProvider.overrideWith(
          () => ThemeNotifier(preferences: releaseLoad.future),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(themeProvider, (_, next) {
      if (next.mornyeAccent == MornyeAccent.blue) loaded.complete();
    });
    await container
        .read(themeProvider.notifier)
        .setMornyeGlassClarity(0.8, persist: false);
    expect(container.read(themeProvider).mornyeGlassClarity, 0.8);
    releaseLoad.complete(prefs);
    await loaded.future;
    expect(container.read(themeProvider).mornyeGlassClarity, 0.8);
    expect(prefs.getDouble(kMornyeGlassClarityKey), 0.2);
  });

  test(
    'failed preference loading keeps early edits without leaking errors',
    () async {
      final releaseLoad = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          themeProvider.overrideWith(
            () => ThemeNotifier(preferences: releaseLoad.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      final saving = container.read(themeProvider.notifier).setUseAmoled(true);
      releaseLoad.completeError(StateError('theme_load_failed'));
      await saving;
      expect(container.read(themeProvider).useAmoled, isTrue);
    },
  );

  test(
    'disposed theme does not read state or save after delayed loading',
    () async {
      SharedPreferences.setMockInitialValues({kUseAmoledKey: false});
      final prefs = await SharedPreferences.getInstance();
      final releaseLoad = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          themeProvider.overrideWith(
            () => ThemeNotifier(preferences: releaseLoad.future),
          ),
        ],
      );
      final saving = container.read(themeProvider.notifier).setUseAmoled(true);
      container.dispose();
      releaseLoad.complete(prefs);
      await saving;
      expect(prefs.getBool(kUseAmoledKey), isFalse);
    },
  );
}
