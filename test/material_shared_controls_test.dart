import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_checkbox.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_menu_button.dart';
import 'package:mornye/widgets/app_text_field.dart';

Widget _host(Widget child, {ThemeData? theme, bool reduceMotion = false}) =>
    ProviderScope(
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Center(child: SizedBox(width: 360, child: child)),
        ),
      ),
    );

AppMenuButton<String> _menu({ValueChanged<String>? onSelected}) =>
    AppMenuButton(
      icon: const Icon(Icons.more_vert),
      tooltip: 'Options',
      items: const [AppMenuItem(value: 'choose', label: 'Choose item')],
      onSelected: onSelected ?? (_) {},
    );

void main() {
  testWidgets('provider menu anchors fit their icon and dropdown arrow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppMenuButton<String>(
          icon: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 20),
              SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 16),
            ],
          ),
          tooltip: 'Provider',
          items: const [AppMenuItem(value: 'one', label: 'Provider one')],
          onSelected: (_) {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Provider'));
    await tester.pumpAndSettle();
    expect(find.text('Provider one', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('popup retains the anchor theme above a nested navigator', (
    tester,
  ) async {
    final localTheme = AppTheme.dark().copyWith(
      colorScheme: AppTheme.dark().colorScheme.copyWith(
        primary: const Color(0xff95ed72),
      ),
    );
    await tester.pumpWidget(
      _host(
        Theme(
          data: localTheme,
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(body: Center(child: _menu())),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    final popup = find.byWidgetPredicate(
      (widget) => widget is M3EMenuPopup<Object>,
    );
    expect(popup, findsOneWidget);
    final colors = M3ETheme.of(tester.element(popup)).colorScheme;
    expect(colors.brightness, Brightness.dark);
    expect(colors.primary, localTheme.colorScheme.primary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop popup keeps only its own scrollbar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      _host(
        AppMenuButton<String>(
          icon: const Icon(Icons.search),
          tooltip: 'Provider',
          items: [
            for (var i = 0; i < 12; i++)
              AppMenuItem(value: '$i', label: 'Provider $i'),
          ],
          onSelected: (_) {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Provider'));
    await tester.pumpAndSettle();
    final popup = find.byWidgetPredicate(
      (widget) => widget is M3EMenuPopup<Object>,
    );
    expect(
      find.descendant(of: popup, matching: find.byType(RawScrollbar)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: popup, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing an anchor also removes its open popup', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => show ? _menu() : const SizedBox.shrink(),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((widget) => widget is M3EMenuPopup<Object>),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('popup selects once and can reopen after dismissal', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(_menu(onSelected: selected.add)));
    await tester.tap(find.byTooltip('Options'));
    await tester.tap(find.byTooltip('Options'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((widget) => widget is M3EMenuPopup<Object>),
      findsOneWidget,
    );
    await tester.tap(find.text('Choose item', findRichText: true));
    await tester.pumpAndSettle();
    expect(selected, ['choose']);
    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(selected, ['choose']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text fields adopt a replacement controller and validate it', (
    tester,
  ) async {
    final first = TextEditingController();
    final second = TextEditingController(text: 'New playlist');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final form = GlobalKey<FormState>();
    Widget content(TextEditingController controller) => _host(
      Form(
        key: form,
        child: AppTextField(
          controller: controller,
          validator: (value) => value!.isEmpty ? 'Required' : null,
        ),
      ),
    );
    await tester.pumpWidget(content(first));
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    await tester.pumpWidget(content(second));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller,
      same(second),
    );
    expect(form.currentState!.validate(), isTrue);
    second.clear();
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final externalController in [false, true]) {
    testWidgets(
      'form reset restores visible text (external=$externalController)',
      (tester) async {
        final controller = externalController
            ? TextEditingController(text: 'Initial')
            : null;
        addTearDown(() => controller?.dispose());
        final form = GlobalKey<FormState>();
        await tester.pumpWidget(
          _host(
            Form(
              key: form,
              child: AppTextField(
                controller: controller,
                validator: (value) => value!.isEmpty ? 'Required' : null,
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(EditableText), 'Changed');
        await tester.pumpAndSettle();
        form.currentState!.reset();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          externalController ? 'Initial' : '',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('URL input preserves autocorrect and keyboard reveal options', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AppTextField(
          autocorrect: false,
          keyboardType: TextInputType.url,
          scrollPadding: EdgeInsets.only(bottom: 120),
        ),
      ),
    );
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.autocorrect, isFalse);
    expect(editable.scrollPadding, const EdgeInsets.only(bottom: 120));
  });

  for (final variant in ['expressive', 'reduced', 'mornye']) {
    testWidgets(
      'playlist dialog validates and submits with the keyboard ($variant)',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final form = GlobalKey<FormState>();
        String? result;
        await tester.pumpWidget(
          _host(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showAppDialog<String>(
                    context: context,
                    builder: (context) {
                      void submit() {
                        if (form.currentState!.validate()) {
                          Navigator.pop(context, controller.text.trim());
                        }
                      }

                      return AppAlertDialog(
                        title: const Text('Playlist name'),
                        content: Form(
                          key: form,
                          child: AppTextField(
                            controller: controller,
                            autofocus: true,
                            textInputAction: TextInputAction.done,
                            validator: (value) =>
                                value!.trim().isEmpty ? 'Required' : null,
                            onSubmitted: (_) => submit(),
                          ),
                        ),
                        actions: [
                          AppDialogAction(
                            onPressed: submit,
                            child: const Text('Create'),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: const Text('Open playlist'),
              ),
            ),
            theme: variant == 'mornye'
                ? MornyeTheme.build(Brightness.dark)
                : null,
            reduceMotion: variant == 'reduced',
          ),
        );
        await tester.tap(find.text('Open playlist'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Required', findRichText: true), findsOneWidget);
        await tester.enterText(find.byType(EditableText), ' My playlist ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(result, 'My playlist');
        expect(find.byType(AppAlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Mornye cards honor explicit margins and press callbacks', (
    tester,
  ) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(
      _host(
        AppContentCard(
          margin: const EdgeInsets.all(12),
          onTap: () => taps++,
          onLongPress: () => longPresses++,
          child: const SizedBox(height: 60, child: Text('Press card')),
        ),
        theme: MornyeTheme.build(Brightness.dark),
      ),
    );
    expect(tester.getSize(find.byType(AppContentCard)).height, 84);
    await tester.tap(find.text('Press card'));
    await tester.longPress(find.text('Press card'));
    expect(taps, 1);
    expect(longPresses, 1);
  });

  for (final reduced in [false, true]) {
    testWidgets('checkbox row and control toggle once (reduced=$reduced)', (
      tester,
    ) async {
      var value = false;
      var changes = 0;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => AppCheckboxListTile(
              value: value,
              title: const Text('Select field'),
              onChanged: (next) => setState(() {
                value = next!;
                changes++;
              }),
            ),
          ),
          reduceMotion: reduced,
        ),
      );
      await tester.tap(find.text('Select field'));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      final control = reduced
          ? find.byType(Checkbox)
          : find.byType(M3ECheckbox);
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(value, isFalse);
      expect(changes, 2);
      expect(tester.takeException(), isNull);
    });
  }
}
