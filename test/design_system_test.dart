import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/app_icon_finder.dart';

/// Every Dart source file under `lib/`, used by the source-level contracts
/// below. Those contracts exist because the duplication they guard against was
/// re-introduced by copy-paste several times before the shared widgets landed.
List<File> _libSources() {
  return Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();
}

String _basename(File file) => file.uri.pathSegments.last;

class _IconButtonTooltipVisitor extends RecursiveAstVisitor<void> {
  _IconButtonTooltipVisitor({
    required this.file,
    required this.lineInfo,
    required this.offenders,
  });

  final File file;
  final LineInfo lineInfo;
  final List<String> offenders;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (const {
      'IconButton',
      'AppIconButton',
    }.contains(node.constructorName.type.name.lexeme)) {
      final hasTooltip = node.argumentList.arguments.any(
        (argument) =>
            argument is NamedArgument && argument.name.lexeme == 'tooltip',
      );
      if (!hasTooltip) {
        final line = lineInfo.getLocation(node.offset).lineNumber;
        offenders.add('${file.path}:$line');
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

Widget _hostSliver(Widget sliver) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: CustomScrollView(slivers: [sliver])),
  );
}

void main() {
  group('AppTokens', () {
    test('is registered on both themes', () {
      expect(AppTheme.light().extension<AppTokens>(), AppTokens.standard);
      expect(AppTheme.dark().extension<AppTokens>(), AppTokens.standard);
      expect(
        AppTheme.dark(isAmoled: true).extension<AppTokens>(),
        AppTokens.standard,
      );
      expect(
        MornyeTheme.build(Brightness.light).extension<AppTokens>(),
        MornyeTheme.tokens,
      );
      expect(
        MornyeTheme.build(Brightness.dark).colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
      );
    });

    testWidgets(
      'Mornye keeps a font family and Cupertino tracking in text roles',
      (tester) async {
        final theme = MornyeTheme.build(Brightness.light);
        final apple = theme.platform == TargetPlatform.iOS;
        for (final role in [
          theme.textTheme.bodyLarge,
          theme.textTheme.bodyMedium,
          theme.textTheme.titleMedium,
          theme.textTheme.titleSmall,
          theme.textTheme.labelLarge,
          theme.textTheme.labelSmall,
        ]) {
          expect(role?.fontFamily, apple ? 'CupertinoSystemText' : 'Inter');
          expect(role?.letterSpacing, lessThan(0));
        }
        expect(
          theme.textTheme.headlineLarge?.fontFamily,
          apple ? 'CupertinoSystemDisplay' : 'Inter',
        );
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );

    testWidgets('context.tokens falls back to the standard scale', (
      tester,
    ) async {
      AppTokens? seen;
      await tester.pumpWidget(
        MaterialApp(
          // A bare ThemeData registers no extension; widgets must still work.
          theme: ThemeData(),
          home: Builder(
            builder: (context) {
              seen = context.tokens;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(seen, AppTokens.standard);
    });

    test('lerp interpolates the scale instead of snapping', () {
      const other = AppTokens.standard;
      final doubled = other.copyWith(radiusCard: 40);
      final mid = other.lerp(doubled, 0.5);

      expect(mid.radiusCard, (other.radiusCard + 40) / 2);
    });

    test('badge text stays legible', () {
      // 9-10px badge labels were the accessibility floor violation this token
      // was introduced to fix.
      expect(AppTokens.standard.badgeFontSize, greaterThanOrEqualTo(11));
    });

    test('minimum touch target matches the Material floor', () {
      expect(AppTokens.standard.minTouchTarget, 48);
    });
  });

  group('accessibility contracts', () {
    test('every IconButton has a tooltip-backed accessible name', () {
      final offenders = <String>[];
      for (final file in _libSources()) {
        final result = parseFile(
          path: file.absolute.path,
          featureSet: FeatureSet.latestLanguageVersion(),
        );
        result.unit.accept(
          _IconButtonTooltipVisitor(
            file: file,
            lineInfo: result.lineInfo,
            offenders: offenders,
          ),
        );
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Icon-only controls must expose a tooltip so TalkBack, VoiceOver, '
            'keyboard users, and pointer users receive the same action name.',
      );
    });

    testWidgets('selection actions expose their label and disabled state', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: SelectionActionButton(
                  icon: Icons.delete,
                  label: 'Delete selected tracks',
                  onPressed: null,
                  colorScheme: AppTheme.light().colorScheme,
                ),
              ),
            ),
          ),
        );

        expect(
          tester.getSemantics(find.byType(SelectionActionButton)),
          matchesSemantics(
            label: 'Delete selected tracks',
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
        );
        expect(
          tester.getSize(find.byType(SelectionActionButton)).height,
          greaterThanOrEqualTo(AppTokens.standard.minTouchTarget),
        );
      } finally {
        semantics.dispose();
      }
    });
  });

  group('AppSearchField', () {
    for (final direction in TextDirection.values) {
      testWidgets(
        'glass theme selector preserves logical selection in $direction',
        (tester) async {
          var selected = 0;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: MornyeTheme.build(Brightness.light),
                home: Scaffold(
                  body: Directionality(
                    textDirection: direction,
                    child: StatefulBuilder(
                      builder: (context, setState) => MornyeSegmentedControl(
                        labels: const ['System', 'Light', 'Dark'],
                        selectedIndex: selected,
                        onChanged: (index) => setState(() => selected = index),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          final systemX = tester.getCenter(find.text('System').first).dx;
          final darkX = tester.getCenter(find.text('Dark').first).dx;
          expect(systemX < darkX, direction == TextDirection.ltr);
          // The package puts a transparent tap layer above the drawn labels.
          await tester.tapAt(tester.getCenter(find.text('Dark').first));
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          expect(selected, 2);
          await tester.tapAt(tester.getCenter(find.text('System').first));
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          expect(selected, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('theme selector skips the glass tab bar with reduced motion', (
      tester,
    ) async {
      var selected = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => MornyeSegmentedControl(
                    labels: const ['System', 'Light', 'Dark'],
                    selectedIndex: selected,
                    onChanged: (index) => setState(() => selected = index),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).duration,
        Duration.zero,
      );
      expect(find.text('Dark'), findsOneWidget);
      await tester.tap(find.text('Dark'));
      await tester.pump();
      expect(selected, 2);
      expect(
        tester.getCenter(find.text('System')).dx <
            tester.getCenter(find.text('Dark')).dx,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('glass search keeps text editing, submit and clear usable', (
      tester,
    ) async {
      final controller = TextEditingController();
      final changes = <String>[];
      String? submitted;
      var cleared = false;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            home: Scaffold(
              body: AppSearchField(
                controller: controller,
                hintText: 'Search library',
                clearTooltip: 'Clear search',
                onChanged: changes.add,
                onSubmitted: (value) => submitted = value,
                onClear: () => cleared = true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(MornyeGlass), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Album');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(changes, ['Album']);
      expect(submitted, 'Album');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(cleared, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('uses the shared filled search style and clears input', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'quality');
      var cleared = false;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AppSearchField(
              controller: controller,
              hintText: 'Search settings',
              clearTooltip: 'Clear',
              onChanged: (_) {},
              onClear: () => cleared = true,
            ),
          ),
        ),
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      final border = field.decoration!.enabledBorder! as OutlineInputBorder;

      expect(field.decoration!.filled, isTrue);
      expect(border.borderRadius.topLeft.x, AppTokens.standard.radiusSheet);
      expect(findAppIcon(Icons.clear), findsOneWidget);

      await tester.tap(findAppIcon(Icons.clear));
      await tester.pump();

      expect(controller.text, isEmpty);
      expect(cleared, isTrue);
    });
  });

  group('Now Playing actions', () {
    test('uses the app bottom sheet instead of a platform popup menu', () {
      final source = File(
        'lib/screens/now_playing_screen.dart',
      ).readAsStringSync();

      expect(source, contains('showAppBottomSheet<String>'));
      expect(source, isNot(contains('PopupMenuButton')));
    });
  });

  group('CoverPalette', () {
    test(
      'local cache identity changes when artwork is replaced in place',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'mornye-cover-palette-',
        );
        final file = File('${directory.path}/cover.jpg');
        try {
          file.writeAsBytesSync(const [1, 2, 3]);
          file.setLastModifiedSync(DateTime.utc(2026, 1, 1));
          final before = await CoverPalette.cacheKeyFor(
            file.path,
            Brightness.dark,
          );

          file.writeAsBytesSync(const [4, 5, 6, 7]);
          file.setLastModifiedSync(DateTime.utc(2026, 1, 2));
          final after = await CoverPalette.cacheKeyFor(
            file.path,
            Brightness.dark,
          );

          expect(after, isNot(before));
        } finally {
          directory.deleteSync(recursive: true);
        }
      },
    );
  });

  group('AlbumDetailHeader', () {
    testWidgets('keeps iOS toolbar controls clear of the screen edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: CustomScrollView(
              slivers: const [
                AlbumDetailHeader(
                  title: 'Album',
                  expandedHeight: 500,
                  showTitleInAppBar: false,
                  background: ColoredBox(color: Colors.orange),
                  appBarActions: [SizedBox.square(dimension: 48)],
                ),
              ],
            ),
          ),
        ),
      );

      final appBar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(appBar.leadingWidth, kToolbarHeight + 12);
      expect(appBar.actionsPadding, const EdgeInsetsDirectional.only(end: 12));
      final leadingPadding = appBar.leading! as Padding;
      expect(
        leadingPadding.padding,
        const EdgeInsetsDirectional.only(start: 12),
      );
    });
  });

  group('AppSliverHeader', () {
    testWidgets('tab root variant shows the title without a back button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _hostSliver(const AppSliverHeader.tabRoot(title: 'Library')),
      );

      expect(find.text('Library'), findsOneWidget);
      expect(findAppIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('page variant shows a back button that pops the route', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      body: CustomScrollView(
                        slivers: [AppSliverHeader.page(title: 'Downloads')],
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Downloads'), findsOneWidget);

      await tester.tap(findAppIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('Downloads'), findsNothing);
    });

    testWidgets('expanded title uses the shared type ramp', (tester) async {
      await tester.pumpWidget(
        _hostSliver(const AppSliverHeader.tabRoot(title: 'Home')),
      );

      final style = tester.widget<Text>(find.text('Home')).style!;
      expect(style.fontSize, AppTokens.standard.headerExpandedTitleSize);
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets(
        'collapsed page title clears leading control on ${platform.name}',
        (tester) async {
          final controller = ScrollController();
          addTearDown(controller.dispose);
          final topInset = platform == TargetPlatform.iOS ? 59.0 : 24.0;

          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light().copyWith(platform: platform),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(430, 932),
                  padding: EdgeInsets.only(top: topInset),
                ),
                child: Scaffold(
                  body: CustomScrollView(
                    controller: controller,
                    slivers: const [
                      AppSliverHeader.page(title: 'Metadata'),
                      SliverToBoxAdapter(child: SizedBox(height: 1200)),
                    ],
                  ),
                ),
              ),
            ),
          );

          controller.jumpTo(AppTokens.standard.headerExpandedHeight);
          await tester.pump();

          final title = find.text('Metadata');
          final backIcon = findAppIcon(Icons.arrow_back);
          expect(
            tester.getRect(title).overlaps(tester.getRect(backIcon)),
            isFalse,
          );
          expect(
            tester.widget<Text>(title).style?.fontSize,
            AppTokens.standard.headerCollapsedTitleSize,
          );
        },
      );
    }

    test('is the only collapsing header implementation left', () {
      final offenders = _libSources()
          .where(
            (file) =>
                file.readAsStringSync().contains('expandedTitleScale') &&
                _basename(file) != 'app_sliver_header.dart',
          )
          .map(_basename)
          .toList();

      expect(
        offenders,
        isEmpty,
        reason:
            'Collapsing headers must go through AppSliverHeader so the type '
            'ramp cannot fork again.',
      );
    });
  });

  group('AppBottomSheet', () {
    testWidgets('supplies one handle plus the title block', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAppBottomSheet<void>(
                  context: context,
                  title: 'Open on',
                  subtitle: 'Track - Artist',
                  builder: (_) => const Text('body'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(AppSheetHandle), findsOneWidget);
      expect(find.text('Open on'), findsOneWidget);
      expect(find.text('Track - Artist'), findsOneWidget);
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('sheet shape comes from the token scale', (tester) async {
      final shape =
          AppTheme.light().bottomSheetTheme.shape! as RoundedRectangleBorder;
      final radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;

      expect(radius, AppTokens.standard.radiusSheet);
    });

    test('no screen hand-rolls a drag handle any more', () {
      final handlePattern = RegExp(
        r'height:\s*4,[\s\S]{0,200}?BorderRadius\.circular\(2\)',
      );
      final offenders = _libSources()
          .where(
            (file) =>
                handlePattern.hasMatch(file.readAsStringSync()) &&
                _basename(file) != 'app_bottom_sheet.dart',
          )
          .map(_basename)
          .toList();

      expect(
        offenders,
        isEmpty,
        reason: 'Use AppSheetHandle instead of rebuilding the pill.',
      );
    });

    test('no call site overrides the modal sheet shape', () {
      final shapeOverride = RegExp(
        r'shape:\s*(?:const\s+)?RoundedRectangleBorder\(\s*borderRadius:\s*'
        r'(?:const\s+)?BorderRadius\.vertical\(',
      );
      final offenders = _libSources()
          .where(
            (file) =>
                shapeOverride.hasMatch(file.readAsStringSync()) &&
                _basename(file) != 'app_theme.dart',
          )
          .map(_basename)
          .toList();

      expect(
        offenders,
        isEmpty,
        reason:
            'Sheet radius belongs to bottomSheetTheme, which reads '
            'AppTokens.radiusSheet.',
      );
    });
  });

  group('TrackCard', () {
    Widget host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

    testWidgets('lays out leading, title, subtitle and trailing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const TrackCard(
            leading: Icon(Icons.music_note),
            title: 'Song',
            subtitle: Text('Artist'),
            trailing: Icon(Icons.play_arrow),
          ),
        ),
      );

      expect(find.text('Song'), findsOneWidget);
      expect(find.text('Artist'), findsOneWidget);
      expect(findAppIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('selection mode swaps the trailing action for a tick', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const TrackCard(
            leading: Icon(Icons.music_note),
            title: 'Song',
            trailing: Icon(Icons.play_arrow),
            isSelectionMode: true,
            isSelected: true,
          ),
        ),
      );

      expect(findAppIcon(Icons.play_arrow), findsNothing);
      expect(findAppIcon(Icons.check), findsOneWidget);
    });

    testWidgets('flat style keeps the row transparent', (tester) async {
      await tester.pumpWidget(
        host(
          const TrackCard(
            leading: SizedBox.shrink(),
            title: 'Song',
            style: TrackCardStyle.flat,
          ),
        ),
      );

      final card = tester.widget<AppContentCard>(find.byType(AppContentCard));
      expect(card.color, Colors.transparent);
    });

    testWidgets('flat style keeps trailing actions near the card edge', (
      tester,
    ) async {
      const trailingKey = Key('flat-trailing');
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 320,
            child: TrackCard(
              leading: SizedBox(width: 24),
              title: 'Song',
              style: TrackCardStyle.flat,
              trailing: SizedBox(key: trailingKey, width: 48, height: 48),
            ),
          ),
        ),
      );

      final cardRect = tester.getRect(find.byType(AppContentCard));
      final trailingRect = tester.getRect(find.byKey(trailingKey));
      // The card's render box includes its 8dp flat-row margin; content is
      // inset another 6dp from the painted card edge.
      expect(cardRect.right - trailingRect.right, 14);
    });

    testWidgets('grid variant is a real button with a semantic label', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 160,
            child: TrackGridCard(
              cover: const ColoredBox(color: Colors.grey),
              title: 'Song',
              subtitle: const Text('Artist'),
              semanticLabel: 'Song by Artist',
              onTap: () => taps++,
            ),
          ),
        ),
      );

      // A bare GestureDetector gave no ripple and no semantics; the shared
      // card uses InkWell + Semantics instead.
      expect(find.byType(InkWell), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
    });

    testWidgets('grid play action keeps a compact visual and 48dp hit box', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          Align(
            child: TrackGridPlayButton(
              tooltip: 'Play Song by Artist',
              onPressed: () => taps++,
            ),
          ),
        ),
      );

      final action = find.byType(TrackGridPlayButton);
      final button = find.descendant(
        of: action,
        matching: find.byType(IconButton),
      );
      final visual = find.descendant(
        of: action,
        matching: find.byType(Container),
      );

      expect(tester.getSize(button), const Size.square(48));
      expect(
        tester.getSize(visual),
        const Size.square(TrackGridPlayButton.visualDiameter),
      );
      expect(tester.getBottomRight(visual), tester.getBottomRight(button));

      await tester.tap(button);
      expect(taps, 1);
    });
  });

  group('selection bar', () {
    test(
      'selection bars and menu popups use their dedicated overlay hosts',
      () {
        // Menus own their popup lifecycle; they are not selection bars.
        const overlayHosts = {
          'selection_bottom_bar.dart',
          'app_menu_button.dart',
        };
        final offenders = _libSources()
            .where(
              (file) =>
                  file.readAsStringSync().contains('OverlayEntry(') &&
                  !overlayHosts.contains(_basename(file)),
            )
            .map(_basename)
            .toList();

        expect(
          offenders,
          isEmpty,
          reason:
              'Selection bars must mount through SelectionOverlayController so '
              'they animate identically and clear the shell navigation bar.',
        );
      },
    );

    testWidgets('shell host keeps modal routes above the selection bar', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = SelectionOverlayController();
      addTearDown(controller.dispose);
      BuildContext? pageContext;
      var selectionTaps = 0;
      var sheetTaps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SelectionOverlayHost(
            child: Builder(
              builder: (context) {
                pageContext = context;
                return const Scaffold(body: SizedBox.expand());
              },
            ),
          ),
        ),
      );

      controller.show(
        pageContext!,
        (_) => GestureDetector(
          key: const ValueKey('selection-hit-target'),
          behavior: HitTestBehavior.opaque,
          onTap: () => selectionTaps++,
          child: const SizedBox(height: 200),
        ),
      );
      await tester.pumpAndSettle();

      final sheetClosed = showModalBottomSheet<void>(
        context: pageContext!,
        useRootNavigator: true,
        enableDrag: false,
        builder: (_) => GestureDetector(
          key: const ValueKey('sheet-hit-target'),
          behavior: HitTestBehavior.opaque,
          onTap: () => sheetTaps++,
          child: const SizedBox(height: 300),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sheet-hit-target')), findsOneWidget);
      expect(find.byKey(const ValueKey('selection-hit-target')), findsNothing);
      expect(selectionTaps, 0);
      expect(sheetTaps, 0);

      Navigator.of(pageContext!, rootNavigator: true).pop();
      await tester.pumpAndSettle();
      await sheetClosed;

      expect(
        find.byKey(const ValueKey('selection-hit-target')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('selection-hit-target')));
      await tester.pump();
      expect(selectionTaps, 1);
    });
  });

  group('CollectionScaffold', () {
    testWidgets('mounts the selection bar only while selecting', (
      tester,
    ) async {
      Widget host({required bool selecting}) => MaterialApp(
        theme: AppTheme.light(),
        home: CollectionScaffold(
          scrollController: ScrollController(),
          isSelectionMode: selecting,
          onExitSelectionMode: () {},
          bottomInset: 0,
          appBar: const SliverToBoxAdapter(child: SizedBox(height: 10)),
          slivers: const [SliverToBoxAdapter(child: Text('content'))],
          selectionBar: const Text('selection-bar'),
        ),
      );

      await tester.pumpWidget(host(selecting: false));
      await tester.pumpAndSettle();
      expect(find.text('selection-bar'), findsNothing);

      await tester.pumpWidget(host(selecting: true));
      await tester.pumpAndSettle();
      expect(find.text('selection-bar'), findsOneWidget);

      await tester.pumpWidget(host(selecting: false));
      await tester.pumpAndSettle();
      expect(find.text('selection-bar'), findsNothing);
    });

    testWidgets('reserves the measured height of a multi-row selection bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: CollectionScaffold(
            scrollController: ScrollController(),
            isSelectionMode: true,
            onExitSelectionMode: () {},
            bottomInset: 0,
            appBar: const SliverToBoxAdapter(child: SizedBox(height: 10)),
            slivers: const [SliverToBoxAdapter(child: Text('content'))],
            selectionBar: const SizedBox(height: 260),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .getSize(find.byKey(const ValueKey('collection-selection-spacer')))
            .height,
        260,
      );
    });

    test('every collection screen goes through the shared shell', () {
      const screens = [
        'album_screen.dart',
        'playlist_screen.dart',
        'local_album_screen.dart',
        'downloaded_album_screen.dart',
        'library_tracks_folder_screen.dart',
      ];
      final offenders = <String>[];
      for (final name in screens) {
        final file = _libSources().firstWhere(
          (candidate) => _basename(candidate) == name,
        );
        if (!file.readAsStringSync().contains('CollectionScaffold(')) {
          offenders.add(name);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Collection screens must share CollectionScaffold; hand-rolled '
            'Scaffold + PopScope + selection plumbing is what let the four '
            'album-style screens drift apart.',
      );
    });

    test('the playlist screen supports multi-select', () {
      final playlist = _libSources().firstWhere(
        (file) => _basename(file) == 'playlist_screen.dart',
      );
      final source = playlist.readAsStringSync();

      expect(source, contains('SelectionModeMixin<PlaylistScreen>'));
      expect(source, contains('SelectionBottomBar('));
      expect(source, contains('isSelectionMode: isSelectionMode'));
    });
  });

  group('settings components', () {
    testWidgets('choice chip meets the minimum touch target', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Row(
              children: [
                SettingsChoiceChip(
                  label: 'Stable',
                  isSelected: true,
                  onTap: () {},
                  expand: true,
                ),
              ],
            ),
          ),
        ),
      );

      final size = tester.getSize(find.byType(SettingsChoiceChip));
      expect(
        size.height,
        greaterThanOrEqualTo(AppTokens.standard.minTouchTarget),
      );
    });

    testWidgets('info card renders title, message and action', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SettingsInfoCard(
              icon: Icons.warning_amber_outlined,
              tone: SettingsInfoTone.error,
              title: 'Folder lost',
              message: 'Pick it again',
              action: TextButton(onPressed: () {}, child: const Text('Fix')),
            ),
          ),
        ),
      );

      expect(find.text('Folder lost'), findsOneWidget);
      expect(find.text('Pick it again'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
    });
  });
}
