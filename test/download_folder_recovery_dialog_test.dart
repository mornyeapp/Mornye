import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

import 'support/fixed_settings.dart';
import 'support/tooltip_finder.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this.item);

  final DownloadItem item;
  final retried = <String>[];

  @override
  DownloadQueueState build() =>
      const DownloadQueueState().copyWith(items: [item], isPaused: true);

  @override
  Future<void> retryItem(String id) async => retried.add(id);
}

void main() {
  for (final mornye in [false, true]) {
    for (final failure in [
      (
        name: 'typed SAF grant failure',
        error: safPermissionLostErrorMessage,
        type: DownloadErrorType.permission,
        network: '',
        reselect: true,
      ),
      (
        name: 'untyped SAF grant failure',
        error: safPermissionLostErrorMessage,
        type: null,
        network: '',
        reselect: true,
      ),
      (
        name: 'bookmark access failure',
        error: downloadFolderAccessLostErrorMessage,
        type: DownloadErrorType.permission,
        network: '',
        reselect: true,
      ),
      (
        name: 'legacy local permission failure',
        error: 'Permission denied writing /music/song.flac',
        type: DownloadErrorType.permission,
        network: '',
        reselect: true,
      ),
      (
        name: 'connection failure',
        error: 'Connection refused',
        type: DownloadErrorType.network,
        network: '',
        reselect: false,
      ),
      (
        name: 'remote folder permission failure',
        error: 'Permission denied on remote server',
        type: DownloadErrorType.permission,
        network: 'smb://example.test/music',
        reselect: false,
      ),
    ]) {
      testWidgets('${failure.name} (Mornye: $mornye)', (tester) async {
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final item = DownloadItem(
          id: 'failed-download',
          track: const Track(
            id: 'example:song',
            name: 'Song',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
          service: 'example',
          status: DownloadStatus.failed,
          createdAt: DateTime.utc(2026),
          error: failure.error,
          errorType: failure.type,
          networkDownloadFolder: failure.network,
        );
        // Persisted failures must recover too, including legacy typed errors.
        final queue = _Queue(
          DownloadItem.fromJson(
            jsonDecode(jsonEncode(item)) as Map<String, dynamic>,
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
              downloadHistoryProvider.overrideWith(_History.new),
              downloadQueueProvider.overrideWith(() => queue),
            ],
            child: MaterialApp(
              locale: const Locale('es', 'ES'),
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.dark(),
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: QueueTab(librarySection: 'downloads')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(QueueTab));
        final l10n = context.l10n;
        final message = failure.error == safPermissionLostErrorMessage
            ? l10n.downloadErrorSafPermissionLost
            : l10n.downloadErrorFolderAccessLost;
        if (failure.reselect) expect(find.text(message), findsOneWidget);

        await tester.tap(find.text('Song'));
        await tester.pumpAndSettle();
        final dialog = find.byType(AppAlertDialog);
        expect(dialog, findsOneWidget);
        final reselect = find.descendant(
          of: dialog,
          matching: find.text(l10n.downloadFolderReselect),
        );
        final retry = find.descendant(
          of: dialog,
          matching: find.text(l10n.dialogRetry),
        );
        expect(reselect, failure.reselect ? findsOneWidget : findsNothing);
        expect(retry, failure.reselect ? findsNothing : findsOneWidget);
        if (failure.reselect) {
          expect(
            find.descendant(
              of: dialog,
              matching: find.byWidgetPredicate(
                (widget) => widget is SelectableText && widget.data == message,
              ),
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.descendant(of: dialog, matching: find.text(l10n.dialogCancel)),
          );
        } else {
          await tester.tap(retry);
        }
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(queue.retried, failure.reselect ? isEmpty : [item.id]);
        if (failure.reselect) {
          await tester.tap(findByTooltip(l10n.downloadFolderReselect));
          await tester.pumpAndSettle();
          expect(reselect, findsOneWidget);
          expect(queue.retried, isEmpty);
          await tester.tap(
            find.descendant(of: dialog, matching: find.text(l10n.dialogCancel)),
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
