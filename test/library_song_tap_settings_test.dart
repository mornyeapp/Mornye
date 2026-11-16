import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/song_row_tap.dart';

const _title = 'Tapping a song';
const _playDescription =
    'A tap plays the song. The button beside it opens its details.';
const _detailsDescription =
    "A tap opens the song's details. The play button plays it.";

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  bool mornye = false,
  AppSettings settings = const AppSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  // A phone width, so both choices must share one row.
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      initialSettingsProvider.overrideWithValue(settings),
      localLibraryProvider.overrideWith(_Library.new),
      extensionProvider.overrideWith(_Extensions.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LibrarySettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text(_title),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  return container;
}

/// The connected button group lays a label out more than once; any copy
/// sits on the same segment.
Finder _option(String label) => find.text(label).first;

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final mornye in [false, true]) {
    testWidgets('a two-way choice that opens details by default ($mornye)', (
      tester,
    ) async {
      final container = await _pumpPage(tester, mornye: mornye);
      expect(
        mornye
            ? find.byType(MornyeSegmentedControl)
            : find.byType(SettingsSegmentedChoice<String>),
        findsOneWidget,
      );
      expect(find.text(_detailsDescription), findsOneWidget);
      // The default comes first.
      expect(
        tester.getTopLeft(_option('Open details')).dx,
        lessThan(tester.getTopLeft(_option('Play song')).dx),
      );

      await tester.tap(_option('Play song'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).librarySongTap,
        AppSettings.librarySongTapPlay,
      );
      expect(find.text(_playDescription), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('app_settings')!) as Map;
      expect(saved['librarySongTap'], AppSettings.librarySongTapPlay);

      await tester.tap(_option('Open details'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).librarySongTap,
        AppSettings.librarySongTapDetails,
      );
      expect(find.text(_detailsDescription), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop shows the choice too', (tester) async {
    debugDesktopPlatformOverride = true;
    await _pumpPage(tester);
    expect(find.text(_title), findsOneWidget);
  });

  for (final (name, backup, expected) in [
    (
      'a new backup',
      const AppSettings(
        librarySongTap: AppSettings.librarySongTapPlay,
      ).toJson(),
      AppSettings.librarySongTapPlay,
    ),
    (
      'a backup from before the choice',
      <String, dynamic>{'swipeToQueue': false},
      AppSettings.librarySongTapDetails,
    ),
  ]) {
    testWidgets('restoring $name keeps the choice', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
        ],
      );
      addTearDown(container.dispose);
      // A backup archive stores the settings as JSON text.
      final json = jsonDecode(jsonEncode(backup)) as Map<String, dynamic>;
      await tester.runAsync(
        () => container.read(settingsProvider.notifier).restoreFromBackup(json),
      );
      expect(container.read(settingsProvider).librarySongTap, expected);
    });
  }

  testWidgets('an unknown value opens details on a tap', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          AppSettings.fromJson(const {'librarySongTap': 'other'}),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(librarySongTapPlaysProvider), isFalse);
    container
        .read(settingsProvider.notifier)
        .setLibrarySongTap(AppSettings.librarySongTapPlay);
    expect(container.read(librarySongTapPlaysProvider), isTrue);
    container.read(settingsProvider.notifier).setLibrarySongTap('other');
    expect(
      container.read(settingsProvider).librarySongTap,
      AppSettings.librarySongTapDetails,
    );
  });

  for (final desktop in [false, true]) {
    testWidgets('settings search finds it (desktop: $desktop)', (tester) async {
      debugDesktopPlatformOverride = desktop;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(),
        ),
      );
      final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      expect([
        for (final entry in SettingsSearchCatalog(l10n).library) entry.title,
      ], contains(_title));
    });
  }

  testWidgets('a CUE virtual track opens its details on a tap and keeps its '
      'play button', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final log = <String>[];
    Widget row(String name, String path) => Consumer(
      builder: (context, ref, _) => Row(
        children: [
          TextButton(
            onPressed: songRowTap(
              ref,
              path: path,
              openDetails: () => log.add('details $name'),
              play: () => log.add('play $name'),
            ),
            child: Text('row $name'),
          ),
          SongRowButton(
            path: path,
            playButton: Text('play button $name'),
            onOpenDetails: () {},
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(librarySongTap: AppSettings.librarySongTapPlay),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                row('song', '/music/song.flac'),
                row('cue', '/music/album.cue#track02'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('row song'));
    await tester.tap(find.text('row cue'));
    expect(log, ['play song', 'details cue']);
    // The song's button opens the details; the CUE track's still plays.
    expect(find.text('play button song'), findsNothing);
    expect(find.text('play button cue'), findsOneWidget);
  });
}
