import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/tooltip_finder.dart';

class _Server extends NetworkStorageService {
  _Server() : super(read: () async => null, write: (_) async {});
  NetworkConnection? attempted;
  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection connection, [
    String path = '',
  ]) async {
    attempted = connection;
    return path.isEmpty
        ? const [NetworkEntry('subsonic/artists/', 'Artists', directory: true)]
        : [
            SubsonicSong({
              'id': 'a',
              'title': 'Song title',
              'artist': 'Song artist',
              'album': 'Album',
              'suffix': 'flac',
            }).entry,
          ];
  }
}

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final mornye in [false, true]) {
      for (final largeText in [false, true]) {
        final mobile =
            platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        testWidgets(
          'Subsonic form and browsing on $platform Mornye=$mornye largeText=$largeText',
          (tester) async {
            tester.view.physicalSize = mobile
                ? const Size(360, 800)
                : const Size(1200, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final service = _Server();
            debugDesktopPlatformOverride = !mobile;
            addTearDown(() => debugDesktopPlatformOverride = null);
            addTearDown(service.dispose);
            final theme =
                (mornye
                        ? MornyeTheme.build(Brightness.dark)
                        : ThemeData.dark(useMaterial3: true))
                    .copyWith(platform: platform);
            await tester.pumpWidget(
              ProviderScope(
                child: MaterialApp(
                  theme: theme,
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(largeText ? 1.5 : 1),
                    ),
                    child: child!,
                  ),
                  home: NetworkStorageScreen(service: service),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(findByTooltip('Add connection'));
            await tester.pumpAndSettle();
            await tester.tap(
              find.widgetWithText(SettingsChoiceChip, 'Subsonic'),
            );
            await tester.pumpAndSettle();
            Future<void> field(String label, String value) async {
              final finder = find.byKey(ValueKey(label));
              await tester.ensureVisible(finder);
              await tester.pumpAndSettle();
              await tester.enterText(
                find.descendant(
                  of: finder,
                  matching: find.byType(EditableText),
                ),
                value,
              );
            }

            await field('Name', 'Personal music');
            await field('Server or audio URL', 'https://example.test/music/');
            final apiKey = find.widgetWithText(SettingsChoiceChip, 'API key');
            await tester.ensureVisible(apiKey);
            await tester.pumpAndSettle();
            await tester.tap(apiKey);
            await tester.pumpAndSettle();
            expect(find.byKey(const ValueKey('Username')), findsNothing);
            await field('API key', 'test-secret');
            final save = find.widgetWithText(
              AppActionButton,
              'Connect and save',
            );
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            await tester.tap(save);
            await tester.pumpAndSettle();
            expect(service.attempted!.subsonicAuth, SubsonicAuth.apiKey);
            expect(service.attempted!.apiKey, 'test-secret');
            expect(service.attempted!.username, isEmpty);
            expect(service.attempted!.password, isEmpty);
            expect((await service.connections()).single.name, 'Personal music');
            await tester.scrollUntilVisible(
              find.text('Personal music'),
              200,
              scrollable: find.byType(Scrollable).last,
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Personal music'));
            await tester.pumpAndSettle();
            expect(find.text('Add server to Library'), findsOneWidget);
            expect(find.text('Download to this folder'), findsNothing);
            expect(find.text('Search server music...'), findsOneWidget);
            final artists = find.widgetWithText(SettingsItem, 'Artists');
            await tester.ensureVisible(artists);
            await tester.pumpAndSettle();
            await tester.tap(artists);
            await tester.pumpAndSettle();
            expect(find.text('Song title'), findsOneWidget);
            expect(find.text('Song artist · FLAC'), findsOneWidget);
            expect(find.text('Add folder to Library'), findsNothing);
            expect(find.textContaining('subsonic/'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
