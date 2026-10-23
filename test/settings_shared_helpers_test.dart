import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/settings_group.dart';

// The legacy builders below are the hand-written dialogs and sheets the
// shared helpers replaced, kept here to prove the helpers build the same UI.

Future<bool?> _legacyDiscard(BuildContext context) => showAppDialog<bool>(
  context: context,
  builder: (context) => AppAlertDialog(
    title: Text(context.l10n.dialogDiscardChanges),
    content: Text(context.l10n.dialogUnsavedChanges),
    actions: [
      AppDialogAction(
        isDefault: true,
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        isDestructive: true,
        onPressed: () => Navigator.pop(context, true),
        child: Text(context.l10n.dialogDiscard),
      ),
    ],
  ),
);

Future<bool?> _legacyOpenSettings(BuildContext context) => showAppDialog<bool>(
  context: context,
  builder: (context) => AppAlertDialog(
    title: Text(context.l10n.setupStorageAccessRequired),
    content: Text(context.l10n.allFilesAccessDeniedMessage),
    actions: [
      AppDialogAction(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        isDefault: true,
        onPressed: () => Navigator.pop(context, true),
        child: Text(context.l10n.setupOpenSettings),
      ),
    ],
  ),
);

ThemeData _theme(bool mornye) =>
    mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light();

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required bool mornye,
  required void Function(BuildContext context) onOpen,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: _theme(mornye),
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

/// What the dialog shows and how its actions are configured and laid out.
List<Object?> _dialogSnapshot(WidgetTester tester) {
  final dialog = tester.widget<AppAlertDialog>(find.byType(AppAlertDialog));
  final actions = find.byType(AppDialogAction);
  return [
    (dialog.title as Text?)?.data,
    (dialog.content as Text?)?.data,
    tester.getRect(find.byType(AppAlertDialog)),
    for (final (index, action)
        in tester.widgetList<AppDialogAction>(actions).indexed)
      (
        (action.child as Text).data,
        action.isDefault,
        action.filled,
        action.isDestructive,
        action.outlined,
        action.style,
        tester.getRect(actions.at(index)),
      ),
    FocusManager.instance.primaryFocus?.debugLabel,
  ];
}

Future<(List<Object?>, Object?)> _runDialog<T>(
  WidgetTester tester, {
  required bool mornye,
  required Future<T> Function(BuildContext context) open,
  required Future<void> Function() close,
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
  await close();
  await tester.pumpAndSettle();
  expect(find.byType(AppAlertDialog), findsNothing);
  return (snapshot, result);
}

class _ChoiceCase {
  const _ChoiceCase(this.name, this.alignStart, this.bottomSpacing);

  final String name;
  final bool alignStart;
  final double bottomSpacing;
}

const _choices = [
  AppChoice('a', Icons.audiotrack, 'Alpha', subtitle: 'First'),
  AppChoice('b', Icons.graphic_eq, 'Beta'),
  AppChoice('c', Icons.album_outlined, 'Gamma', subtitle: 'Third'),
];

/// The per-site sheet the helper replaced, with that site's alignment and
/// trailing gap.
void _legacySheet(
  BuildContext context,
  _ChoiceCase shape,
  String selected,
  ValueChanged<String> onSelected,
) {
  showAppScrollableBottomSheet<void>(
    context: context,
    title: 'Pick',
    subtitle: 'One of three',
    builder: (sheetContext, controller) => SingleChildScrollView(
      controller: controller,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: shape.alignStart
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          for (final choice in _choices)
            AppSheetOption.choice(
              leading: AppIcon(choice.icon),
              title: Text(choice.title),
              subtitle: choice.subtitle == null ? null : Text(choice.subtitle!),
              selected: selected == choice.value,
              onTap: () {
                onSelected(choice.value);
                Navigator.pop(sheetContext);
              },
            ),
          if (shape.bottomSpacing > 0) SizedBox(height: shape.bottomSpacing),
        ],
      ),
    ),
  );
}

List<Object?> _sheetSnapshot(WidgetTester tester) {
  final options = find.byType(AppSheetOption);
  return [
    tester.getRect(find.byType(AppScrollableSheet)),
    tester.getRect(find.byType(SingleChildScrollView)),
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

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    group('showAppConfirmDialog ($style)', () {
      for (final (name, legacy, helper) in [
        (
          'discard changes',
          _legacyDiscard,
          (BuildContext context) => showDiscardChangesDialog(context),
        ),
        (
          'open settings',
          _legacyOpenSettings,
          (BuildContext context) => showAppConfirmDialog(
            context,
            title: context.l10n.setupStorageAccessRequired,
            message: context.l10n.allFilesAccessDeniedMessage,
            confirmLabel: context.l10n.setupOpenSettings,
            confirmIsDefault: true,
          ),
        ),
      ]) {
        testWidgets('$name matches the hand-written dialog', (tester) async {
          // Mornye lists the filled confirm action first.
          Finder action({required bool filled}) => find.byWidgetPredicate(
            (widget) => widget is AppDialogAction && widget.filled == filled,
          );
          final closes = <String, Future<void> Function()>{
            'confirm': () => tester.tap(action(filled: true)),
            'cancel': () => tester.tap(action(filled: false)),
            'barrier': () => tester.tapAt(const Offset(4, 4)),
          };
          for (final MapEntry(key: how, value: close) in closes.entries) {
            final (before, legacyResult) = await _runDialog(
              tester,
              mornye: mornye,
              open: legacy,
              close: close,
            );
            final (after, helperResult) = await _runDialog(
              tester,
              mornye: mornye,
              open: helper,
              close: close,
            );
            expect(after, before, reason: how);
            // Callers only acted on true; the helper reports null as false.
            expect(helperResult, legacyResult == true, reason: how);
          }
          expect(tester.takeException(), isNull);
        });
      }

      for (final flags in [
        (destructive: true, filled: true, cancel: true, confirm: false),
        (destructive: false, filled: true, cancel: false, confirm: true),
        (destructive: false, filled: false, cancel: false, confirm: false),
        (destructive: true, filled: false, cancel: false, confirm: true),
      ]) {
        testWidgets('maps $flags onto the two actions', (tester) async {
          final errorStyle = FilledButton.styleFrom(
            backgroundColor: Colors.red,
          );
          await _pumpLauncher(
            tester,
            mornye: mornye,
            onOpen: (context) => showAppConfirmDialog(
              context,
              title: 'Title',
              content: const Text('Body'),
              confirmLabel: 'Go',
              cancelLabel: 'Back',
              destructive: flags.destructive,
              filled: flags.filled,
              cancelIsDefault: flags.cancel,
              confirmIsDefault: flags.confirm,
              confirmStyle: errorStyle,
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final actions = {
            for (final action in tester.widgetList<AppDialogAction>(
              find.byType(AppDialogAction),
            ))
              (action.child as Text).data: action,
          };
          expect(actions.keys.toSet(), {'Back', 'Go'});
          final cancel = actions['Back']!;
          final confirm = actions['Go']!;
          expect(
            (cancel.isDefault, cancel.filled, cancel.isDestructive),
            (flags.cancel, false, false),
          );
          expect(cancel.style, isNull);
          expect(
            (confirm.isDefault, confirm.filled, confirm.isDestructive),
            (flags.confirm, flags.filled, flags.destructive),
          );
          expect(confirm.style, errorStyle);
          expect(find.text('Body'), findsOneWidget);
        });
      }

      for (final filled in [true, false]) {
        testWidgets('errorConfirm follows the dialog theme (filled=$filled)', (
          tester,
        ) async {
          final base = _theme(mornye);
          final theme = ValueNotifier(base);
          addTearDown(theme.dispose);
          await tester.pumpWidget(
            ProviderScope(
              child: ValueListenableBuilder(
                valueListenable: theme,
                builder: (context, data, _) => MaterialApp(
                  theme: data,
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => showAppConfirmDialog(
                          context,
                          title: 'Title',
                          confirmLabel: 'Go',
                          filled: filled,
                          errorConfirm: true,
                        ),
                        child: const Text('Open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          Color? errorColor() {
            final style = tester
                .widget<AppDialogAction>(
                  find.widgetWithText(AppDialogAction, 'Go'),
                )
                .style!;
            return (filled ? style.backgroundColor : style.foregroundColor)
                ?.resolve(const {});
          }

          expect(errorColor(), base.colorScheme.error);
          const changed = Color(0xFF00AA00);
          theme.value = base.copyWith(
            colorScheme: base.colorScheme.copyWith(error: changed),
          );
          await tester.pumpAndSettle();
          expect(errorColor(), changed);
        });
      }

      testWidgets('barrierDismissible false keeps the dialog open', (
        tester,
      ) async {
        bool? result;
        await _pumpLauncher(
          tester,
          mornye: mornye,
          onOpen: (context) async => result = await showAppConfirmDialog(
            context,
            title: 'Title',
            confirmLabel: 'Go',
            barrierDismissible: false,
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(find.byType(AppAlertDialog), findsOneWidget);
        await tester.tap(find.text('Go'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
      });
    });

    group('showAppChoiceSheet ($style)', () {
      for (final shape in const [
        _ChoiceCase('centered rows, 8 gap', false, 8),
        _ChoiceCase('start rows, 16 gap', true, 16),
        _ChoiceCase('start rows, no gap', true, 0),
      ]) {
        testWidgets('${shape.name} matches the hand-written sheet', (
          tester,
        ) async {
          Future<(List<Object?>, String?)> run(bool useHelper) async {
            String? picked;
            await _pumpLauncher(
              tester,
              mornye: mornye,
              onOpen: (context) => useHelper
                  ? showAppChoiceSheet(
                      context: context,
                      title: 'Pick',
                      subtitle: 'One of three',
                      selected: 'b',
                      choices: _choices,
                      bottomSpacing: shape.bottomSpacing,
                      onSelected: (value) => picked = value,
                    )
                  : _legacySheet(
                      context,
                      shape,
                      'b',
                      (value) => picked = value,
                    ),
            );
            await tester.tap(find.text('Open'));
            await tester.pumpAndSettle();
            final snapshot = _sheetSnapshot(tester);
            await tester.tap(find.text('Gamma'));
            await tester.pumpAndSettle();
            expect(find.byType(AppSheetOption), findsNothing);
            return (snapshot, picked);
          }

          final legacy = await run(false);
          final helper = await run(true);
          expect(helper.$1, legacy.$1);
          expect(helper.$2, 'c');
          expect(legacy.$2, 'c');
          expect(tester.takeException(), isNull);
        });
      }
    });

    testWidgets('settings groups keep their insets ($style)', (tester) async {
      for (final width in [390.0, 1400.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final reduceMotion in [false, true]) {
          for (final glass in [false, true]) {
            for (final rows in <List<Widget>>[
              [const SettingsItem(title: 'Row')],
              [const SizedBox(width: double.infinity, height: 40)],
            ]) {
              for (final margin in [null, const EdgeInsets.all(10)]) {
                await tester.pumpWidget(
                  ProviderScope(
                    child: MaterialApp(
                      theme: _theme(mornye),
                      home: MediaQuery(
                        data: MediaQueryData(
                          size: Size(width, 900),
                          disableAnimations: reduceMotion,
                        ),
                        child: Scaffold(
                          body: Align(
                            alignment: Alignment.topLeft,
                            child: SettingsGroup(
                              key: const ValueKey('group'),
                              glass: glass,
                              margin: margin,
                              children: rows,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                final outer = tester.getRect(
                  find.byKey(const ValueKey('group')),
                );
                final inset =
                    margin ??
                    EdgeInsets.symmetric(
                      horizontal: settingsHorizontalInset(width),
                      vertical: 4,
                    );
                final surface = find
                    .descendant(
                      of: find.byKey(const ValueKey('group')),
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is Padding && widget.padding == inset,
                      ),
                    )
                    .first;
                expect(tester.getRect(surface), outer);
                expect(outer.width, width);
              }
            }
          }
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye glass groups skip the backdrop pass', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: const Scaffold(
            body: Column(
              children: [
                MornyeGlassPanel(
                  key: ValueKey('panel'),
                  child: SizedBox(width: 200, height: 40),
                ),
                SettingsGroup(
                  glass: true,
                  children: [SettingsItem(title: 'Row')],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    Color? fillOf(Finder glass) => tester
        .widgetList<DecoratedBox>(
          find.descendant(of: glass, matching: find.byType(DecoratedBox)),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((decoration) => decoration.color != null)
        .color;

    final group = find.descendant(
      of: find.byType(SettingsGroup),
      matching: find.byType(MornyeGlass),
    );
    final glass = tester.widget<MornyeGlass>(group);
    expect(glass.samplesBackdrop, isFalse);
    expect(
      find.descendant(
        of: find.byType(SettingsGroup),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(find.text('Row'), findsOneWidget);
    // Same tint as the default panel, without filtering the flat page.
    final panelGlass = find.descendant(
      of: find.byKey(const ValueKey('panel')),
      matching: find.byType(MornyeGlass),
    );
    expect(fillOf(group), isNotNull);
    expect(fillOf(group)!.a, lessThan(1));
    final panel = tester.widget<MornyeGlass>(panelGlass);
    expect(
      (glass.radius, glass.strongTint, glass.tintOpacity, glass.tintColor),
      (panel.radius, panel.strongTint, panel.tintOpacity, panel.tintColor),
    );
    expect(tester.takeException(), isNull);
  });

  test('settingsSectionSlivers pairs a header with its group', () {
    final rows = <Widget>[const SettingsItem(title: 'Row')];
    final slivers = settingsSectionSlivers(
      title: 'Section',
      connected: true,
      glass: true,
      children: rows,
    );
    expect(slivers, hasLength(2));
    final header = (slivers[0] as SliverToBoxAdapter).child!;
    final group = (slivers[1] as SliverToBoxAdapter).child! as SettingsGroup;
    expect((header as SettingsSectionHeader).title, 'Section');
    expect((group.connected, group.glass, group.margin), (true, true, null));
    expect(group.children, same(rows));
    final plain = settingsSectionSlivers(title: 'Section', children: const []);
    final plainGroup = (plain[1] as SliverToBoxAdapter).child! as SettingsGroup;
    expect((plainGroup.connected, plainGroup.glass), (false, false));
  });
}
