import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';

class _Storage extends NetworkStorageService {
  _Storage(this._events, this._fail);
  final List<String> _events;
  final bool _fail;
  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async => [];
  @override
  Future<void> checkUploadAccess(String folder) async {
    _events.add('check:$folder');
    if (_fail) throw StateError('Permission denied');
  }
}

class _Settings extends SettingsNotifier {
  _Settings(this._events);
  final List<String> _events;
  @override
  AppSettings build() => const AppSettings();
  @override
  Future<void> setNetworkDownloadFolder(String source, String label) async {
    _events.add('save:$source');
    state = state.copyWith(
      networkDownloadFolder: source,
      networkDownloadLabel: label,
    );
  }
}

void main() {
  test(
    'network destination survives queue restart and later settings changes',
    () {
      final settings = AppSettings.fromJson(
        const AppSettings(
          networkDownloadFolder: 'network://nas/Music/',
          networkDownloadLabel: 'NAS / Music',
        ).toJson(),
      );
      final item = DownloadItem(
        id: 'item',
        track: Track(
          id: 'track',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 60,
        ),
        service: 'provider',
        createdAt: DateTime.utc(2026),
        status: DownloadStatus.finalizing,
        networkDownloadFolder: settings.networkDownloadFolder,
      );
      final restored = DownloadItem.fromJson(
        jsonDecode(encodeDownloadQueueItemForPersistence(item))
            as Map<String, dynamic>,
      );
      expect(restored.status, DownloadStatus.queued);
      expect(
        restored.copyWith(status: DownloadStatus.failed).networkDownloadFolder,
        'network://nas/Music/',
      );
      expect(
        settings.copyWith(networkDownloadFolder: '').networkDownloadFolder,
        '',
      );
      expect(restored.networkDownloadFolder, 'network://nas/Music/');
      final legacy = (jsonDecode(jsonEncode(item)) as Map<String, dynamic>)
        ..remove('networkDownloadFolder');
      expect(DownloadItem.fromJson(legacy).networkDownloadFolder, '');
    },
  );
  for (final mornye in [false, true]) {
    for (final fail in [false, true]) {
      testWidgets(
        'download folder checks write access before saving ($mornye, $fail)',
        (tester) async {
          final events = <String>[];
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(() => _Settings(events)),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: NetworkStorageScreen(
                  service: _Storage(events, fail),
                  path: 'Albums/',
                  connection: const NetworkConnection(
                    id: 'nas',
                    name: 'NAS',
                    protocol: NetworkProtocol.smb,
                    address: 'smb://nas/Music/',
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final button = find.widgetWithText(
            AppActionButton,
            'Download to this folder',
          );
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(events, [
            'check:network://nas/Albums/',
            if (!fail) 'save:network://nas/Albums/',
          ]);
          expect(
            find.text('Selected download destination'),
            fail ? findsNothing : findsOneWidget,
          );
          if (fail) {
            expect(
              find.textContaining('Could not write to this folder.'),
              findsOneWidget,
            );
          }
        },
      );
    }
  }
}
