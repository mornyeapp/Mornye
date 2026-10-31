import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_library_jobs_host.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/desktop/desktop_link_library_jobs_view.dart';
import 'package:mornye/widgets/link/link_library_actions.dart';

class _Host extends LinkDesktopHost {
  _Host(this.jobs);

  final List<LinkHostedLibraryJob> jobs;
  final cancelled = <String>[];

  @override
  LinkDesktopHostState build() => LinkDesktopHostState(
    devices: const [
      LinkPairedDevice(deviceId: 'phone-a', name: 'Pixel', platform: 'android'),
      LinkPairedDevice(deviceId: 'phone-b', name: 'iPhone', platform: 'ios'),
    ],
    libraryJobs: jobs,
  );

  @override
  void cancelLibraryJob(String deviceId, String id) =>
      cancelled.add('$deviceId:$id');
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets(
      'desktop file changes show requesting phones and results ($mornye)',
      (tester) async {
        final host = _Host([
          (
            deviceId: 'phone-a',
            job: const LinkLibraryJob(
              id: 'metadata',
              action: LinkLibraryAction.editMetadata,
              status: LinkLibraryJobStatus.completed,
              total: 1,
              finished: 1,
              succeeded: 1,
              results: [
                {'title': 'Renamed song'},
              ],
            ),
          ),
          (
            deviceId: 'phone-b',
            job: const LinkLibraryJob(
              id: 'convert',
              action: LinkLibraryAction.convert,
              status: LinkLibraryJobStatus.running,
              total: 2,
              currentTitle: 'Converting song',
            ),
          ),
          (
            deviceId: 'phone-a',
            job: const LinkLibraryJob(
              id: 'delete',
              action: LinkLibraryAction.delete,
              status: LinkLibraryJobStatus.completed,
              total: 1,
              finished: 1,
              results: [
                {'title': 'Missing song', 'error': 'operation_failed'},
              ],
            ),
          ),
          (
            deviceId: 'phone-b',
            job: const LinkLibraryJob(
              id: 'read',
              action: LinkLibraryAction.readMetadata,
              status: LinkLibraryJobStatus.completed,
              total: 1,
            ),
          ),
        ]);
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [linkDesktopHostProvider.overrideWith(() => host)],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 560,
                    child: DesktopLinkLibraryJobsView(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rows = tester
            .widgetList<LinkLibraryJobRow>(find.byType(LinkLibraryJobRow))
            .toList();
        expect(rows.map((row) => row.job.id), [
          'delete',
          'convert',
          'metadata',
        ]);
        expect(rows.map((row) => row.deviceName), ['Pixel', 'iPhone', 'Pixel']);
        expect(find.text('Renamed song'), findsOneWidget);
        expect(find.textContaining('Missing song:'), findsOneWidget);
        expect(find.textContaining('From iPhone'), findsOneWidget);
        await tester.tap(find.byTooltip('Stop after the current song'));
        expect(host.cancelled, ['phone-b:convert']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
