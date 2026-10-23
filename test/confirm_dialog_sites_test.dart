import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/confirm_and_delete_tracks.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

// Each legacy builder is the hand-written confirm dialog a call site used
// before it moved to showAppConfirmDialog; the paired helper call carries the
// arguments that site now passes.

typedef _Site = (
  String name,
  Future<Object?> Function(BuildContext context) legacy,
  Future<Object?> Function(BuildContext context) helper,
);

Future<bool?> _legacy(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool cancelDefault = false,
  bool confirmDefault = false,
  bool filled = false,
  bool destructive = false,
  ButtonStyle? Function(BuildContext dialogContext)? style,
}) => showAppDialog<bool>(
  context: context,
  builder: (ctx) => AppAlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [
      AppDialogAction(
        isDefault: cancelDefault,
        onPressed: () => Navigator.pop(ctx, false),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: filled,
        isDefault: confirmDefault,
        isDestructive: destructive,
        onPressed: () => Navigator.pop(ctx, true),
        style: style?.call(ctx),
        child: Text(confirm),
      ),
    ],
  ),
);

ButtonStyle _filledError(BuildContext context) => FilledButton.styleFrom(
  backgroundColor: Theme.of(context).colorScheme.error,
);

ButtonStyle _textError(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error);

final _sites = <_Site>[
  (
    'batch convert',
    (context) => _legacy(
      context,
      title: context.l10n.selectionBatchConvertConfirmTitle,
      message: context.l10n.selectionBatchConvertConfirmMessage(
        3,
        'MP3',
        '320k',
      ),
      confirm: context.l10n.trackConvertFormat,
      filled: true,
      confirmDefault: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.selectionBatchConvertConfirmTitle,
      message: context.l10n.selectionBatchConvertConfirmMessage(
        3,
        'MP3',
        '320k',
      ),
      confirmLabel: context.l10n.trackConvertFormat,
      confirmIsDefault: true,
    ),
  ),
  (
    'batch replay gain',
    (context) => _legacy(
      context,
      title: context.l10n.replayGainBatchConfirmTitle,
      message: context.l10n.replayGainBatchConfirmMessage(3),
      confirm: context.l10n.replayGainBatchConfirmTitle,
      filled: true,
      confirmDefault: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.replayGainBatchConfirmTitle,
      message: context.l10n.replayGainBatchConfirmMessage(3),
      confirmLabel: context.l10n.replayGainBatchConfirmTitle,
      confirmIsDefault: true,
    ),
  ),
  (
    'queue as FLAC',
    (context) => _legacy(
      context,
      title: context.l10n.queueFlacAction,
      message: context.l10n.queueFlacConfirmMessage(3),
      confirm: context.l10n.queueFlacAction,
      filled: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.queueFlacAction,
      message: context.l10n.queueFlacConfirmMessage(3),
      confirmLabel: context.l10n.queueFlacAction,
    ),
  ),
  (
    'delete library tracks',
    (context) => _legacy(
      context,
      title: context.l10n.dialogDeleteSelectedTitle,
      message: context.l10n.dialogDeleteSelectedMessage(3),
      confirm: context.l10n.dialogDelete,
      cancelDefault: true,
      filled: true,
      destructive: true,
      style: (_) => _filledError(context),
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.dialogDeleteSelectedTitle,
      message: context.l10n.dialogDeleteSelectedMessage(3),
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      cancelIsDefault: true,
      confirmStyle: _filledError(context),
    ),
  ),
  (
    'confirm and delete tracks',
    (context) async {
      final confirmed = await _legacy(
        context,
        title: context.l10n.downloadedAlbumDeleteSelected,
        message: context.l10n.downloadedAlbumDeleteMessage(2),
        confirm: context.l10n.dialogDelete,
        cancelDefault: true,
        filled: true,
        destructive: true,
        style: (_) => _filledError(context),
      );
      return confirmed == true ? 2 : null;
    },
    // The real call site: it returns null on cancel and the deleted count
    // otherwise.
    (context) => confirmAndDeleteTracks(
      context: context,
      ids: const ['a', 'b'],
      deleteItem: (_) async => true,
      onExitSelectionMode: () {},
    ),
  ),
  (
    'track delete',
    (context) => _legacy(
      context,
      title: context.l10n.trackDeleteConfirmTitle,
      message: context.l10n.trackDeleteConfirmMessage,
      confirm: context.l10n.dialogDelete,
      destructive: true,
      style: (_) => _textError(context),
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.trackDeleteConfirmTitle,
      message: context.l10n.trackDeleteConfirmMessage,
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      filled: false,
      confirmStyle: _textError(context),
    ),
  ),
  (
    'remove replay gain',
    (context) => _legacy(
      context,
      title: context.l10n.trackRemoveReplayGain,
      message: context.l10n.replayGainRemoveConfirmMessage(1),
      confirm: context.l10n.trackRemoveReplayGain,
      filled: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.trackRemoveReplayGain,
      message: context.l10n.replayGainRemoveConfirmMessage(1),
      confirmLabel: context.l10n.trackRemoveReplayGain,
    ),
  ),
  (
    'duplicate review delete',
    (context) => _legacy(
      context,
      title: context.l10n.dialogDeleteSelectedTitle,
      message: 'Delete 2 copies?',
      confirm: context.l10n.dialogDelete,
      filled: true,
      destructive: true,
      style: _filledError,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.dialogDeleteSelectedTitle,
      message: 'Delete 2 copies?',
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      confirmStyle: _filledError(context),
    ),
  ),
  (
    'setup storage access',
    (context) => _legacy(
      context,
      title: context.l10n.setupStorageAccessRequired,
      message:
          '${context.l10n.setupStorageAccessMessageAndroid11}\n\n'
          '${context.l10n.setupAllowAccessToManageFiles}',
      confirm: context.l10n.setupOpenSettings,
      filled: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.setupStorageAccessRequired,
      message:
          '${context.l10n.setupStorageAccessMessageAndroid11}\n\n'
          '${context.l10n.setupAllowAccessToManageFiles}',
      confirmLabel: context.l10n.setupOpenSettings,
    ),
  ),
  (
    'setup default folder',
    (context) => _legacy(
      context,
      title: context.l10n.setupUseDefaultFolder,
      message: '${context.l10n.setupNoFolderSelected}\n\n/music',
      confirm: context.l10n.setupUseDefault,
      filled: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.setupUseDefaultFolder,
      message: '${context.l10n.setupNoFolderSelected}\n\n/music',
      confirmLabel: context.l10n.setupUseDefault,
    ),
  ),
  (
    'clear listening statistics',
    (context) => _legacy(
      context,
      title: context.l10n.listeningStatsClear,
      message: context.l10n.listeningStatsClearDescription,
      confirm: context.l10n.listeningStatsClear,
      destructive: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.listeningStatsClear,
      message: context.l10n.listeningStatsClearDescription,
      confirmLabel: context.l10n.listeningStatsClear,
      destructive: true,
      filled: false,
    ),
  ),
  (
    'uninstall extension',
    (context) => _legacy(
      context,
      title: context.l10n.dialogUninstallExtension,
      message: context.l10n.dialogUninstallExtensionMessage('Example'),
      confirm: context.l10n.dialogUninstall,
      cancelDefault: true,
      destructive: true,
      style: _textError,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.dialogUninstallExtension,
      message: context.l10n.dialogUninstallExtensionMessage('Example'),
      confirmLabel: context.l10n.dialogUninstall,
      destructive: true,
      filled: false,
      cancelIsDefault: true,
      confirmStyle: _textError(context),
    ),
  ),
  (
    'download selected playlists',
    (context) => _legacy(
      context,
      title: context.l10n.dialogDownloadAllTitle,
      message: context.l10n.dialogDownloadPlaylistsMessage(12, 2),
      confirm: context.l10n.dialogDownload,
      filled: true,
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.dialogDownloadAllTitle,
      message: context.l10n.dialogDownloadPlaylistsMessage(12, 2),
      confirmLabel: context.l10n.dialogDownload,
    ),
  ),
  (
    'delete selected playlists',
    (context) => _legacy(
      context,
      title: context.l10n.collectionDeletePlaylist,
      message: context.l10n.collectionDeletePlaylistsMessage(2),
      confirm: context.l10n.dialogDelete,
      cancelDefault: true,
      filled: true,
      destructive: true,
      style: (_) => _filledError(context),
    ),
    (context) => showAppConfirmDialog(
      context,
      title: context.l10n.collectionDeletePlaylist,
      message: context.l10n.collectionDeletePlaylistsMessage(2),
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      cancelIsDefault: true,
      confirmStyle: _filledError(context),
    ),
  ),
];

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required bool mornye,
  required void Function(BuildContext context) onOpen,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => onOpen(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

List<Object?> _resolved(ButtonStyle? style) => [
  for (final states in [
    <WidgetState>{},
    {WidgetState.pressed},
    {WidgetState.hovered},
    {WidgetState.disabled},
  ]) ...[
    style?.backgroundColor?.resolve(states),
    style?.foregroundColor?.resolve(states),
    style?.overlayColor?.resolve(states),
  ],
];

/// What the dialog shows, how its actions are configured and painted, and
/// where they sit.
List<Object?> _dialogSnapshot(WidgetTester tester) {
  final dialog = tester.widget<AppAlertDialog>(find.byType(AppAlertDialog));
  final actions = find.byType(AppDialogAction);
  return [
    (dialog.title as Text?)?.data,
    (dialog.content as Text?)?.data,
    tester.getRect(find.byType(AppAlertDialog)),
    for (final (index, action)
        in tester.widgetList<AppDialogAction>(actions).indexed) ...[
      (action.child as Text).data,
      action.isDefault,
      action.filled,
      action.isDestructive,
      action.outlined,
      ..._resolved(action.style),
      tester.getRect(actions.at(index)),
      // What paints: every widget type under the action, each Material's
      // fill, and the label's effective text style.
      for (final element
          in find
              .descendant(
                of: actions.at(index),
                matching: find.byWidgetPredicate((_) => true),
              )
              .evaluate()) ...[
        element.widget.runtimeType,
        if (element.widget case final Material material) material.color,
      ],
      DefaultTextStyle.of(
        tester.element(
          find.descendant(
            of: actions.at(index),
            matching: find.text((action.child as Text).data!),
          ),
        ),
      ).style,
    ],
    FocusManager.instance.primaryFocus?.debugLabel,
  ];
}

Future<(List<Object?>, Object?)> _runDialog(
  WidgetTester tester, {
  required bool mornye,
  required Future<Object?> Function(BuildContext context) open,
  required int? actionIndex,
}) async {
  Object? result = #pending;
  await _pumpLauncher(
    tester,
    mornye: mornye,
    onOpen: (context) async => result = await open(context),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  final snapshot = _dialogSnapshot(tester);
  if (actionIndex == null) {
    await tester.tapAt(const Offset(4, 4));
  } else {
    // Declared order (cancel, confirm), whatever order the style paints.
    final dialog = tester.widget<AppAlertDialog>(find.byType(AppAlertDialog));
    await tester.tap(find.byWidget(dialog.actions[actionIndex]));
  }
  await tester.pumpAndSettle();
  expect(find.byType(AppAlertDialog), findsNothing);
  return (snapshot, result);
}

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';
    group('migrated confirm dialogs ($style)', () {
      for (final (name, legacy, helper) in _sites) {
        testWidgets('$name matches the hand-written dialog', (tester) async {
          for (final (how, actionIndex) in [
            ('confirm', 1),
            ('cancel', 0),
            ('barrier', null),
          ]) {
            final (before, legacyResult) = await _runDialog(
              tester,
              mornye: mornye,
              open: legacy,
              actionIndex: actionIndex,
            );
            final (after, helperResult) = await _runDialog(
              tester,
              mornye: mornye,
              open: helper,
              actionIndex: actionIndex,
            );
            expect(after, before, reason: how);
            expect(helperResult, isNot(#pending), reason: how);
            // Every caller acted only on true; a dismissal is now false.
            expect(
              helperResult,
              helperResult is bool ? legacyResult == true : legacyResult,
              reason: how,
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    });
  }
}
