import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/fixed_settings.dart';

// The settings pages used to write each confirm dialog and choice sheet by
// hand. The legacy builders below rebuild them with the flags, labels and
// icons each page passed, and every case checks them against the shared
// helper call the page makes now.

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

ThemeData _theme(bool mornye) =>
    mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light();

void _useScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  required bool mornye,
  required Widget home,
  AppSettings settings = const AppSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  _useScreen(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
        localLibraryProvider.overrideWith(_Library.new),
        extensionProvider.overrideWith(_Extensions.new),
      ],
      child: MaterialApp(
        theme: _theme(mornye),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required bool mornye,
  required void Function(BuildContext context) onOpen,
}) => _pump(
  tester,
  mornye: mornye,
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
);

ButtonStyle _errorFill(BuildContext context) => FilledButton.styleFrom(
  backgroundColor: Theme.of(context).colorScheme.error,
);

/// The two-action dialog each page wrote out: cancel pops false, confirm
/// pops true, with the page's flags on each action.
Future<bool?> _legacyDialog(
  BuildContext context, {
  required String Function(BuildContext) title,
  String Function(BuildContext)? message,
  Widget Function(BuildContext)? content,
  required String Function(BuildContext) confirm,
  bool cancelDefault = false,
  bool confirmDefault = false,
  bool filled = false,
  bool destructive = false,
  ButtonStyle Function(BuildContext)? style,
  VoidCallback? onConfirm,
}) => showAppDialog<bool>(
  context: context,
  builder: (context) => AppAlertDialog(
    title: Text(title(context)),
    content: content?.call(context) ?? Text(message!(context)),
    actions: [
      AppDialogAction(
        isDefault: cancelDefault,
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: filled,
        isDefault: confirmDefault,
        isDestructive: destructive,
        style: style?.call(context),
        onPressed: () {
          onConfirm?.call();
          Navigator.pop(context, true);
        },
        child: Text(confirm(context)),
      ),
    ],
  ),
);

/// The restore summary, reading its heading style from [themeContext] as
/// the old builder read it from the dialog.
Widget _restoreSummary(BuildContext context, BuildContext themeContext) =>
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.backupSelectedRestoreMessage),
        const SizedBox(height: 16),
        Text(
          context.l10n.backupContentsTitle,
          style: Theme.of(
            themeContext,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(context.l10n.backupContentsSettings),
      ],
    );

typedef _Site = (
  String name,
  Future<bool?> Function(BuildContext context, VoidCallback onConfirm) legacy,
  Future<void> Function(BuildContext context, VoidCallback onConfirm) helper,
);

Future<void> _confirmThen(
  Future<bool> confirmed,
  VoidCallback onConfirm,
) async {
  if (await confirmed) onConfirm();
}

final List<_Site> _sites = [
  (
    'library storage access',
    (context, done) => _legacyDialog(
      context,
      title: (c) => c.l10n.libraryStorageAccessRequired,
      message: (c) => c.l10n.libraryStorageAccessMessage,
      confirm: (c) => c.l10n.setupOpenSettings,
      filled: true,
      confirmDefault: true,
      onConfirm: done,
    ),
    (context, done) => _confirmThen(
      showAppConfirmDialog(
        context,
        title: context.l10n.libraryStorageAccessRequired,
        message: context.l10n.libraryStorageAccessMessage,
        confirmLabel: context.l10n.setupOpenSettings,
        confirmIsDefault: true,
      ),
      done,
    ),
  ),
  for (final (name, title, message, label) in [
    (
      'library clear',
      (BuildContext c) => c.l10n.libraryClearConfirmTitle,
      (BuildContext c) => c.l10n.libraryClearConfirmMessage,
      (BuildContext c) => c.l10n.dialogClear,
    ),
    (
      'library remove folder',
      (BuildContext c) => c.l10n.libraryRemoveFolder,
      (BuildContext c) => c.l10n.libraryRemoveFolderMessage,
      (BuildContext c) => c.l10n.dialogRemove,
    ),
    (
      'extension remove',
      (BuildContext c) => c.l10n.dialogRemoveExtension,
      (BuildContext c) => c.l10n.dialogRemoveExtensionMessage,
      (BuildContext c) => c.l10n.dialogRemove,
    ),
  ])
    (
      name,
      (context, done) => _legacyDialog(
        context,
        title: title,
        message: message,
        confirm: label,
        cancelDefault: true,
        filled: true,
        destructive: true,
        style: _errorFill,
        onConfirm: done,
      ),
      (context, done) => _confirmThen(
        showAppConfirmDialog(
          context,
          title: title(context),
          message: message(context),
          confirmLabel: label(context),
          cancelIsDefault: true,
          destructive: true,
          confirmStyle: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
        done,
      ),
    ),
  (
    'playback volume warning',
    (context, done) => _legacyDialog(
      context,
      title: (c) => c.l10n.usbVolumeWarningTitle,
      message: (c) => c.l10n.usbVolumeWarning,
      confirm: (c) => c.l10n.usbVolumeAccept,
      onConfirm: done,
    ),
    (context, done) => _confirmThen(
      showAppConfirmDialog(
        context,
        title: context.l10n.usbVolumeWarningTitle,
        message: context.l10n.usbVolumeWarning,
        confirmLabel: context.l10n.usbVolumeAccept,
        filled: false,
      ),
      done,
    ),
  ),
  (
    'playback reset learning',
    (context, done) => _legacyDialog(
      context,
      title: (c) => c.l10n.autoplayResetLearningConfirmTitle,
      message: (c) => c.l10n.autoplayResetLearningConfirmMessage,
      confirm: (c) => c.l10n.autoplayResetLearningConfirm,
      destructive: true,
      onConfirm: done,
    ),
    (context, done) => _confirmThen(
      showAppConfirmDialog(
        context,
        title: context.l10n.autoplayResetLearningConfirmTitle,
        message: context.l10n.autoplayResetLearningConfirmMessage,
        confirmLabel: context.l10n.autoplayResetLearningConfirm,
        destructive: true,
        filled: false,
      ),
      done,
    ),
  ),
  for (final (name, title, message) in [
    (
      'cache clear one',
      (BuildContext c) => c.l10n.cacheClearConfirmTitle,
      (BuildContext c) =>
          c.l10n.cacheClearConfirmMessage(c.l10n.cacheCoverImage),
    ),
    (
      'cache clear all',
      (BuildContext c) => c.l10n.cacheClearAllConfirmTitle,
      (BuildContext c) => c.l10n.cacheClearAllConfirmMessage,
    ),
    (
      'log clear',
      (BuildContext c) => c.l10n.logClearLogsTitle,
      (BuildContext c) => c.l10n.logClearLogsMessage,
    ),
  ])
    (
      name,
      (context, done) => _legacyDialog(
        context,
        title: title,
        message: message,
        confirm: (c) => c.l10n.dialogClear,
        cancelDefault: true,
        filled: true,
        destructive: true,
        onConfirm: done,
      ),
      (context, done) => _confirmThen(
        showAppConfirmDialog(
          context,
          title: title(context),
          message: message(context),
          confirmLabel: context.l10n.dialogClear,
          cancelIsDefault: true,
          destructive: true,
        ),
        done,
      ),
    ),
  (
    'backup restore',
    (context, done) => _legacyDialog(
      context,
      title: (c) => c.l10n.backupRestoreConfirmTitle,
      content: (dialogContext) => _restoreSummary(context, dialogContext),
      confirm: (c) => c.l10n.backupRestoreConfirmButton,
      cancelDefault: true,
      filled: true,
      destructive: true,
      onConfirm: done,
    ),
    (context, done) => _confirmThen(
      showAppConfirmDialog(
        context,
        title: context.l10n.backupRestoreConfirmTitle,
        confirmLabel: context.l10n.backupRestoreConfirmButton,
        cancelIsDefault: true,
        destructive: true,
        content: _restoreSummary(context, context),
      ),
      done,
    ),
  ),
];

/// Everything the dialog shows and how its actions are set up and laid out.
List<Object?> _dialogSnapshot(WidgetTester tester) {
  final dialog = find.byType(AppAlertDialog);
  final texts = find.descendant(of: dialog, matching: find.byType(Text));
  final actions = find.byType(AppDialogAction);
  Color? resolve(WidgetStateProperty<Color?>? color) =>
      color?.resolve(const {});
  return [
    tester.getRect(dialog),
    for (final (index, text) in tester.widgetList<Text>(texts).indexed)
      (text.data, text.style, tester.getRect(texts.at(index))),
    for (final (index, action)
        in tester.widgetList<AppDialogAction>(actions).indexed)
      (
        action.isDefault,
        action.filled,
        action.isDestructive,
        action.outlined,
        resolve(action.style?.backgroundColor),
        resolve(action.style?.foregroundColor),
        tester.getRect(actions.at(index)),
      ),
    FocusManager.instance.primaryFocus?.debugLabel,
  ];
}

typedef _Option = (String value, IconData icon, String title, String? sub);

/// The single-choice sheet the library and lyrics pages wrote by hand.
void _legacySheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required String current,
  required List<_Option> options,
  required ValueChanged<String> onSelected,
}) {
  showAppScrollableBottomSheet<void>(
    context: context,
    title: title,
    subtitle: subtitle,
    builder: (context, controller) => SingleChildScrollView(
      controller: controller,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (value, icon, label, sub) in options)
            AppSheetOption.choice(
              leading: AppIcon(icon),
              title: Text(label),
              subtitle: sub == null ? null : Text(sub),
              selected: current == value,
              onTap: () {
                onSelected(value);
                Navigator.pop(context);
              },
            ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

List<Object?> _sheetSnapshot(WidgetTester tester, String title, String? sub) {
  final options = find.byType(AppSheetOption);
  return [
    tester.getRect(find.byType(AppScrollableSheet)),
    tester.getRect(find.byType(SingleChildScrollView).last),
    tester.getRect(find.text(title).last),
    if (sub != null) tester.getRect(find.text(sub).last),
    for (final (index, option)
        in tester.widgetList<AppSheetOption>(options).indexed)
      (
        (option.title as Text).data,
        (option.subtitle as Text?)?.data,
        (option.leading! as AppIcon).icon,
        option.selected,
        tester.getRect(options.at(index)),
      ),
  ];
}

typedef _SheetCase = (
  String row,
  String? sheetSubtitle,
  String current,
  List<_Option> options,
  String pick,
  String Function(AppSettings settings) read,
);

List<_SheetCase> _libraryCases(AppLocalizations l10n) => [
  (
    l10n.libraryAutoScan,
    l10n.libraryAutoScanSubtitle,
    'daily',
    [
      ('off', Icons.block, l10n.libraryAutoScanOff, null),
      ('on_open', Icons.open_in_new, l10n.libraryAutoScanOnOpen, null),
      ('daily', Icons.today, l10n.libraryAutoScanDaily, null),
      ('weekly', Icons.date_range, l10n.libraryAutoScanWeekly, null),
    ],
    'weekly',
    (settings) => settings.localLibraryAutoScan,
  ),
  (
    l10n.libraryDefaultView,
    null,
    'albums',
    [
      ('last', Icons.history, l10n.libraryDefaultViewLastUsed, null),
      ('all', Icons.music_note, l10n.searchSongs, null),
      ('albums', Icons.album, l10n.historyFilterAlbums, null),
      ('singles', Icons.audiotrack, l10n.historyFilterSingles, null),
      ('artists', Icons.person, l10n.searchArtists, null),
      ('playlists', Icons.queue_music, l10n.searchPlaylists, null),
    ],
    'playlists',
    (settings) => settings.defaultLibraryView,
  ),
  (
    l10n.trackAudioQuality,
    null,
    AppSettings.libraryQualityLabelBitDepth,
    [
      (
        AppSettings.libraryQualityLabelBitrate,
        Icons.speed_rounded,
        l10n.trackConvertBitrate,
        null,
      ),
      (
        AppSettings.libraryQualityLabelBitDepthOnly,
        Icons.tune_rounded,
        l10n.audioAnalysisBitDepth,
        null,
      ),
      (
        AppSettings.libraryQualityLabelBitDepth,
        Icons.graphic_eq_rounded,
        '${l10n.audioAnalysisBitDepth} & '
            '${l10n.audioAnalysisSampleRate}',
        null,
      ),
      (
        AppSettings.libraryQualityLabelBitDepthBitrate,
        Icons.multiline_chart_rounded,
        '${l10n.audioAnalysisBitDepth} & '
            '${l10n.trackConvertBitrate}',
        null,
      ),
      (
        AppSettings.libraryQualityLabelFileFormat,
        Icons.audio_file_rounded,
        l10n.libraryQualityLabelFileFormat,
        null,
      ),
    ],
    AppSettings.libraryQualityLabelFileFormat,
    (settings) => settings.libraryQualityLabelMode,
  ),
];

List<_SheetCase> _lyricsCases(AppLocalizations l10n) => [
  (
    l10n.lyricsMode,
    l10n.lyricsModeDescription,
    'both',
    [
      (
        'embed',
        Icons.audiotrack,
        l10n.lyricsModeEmbed,
        l10n.lyricsModeEmbedSubtitle,
      ),
      (
        'external',
        Icons.insert_drive_file_outlined,
        l10n.lyricsModeExternal,
        l10n.lyricsModeExternalSubtitle,
      ),
      (
        'both',
        Icons.library_music_outlined,
        l10n.lyricsModeBoth,
        l10n.lyricsModeBothSubtitle,
      ),
    ],
    'external',
    (settings) => settings.lyricsMode,
  ),
];

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    for (final (name, legacy, helper) in _sites) {
      testWidgets('$name dialog is unchanged ($style)', (tester) async {
        // Mornye lists the filled confirm action first, so actions are
        // found by their label.
        Finder action({required bool cancel}) => find.byWidgetPredicate(
          (widget) =>
              widget is AppDialogAction &&
              ((widget.child as Text).data == 'Cancel') == cancel,
        );
        final closes = <String, Future<void> Function()>{
          'confirm': () => tester.tap(action(cancel: false)),
          'cancel': () => tester.tap(action(cancel: true)),
          'barrier': () => tester.tapAt(const Offset(4, 4)),
        };
        for (final MapEntry(key: how, value: close) in closes.entries) {
          Future<(List<Object?>, Object?, int)> run(bool useHelper) async {
            Object? result;
            var confirmed = 0;
            await _pumpLauncher(
              tester,
              mornye: mornye,
              onOpen: (context) async => useHelper
                  ? await helper(context, () => confirmed++)
                  : result = await legacy(context, () => confirmed++),
            );
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            final snapshot = _dialogSnapshot(tester);
            await close();
            await tester.pumpAndSettle();
            expect(find.byType(AppAlertDialog), findsNothing);
            return (snapshot, result, confirmed);
          }

          final before = await run(false);
          final after = await run(true);
          expect(after.$1, before.$1, reason: how);
          // The pages acted only on true; dismissing reads as cancel.
          expect(before.$3, before.$2 == true ? 1 : 0, reason: how);
          expect(after.$3, before.$3, reason: how);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final (page, cases, settings) in [
      (
        const LibrarySettingsPage(),
        _libraryCases,
        const AppSettings(
          localLibraryEnabled: true,
          localLibraryAutoScan: 'daily',
          defaultLibraryView: 'albums',
          libraryQualityLabelMode: AppSettings.libraryQualityLabelBitDepth,
        ),
      ),
      (
        const LyricsSettingsPage(),
        _lyricsCases,
        const AppSettings(
          embedMetadata: true,
          embedLyrics: true,
          lyricsMode: 'both',
        ),
      ),
    ]) {
      testWidgets('${page.runtimeType} sheets are unchanged ($style)', (
        tester,
      ) async {
        await _pump(tester, mornye: mornye, home: const SizedBox());
        final l10n = tester.element(find.byType(SizedBox)).l10n;
        for (final (row, sub, current, options, pick, read) in cases(l10n)) {
          String? legacyPick;
          await _pumpLauncher(
            tester,
            mornye: mornye,
            onOpen: (context) => _legacySheet(
              context,
              title: row,
              subtitle: sub,
              current: current,
              options: options,
              onSelected: (value) => legacyPick = value,
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final before = _sheetSnapshot(tester, row, sub);
          await tester.tap(
            find.text(options.firstWhere((o) => o.$1 == pick).$3).last,
          );
          await tester.pumpAndSettle();
          expect(legacyPick, pick);

          await _pump(tester, mornye: mornye, home: page, settings: settings);
          final rowFinder = find.byWidgetPredicate(
            (widget) => widget is SettingsItem && widget.title == row,
          );
          await tester.scrollUntilVisible(rowFinder, 200);
          await tester.pumpAndSettle();
          await tester.tap(rowFinder);
          await tester.pumpAndSettle();
          expect(_sheetSnapshot(tester, row, sub), before, reason: row);
          await tester.tap(
            find.text(options.firstWhere((o) => o.$1 == pick).$3).last,
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppSheetOption), findsNothing);
          final container = ProviderScope.containerOf(
            tester.element(find.byWidget(page)),
          );
          expect(read(container.read(settingsProvider)), pick, reason: row);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
