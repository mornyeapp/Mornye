import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/theme/app_theme.dart';

import 'support/fixed_settings.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this.item);

  final DownloadItem item;

  @override
  DownloadQueueState build() =>
      const DownloadQueueState().copyWith(items: [item], isPaused: true);
}

class _NamedExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'provider-a',
        name: 'provider-a',
        displayName: 'Provider A',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
      ),
    ],
  );
}

DownloadItem _waiting(String marker) => DownloadItem(
  id: 'download-waiting',
  track: const Track(
    id: 'example:song',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  ),
  service: 'provider-a',
  status: DownloadStatus.downloading,
  createdAt: DateTime.utc(2026),
  error: marker,
  errorType: DownloadErrorType.verificationRequired,
);

Future<void> _pumpQueue(WidgetTester tester, DownloadItem item) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        downloadHistoryProvider.overrideWith(_History.new),
        downloadQueueProvider.overrideWith(() => _Queue(item)),
        extensionProvider.overrideWith(_NamedExtensions.new),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: QueueTab(librarySection: 'downloads')),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a download waiting for verification names the extension', (
    tester,
  ) async {
    await _pumpQueue(tester, _waiting('Waiting for verification: provider-a'));
    expect(find.text('Waiting for Provider A verification...'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a waiting marker without an extension reads as before', (
    tester,
  ) async {
    await _pumpQueue(tester, _waiting('Waiting for verification'));
    final l10n = tester.element(find.byType(QueueTab)).l10n;
    expect(find.text(l10n.queueWaitingForVerification), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
