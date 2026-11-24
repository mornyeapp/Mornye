import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/network_upload_provider.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_library_upload.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/network_upload_actions.dart';

import 'support/tooltip_finder.dart';

UnifiedLibraryItem song(String path) => UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: path,
    trackName: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: path,
    scannedAt: DateTime(2026),
  ),
);

/// The Material progress bar waves without end, so this pumps a second of
/// frames instead of settling.
Future<void> settle(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const nas = NetworkConnection(
  id: 'nas',
  name: 'NAS',
  protocol: NetworkProtocol.webdav,
  address: 'https://nas.example/music/',
);

void main() {
  const label = 'Upload to network storage';

  Future<void> pump(
    WidgetTester tester, {
    required List<UnifiedLibraryItem> items,
    required List<NetworkConnection> writable,
    bool mornye = false,
    NetworkUploadNotifier? upload,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkUploadConnectionsProvider.overrideWith(
            (ref) async => writable,
          ),
          if (upload != null) networkUploadProvider.overrideWith(() => upload),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                LibrarySelectionPlaybackActions(items: items, onClose: () {}),
                NetworkUploadButton(items: items),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mornye in [false, true]) {
    testWidgets('songs on this device offer the upload ($mornye)', (
      tester,
    ) async {
      await pump(
        tester,
        items: [song('/music/a.flac'), song('network://nas/b.flac')],
        writable: [nas],
        mornye: mornye,
      );
      expect(find.text(label), findsOneWidget);
      expect(findByTooltip(label), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mornye in [false, true]) {
    testWidgets('a closed progress sheet leads back to it ($mornye)', (
      tester,
    ) async {
      final upload = _Uploading();
      await pump(
        tester,
        items: [song('/music/a.flac')],
        writable: [nas],
        mornye: mornye,
        upload: upload,
      );
      await tester.tap(findByTooltip(label));
      await settle(tester);
      expect(find.text('Second song'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);

      Navigator.of(tester.element(find.text('Second song'))).pop();
      await settle(tester);
      expect(find.text('Second song'), findsNothing);
      expect(
        find.text('The upload continues. Network storage shows its progress.'),
        findsOneWidget,
      );
      await tester.tap(find.text('View'));
      await settle(tester);
      expect(find.text('Second song'), findsOneWidget);

      upload.finish();
      await settle(tester);
      expect(find.text('Second song'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test('the outcome names the counts, a stop or the failure', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(
      networkUploadOutcome(
        l10n,
        result: const NetworkUploadResult(
          saved: 2,
          skipped: 1,
          failed: 1,
          cancelled: false,
        ),
      ),
      'Uploaded 2, already there 1, failed 1',
    );
    expect(
      networkUploadOutcome(
        l10n,
        result: const NetworkUploadResult(saved: 1, failed: 0, cancelled: true),
      ),
      'Upload stopped',
    );
    expect(
      networkUploadOutcome(l10n, error: const NetworkUploadReadOnly()),
      l10n.networkUploadReadOnly,
    );
    expect(
      networkUploadOutcome(l10n, error: StateError('offline')),
      l10n.networkUploadFailed,
    );
  });

  testWidgets('network songs never offer the upload', (tester) async {
    await pump(
      tester,
      items: [song('network://nas/b.flac'), song('/music/album.cue#track01')],
      writable: [nas],
    );
    expect(find.text(label), findsNothing);
    expect(findByTooltip(label), findsNothing);
  });

  testWidgets('no writable connection hides the upload', (tester) async {
    await pump(tester, items: [song('/music/a.flac')], writable: const []);
    expect(find.text(label), findsNothing);
    expect(findByTooltip(label), findsNothing);
  });

  for (final mornye in [false, true]) {
    testWidgets('the folder browser returns the chosen folder ($mornye)', (
      tester,
    ) async {
      final service = _Folders();
      String? picked;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await browseNetworkUploadFolder(
                  context,
                  nas,
                  service: service,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      // Folders only, and none of the Library or download actions.
      expect(find.text('Rock'), findsOneWidget);
      expect(find.text('Song.flac'), findsNothing);
      expect(find.text('Add folder to Library'), findsNothing);
      expect(find.text('Download to this folder'), findsNothing);
      await tester.tap(find.text('Rock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Upload to this folder'));
      await tester.pumpAndSettle();
      expect(service.checked, ['network://nas/Rock/']);
      expect(picked, 'network://nas/Rock/');
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('the offer waits for the connections to load', () {
    expect(networkUploadOffered(null, [song('/music/a.flac')]), isFalse);
    expect(networkUploadOffered([nas], [song('/music/a.flac')]), isTrue);
  });
}

class _Uploading extends NetworkUploadNotifier {
  @override
  NetworkUploadStatus? build() => const NetworkUploadStatus(
    LinkOfflineProgress(done: 1, total: 3, title: 'Second song'),
  );

  void finish() => state = NetworkUploadStatus(
    state!.progress,
    result: const NetworkUploadResult(saved: 3, failed: 0, cancelled: false),
  );
}

class _Folders extends NetworkStorageService {
  _Folders() : super(read: () async => null, write: (_) async {});
  final checked = <String>[];

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection connection, [
    String path = '',
  ]) async => path.isEmpty
      ? const [
          NetworkEntry('Rock/', 'Rock', directory: true),
          NetworkEntry('Song.flac', 'Song.flac'),
        ]
      : const [];

  @override
  Future<void> checkUploadAccess(String folder) async => checked.add(folder);
}
