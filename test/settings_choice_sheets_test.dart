import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/fixed_settings.dart';

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

const _settings = AppSettings(
  localLibraryEnabled: true,
  localLibraryAutoScan: 'daily',
  defaultLibraryView: 'albums',
  libraryQualityLabelMode: 'bit_depth',
  lyricsMode: 'both',
);

typedef _Sheet = (
  String Function(AppLocalizations l10n) row,
  List<String> values,
  List<IconData> icons,
  String Function(AppSettings settings) setting,
);

/// Each sheet's row title, values and icons in order, and its setting.
final List<_Sheet> _library = [
  (
    (l) => l.libraryAutoScan,
    ['off', 'on_open', 'daily', 'weekly'],
    [Icons.block, Icons.open_in_new, Icons.today, Icons.date_range],
    (s) => s.localLibraryAutoScan,
  ),
  (
    (l) => l.libraryDefaultView,
    ['last', 'all', 'albums', 'singles', 'artists', 'playlists'],
    [
      Icons.history,
      Icons.music_note,
      Icons.album,
      Icons.audiotrack,
      Icons.person,
      Icons.queue_music,
    ],
    (s) => s.defaultLibraryView,
  ),
  (
    (l) => l.trackAudioQuality,
    [
      'bitrate',
      'bit_depth_only',
      'bit_depth',
      'bit_depth_bitrate',
      'file_format',
    ],
    [
      Icons.speed_rounded,
      Icons.tune_rounded,
      Icons.graphic_eq_rounded,
      Icons.multiline_chart_rounded,
      Icons.audio_file_rounded,
    ],
    (s) => s.libraryQualityLabelMode,
  ),
];

final _Sheet _lyrics = (
  (l) => l.lyricsMode,
  ['embed', 'external', 'both'],
  [
    Icons.audiotrack,
    Icons.insert_drive_file_outlined,
    Icons.library_music_outlined,
  ],
  (s) => s.lyricsMode,
);

void main() {
  for (final mornye in [false, true]) {
    for (final (page, sheet) in [
      for (final sheet in _library) (const LibrarySettingsPage(), sheet),
      (const LyricsSettingsPage(), _lyrics),
    ]) {
      final (row, values, icons, setting) = sheet;
      final current = setting(_settings);
      testWidgets('${page.runtimeType} $current sheet (Mornye: $mornye)', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(
                () => FixedSettingsNotifier(_settings),
              ),
              localLibraryProvider.overrideWith(_Library.new),
              extensionProvider.overrideWith(_Extensions.new),
            ],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: page,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byWidget(page));
        final rowFinder = find.byWidgetPredicate(
          (w) => w is SettingsItem && w.title == row(context.l10n),
        );
        await tester.scrollUntilVisible(rowFinder, 200);
        await tester.pumpAndSettle();
        await tester.tap(rowFinder);
        await tester.pumpAndSettle();

        final shown = tester
            .widgetList<AppSheetOption>(find.byType(AppSheetOption))
            .toList();
        expect(
          [
            for (final o in shown)
              ((o.leading! as AppIcon).icon, o.selected, o.subtitle != null),
          ],
          [
            for (final (i, value) in values.indexed)
              (icons[i], value == current, page is LyricsSettingsPage),
          ],
        );

        final pick = values.last == current ? 0 : values.length - 1;
        await tester.tap(find.byWidget(shown[pick]));
        await tester.pumpAndSettle();
        expect(find.byType(AppSheetOption), findsNothing);
        final container = ProviderScope.containerOf(context);
        expect(setting(container.read(settingsProvider)), values[pick]);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
