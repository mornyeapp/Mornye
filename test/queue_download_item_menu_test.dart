import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/network_upload_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';

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

DownloadItem _download(DownloadStatus status, {double progress = 0}) =>
    DownloadItem(
      id: 'download-${status.name}',
      track: const Track(
        id: 'example:song',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        albumId: 'example-album',
        duration: 180,
        source: 'example',
      ),
      service: 'example',
      status: status,
      progress: progress,
      createdAt: DateTime.utc(2026),
      error: status == DownloadStatus.failed ? 'Connection refused' : null,
      errorType: status == DownloadStatus.failed
          ? DownloadErrorType.network
          : null,
    );

Future<AppLocalizations> _pumpQueue(
  WidgetTester tester,
  DownloadItem item, {
  required bool mornye,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        downloadHistoryProvider.overrideWith(_History.new),
        downloadQueueProvider.overrideWith(() => _Queue(item)),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: QueueTab(librarySection: 'downloads')),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return tester.element(find.byType(QueueTab)).l10n;
}

/// Records what the app puts on the clipboard.
List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final mornye in [false, true]) {
    testWidgets('a queued row adds album and copy to its menu '
        '(Mornye: $mornye)', (tester) async {
      debugDesktopPlatformOverride = false;
      final copied = _mockClipboard(tester);
      final l10n = await _pumpQueue(
        tester,
        _download(DownloadStatus.queued),
        mornye: mornye,
      );

      await tester.longPress(find.text('Song'));
      await tester.pumpAndSettle();
      for (final label in [
        l10n.queueDownloadNext,
        l10n.queueMoveUp,
        l10n.queueMoveDown,
        l10n.homeGoToAlbum,
        l10n.trackOptionCopyTrackAndArtist,
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }

      await tester.tap(find.text(l10n.trackOptionCopyTrackAndArtist));
      await tester.pumpAndSettle();
      expect(copied, ['Song - Artist']);
      expect(find.text(l10n.trackCopiedToClipboard), findsOneWidget);
      expect(find.text(l10n.queueMoveUp), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed row gets album and copy and keeps its dialog '
        '(Mornye: $mornye)', (tester) async {
      debugDesktopPlatformOverride = false;
      final copied = _mockClipboard(tester);
      final l10n = await _pumpQueue(
        tester,
        _download(DownloadStatus.failed),
        mornye: mornye,
      );

      await tester.tap(find.text('Song'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AppAlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text(l10n.dialogRetry)),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: dialog, matching: find.text(l10n.dialogCancel)),
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);

      await tester.longPress(find.text('Song'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.homeGoToAlbum), findsOneWidget);
      expect(find.text(l10n.trackOptionCopyTrackAndArtist), findsOneWidget);
      expect(find.text(l10n.queueMoveUp), findsNothing);
      expect(find.text(l10n.queueDownloadNext), findsNothing);

      await tester.tap(find.text(l10n.trackOptionCopyTrackAndArtist));
      await tester.pumpAndSettle();
      expect(copied, ['Song - Artist']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a downloading row opens album and copy on right-click '
        '(Mornye: $mornye)', (tester) async {
      debugDesktopPlatformOverride = true;
      final l10n = await _pumpQueue(
        tester,
        _download(DownloadStatus.downloading, progress: 0.5),
        mornye: mornye,
        settle: false,
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Song')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      // The row's progress keeps animating, so the menu gets fixed frames.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(l10n.homeGoToAlbum), findsOneWidget);
      expect(find.text(l10n.trackOptionCopyTrackAndArtist), findsOneWidget);
      expect(find.text(l10n.queueMoveUp), findsNothing);
      expect(find.text(l10n.dialogCancel), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the desktop library menu adds album and copy to one song row', (
    tester,
  ) async {
    final copied = _mockClipboard(tester);
    final song = UnifiedLibraryItem.fromDownloadHistory(
      DownloadHistoryItem(
        id: 'example-download',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/song.flac',
        service: 'example',
        downloadedAt: DateTime(2026),
      ),
    );
    final other = UnifiedLibraryItem.fromDownloadHistory(
      DownloadHistoryItem(
        id: 'example-download-2',
        trackName: 'Other',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/other.flac',
        service: 'example',
        downloadedAt: DateTime(2026),
      ),
    );
    late BuildContext menuContext;
    late WidgetRef menuRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          networkUploadConnectionsProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                menuContext = context;
                menuRef = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    final l10n = menuContext.l10n;
    var done = 0;
    List<String> labels(List<List<ContextMenuAction>> groups) => [
      for (final group in groups)
        for (final action in group) action.label,
    ];

    final row = libraryTrackMenuGroups(
      menuContext,
      menuRef,
      items: [song],
      onDone: () => done++,
    );
    expect(
      labels(row),
      containsAll([l10n.homeGoToAlbum, l10n.trackOptionCopyTrackAndArtist]),
    );
    // A collection header (no onDone) and a multiple selection have neither.
    for (final groups in [
      libraryTrackMenuGroups(menuContext, menuRef, items: [song]),
      libraryTrackMenuGroups(
        menuContext,
        menuRef,
        items: [song, other],
        onDone: () {},
      ),
    ]) {
      expect(labels(groups), isNot(contains(l10n.homeGoToAlbum)));
      expect(
        labels(groups),
        isNot(contains(l10n.trackOptionCopyTrackAndArtist)),
      );
    }

    row
        .expand((group) => group)
        .firstWhere(
          (action) => action.label == l10n.trackOptionCopyTrackAndArtist,
        )
        .onSelected!();
    await tester.pump();
    expect(copied, ['Song - Artist']);
    expect(done, 1);
    expect(find.text(l10n.trackCopiedToClipboard), findsOneWidget);
  });
}
