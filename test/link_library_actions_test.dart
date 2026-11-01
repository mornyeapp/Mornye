import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_library_jobs_host.dart';
import 'package:mornye/services/link/features/link_library_jobs_client.dart';
import 'package:mornye/services/link/features/link_library_reconcile.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/link/link_library_actions.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';

import 'support/link_fakes.dart';
import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  final item = UnifiedLibraryItem.fromLocalLibrary(
    LocalLibraryItem(
      id: 'phone_index',
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: linkDesktopSongSource(
        linkTestServer,
        'l:desktop_song',
        format: 'flac',
      ),
      format: 'flac',
      scannedAt: DateTime(2026),
    ),
  );

  for (final mornye in [false, true]) {
    testWidgets(
      'remote conversion sends chosen settings only after confirmation ($mornye)',
      (tester) async {
        final client = FakeLinkClient(
          onGet: (_, _) => {
            'actions': ['convert'],
            'jobs': <Object?>[],
          },
          onPost: (_, body) => LinkLibraryJob(
            id: body['id'] as String,
            action: LinkLibraryAction.convert,
            status: LinkLibraryJobStatus.completed,
            total: 1,
            finished: 1,
            succeeded: 1,
          ).toJson(),
        );
        final container = ProviderContainer(
          overrides: [
            linkPhoneClientProvider.overrideWithValue(client),
            linkLibraryReconcileProvider.overrideWithValue((_, _) async {}),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await client.close();
        });
        var accepted = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => unawaited(
                      runLinkLibraryAction(
                        context,
                        container,
                        [item],
                        LinkLibraryAction.convert,
                        onAccepted: () {
                          accepted++;
                        },
                      ),
                    ),
                    child: const Text('Remote convert'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Remote convert'));
        await tester.pumpAndSettle();
        tester
            .widget<BatchConvertSheet>(find.byType(BatchConvertSheet))
            .onConvert(
              'FLAC',
              '320k',
              const LosslessConversionQuality(
                maxBitDepth: 16,
                maxSampleRate: 44100,
              ),
              const LosslessConversionProcessing(
                dither: 'triangular',
                resampler: 'soxr',
              ),
              true,
            );
        await tester.pumpAndSettle();
        expect(find.text('Convert Format on Studio PC'), findsOneWidget);
        expect(client.posts, isEmpty);
        expect(accepted, 0);
        await tester.tap(find.text('Convert Format'));
        await tester.pumpAndSettle();
        expect(client.posts.single.body['options'], {
          'format': 'FLAC',
          'bitrate': '320k',
          'keepOriginal': true,
          'maxBitDepth': 16,
          'maxSampleRate': 44100,
          'dither': 'triangular',
          'resampler': 'soxr',
        });
        expect(accepted, 1);
        // Ends like a conversion on this phone: progress, then the result.
        expect(find.byType(BatchProgressDialog), findsNothing);
        expect(find.text('Converted 1 of 1 tracks to FLAC'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('desktop song menu offers remote file actions ($mornye)', (
      tester,
    ) async {
      final client = FakeLinkClient();
      addTearDown(client.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            linkPhoneClientProvider.overrideWithValue(client),
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(const AppSettings()),
            ),
            extensionProvider.overrideWith(_Extensions.new),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(localItem: item.localItem),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Show menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (final label in [
        'Edit Metadata',
        'Re-enrich',
        'Convert Format',
        'Rescan ReplayGain',
        'Remove ReplayGain',
        'Save Cover Art',
        'Save Lyrics (.lrc)',
        'Delete',
      ]) {
        // The same words as the actions on this phone's songs.
        expect(find.text(label), findsOneWidget);
      }
      expect(find.textContaining('on Studio PC'), findsNothing);
      expect(client.posts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets(
      'remote deletion names target and only runs after confirmation ($mornye)',
      (tester) async {
        late FakeLinkClient client;
        final executed = <String>[];
        final host = LinkLibraryJobsHost(
          isPaired: (_) async => true,
          execute: (work, id) async {
            executed.add(id);
            return {};
          },
          notify: (_, job) =>
              client.push({'type': 'library.job', 'job': job.toJson()}),
          onChanged: () async {},
        );
        client = FakeLinkClient(
          onGet: (op, _) => host.handle(
            LinkRequest(
              requestId: 'get',
              op: op,
              deviceId: 'phone',
              args: const {'_method': 'GET'},
            ),
          ),
          onPost: (op, body) => host.handle(
            LinkRequest(
              requestId: 'post',
              op: op,
              deviceId: 'phone',
              args: body,
            ),
          ),
        );
        final container = ProviderContainer(
          overrides: [
            linkPhoneClientProvider.overrideWithValue(client),
            linkLibraryReconcileProvider.overrideWithValue((_, _) async {}),
          ],
        );
        addTearDown(() async {
          host.close();
          container.dispose();
          await client.close();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => unawaited(
                      runLinkLibraryAction(context, container, [
                        item,
                      ], LinkLibraryAction.delete),
                    ),
                    child: const Text('Remote delete'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Remote delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete on Studio PC'), findsOneWidget);
        expect(find.textContaining("computer's storage"), findsOneWidget);
        expect(client.posts, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(executed, isEmpty);
        await tester.tap(find.text('Remote delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(executed, ['l:desktop_song']);
        expect(client.posts.single.op, LinkOps.libraryJobs);
        expect(client.posts.single.body['songIds'], ['l:desktop_song']);
        expect(find.text('Deleted 1 track'), findsOneWidget);
        expect(
          container.read(linkLibraryJobsProvider).jobs.single.active,
          isFalse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('mixed-device batch never sends an operation', (tester) async {
    final client = FakeLinkClient();
    final container = ProviderContainer(
      overrides: [linkPhoneClientProvider.overrideWithValue(client)],
    );
    addTearDown(() async {
      container.dispose();
      await client.close();
    });
    final local = UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'local',
        trackName: 'Local',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/local.flac',
        scannedAt: DateTime(2026),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  runLinkLibraryAction(context, container, [
                    item,
                    local,
                  ], LinkLibraryAction.replayGain),
                ),
                child: const Text('Mixed batch'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mixed batch'));
    await tester.pumpAndSettle();
    expect(find.textContaining('one linked computer'), findsOneWidget);
    expect(client.posts, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> pumpJobs(WidgetTester tester, List<LinkLibraryJob> jobs) async {
    final client = FakeLinkClient(
      onGet: (_, _) => {
        'actions': ['convert'],
        'jobs': [for (final job in jobs) job.toJson()],
      },
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkPhoneClientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: LinkLibraryJobsView()),
        ),
      ),
    );
    // A running job's progress bar never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('file changes list jobs in one group with their failures', (
    tester,
  ) async {
    await pumpJobs(tester, const [
      LinkLibraryJob(
        id: 'read',
        action: LinkLibraryAction.readMetadata,
        status: LinkLibraryJobStatus.completed,
        total: 1,
        finished: 1,
        succeeded: 1,
      ),
      LinkLibraryJob(
        id: 'convert',
        action: LinkLibraryAction.convert,
        status: LinkLibraryJobStatus.completed,
        total: 2,
        finished: 2,
        succeeded: 1,
        results: [
          {'songId': 'a', 'title': 'Good'},
          {'songId': 'b', 'title': 'Broken', 'error': 'conversion_failed'},
        ],
      ),
      LinkLibraryJob(
        id: 'gain',
        action: LinkLibraryAction.replayGain,
        status: LinkLibraryJobStatus.running,
        total: 3,
        finished: 1,
        currentTitle: 'Next Song',
      ),
    ]);
    expect(find.byType(SettingsGroup), findsOneWidget);
    expect(find.text('Convert Format'), findsOneWidget);
    expect(find.text('2 of 2 songs · 1 failed'), findsOneWidget);
    expect(find.text('Broken: Conversion failed'), findsOneWidget);
    expect(find.text('Next Song · 1 of 3 songs'), findsOneWidget);
    expect(find.byTooltip('Stop after the current song'), findsOneWidget);
    // Reading tags is a step of an edit, not a change of its own.
    expect(find.text('Show details'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('file changes without any job show the empty state', (
    tester,
  ) async {
    await pumpJobs(tester, const []);
    expect(find.text('No file changes yet'), findsOneWidget);
    expect(find.byType(SettingsGroup), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
