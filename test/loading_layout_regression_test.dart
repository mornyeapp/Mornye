import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/screens/repo_tab.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/extension_row.dart';
import 'package:mornye/widgets/settings_group.dart';

class _LoadingRepo extends RepoNotifier {
  @override
  RepoState build() => const RepoState(
    isLoading: true,
    isInitialized: true,
    registryUrls: ['https://example.invalid/registry.json'],
  );

  @override
  Future<void> initialize(String cacheDir) async {}
}

/// The filled row surfaces under [skeleton], top to bottom.
List<(Rect, BoxDecoration)> _filledRows(WidgetTester tester, Type skeleton) {
  final context = tester.element(find.byType(skeleton));
  final fill = settingsGroupColor(context);
  return [
    for (final element
        in find
            .descendant(
              of: find.byType(skeleton),
              matching: find.byType(DecoratedBox),
            )
            .evaluate())
      if ((element.widget as DecoratedBox).decoration
          case final BoxDecoration decoration when decoration.color == fill)
        (tester.getRect(find.byWidget(element.widget)), decoration),
  ];
}

void main() {
  for (final skeleton in const <Widget>[
    TrackListSkeleton(itemCount: 3),
    AlbumTrackListSkeleton(itemCount: 3),
    ArtistScreenSkeleton(showCoverHeader: false),
  ]) {
    testWidgets('${skeleton.runtimeType} rows are one connected filled run', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        // Light, where a placeholder box is darker than the row fill.
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: skeleton),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final rows = _filledRows(tester, skeleton.runtimeType);
      expect(rows.length, skeleton is ArtistScreenSkeleton ? 5 : 3);
      // Inset from the page edge, 2dp apart, large corners at the ends only.
      final context = tester.element(find.byType(skeleton.runtimeType));
      final outer = Radius.circular(context.tokens.radiusCard);
      for (final (index, (rect, decoration)) in rows.indexed) {
        expect(rect.left, 16);
        expect(rect.right, 400 - 16);
        if (index > 0) expect(rect.top - rows[index - 1].$1.bottom, 2);
        final radius = decoration.borderRadius! as BorderRadius;
        expect(radius.topLeft == outer, index == 0);
        expect(radius.bottomLeft == outer, index == rows.length - 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [320.0, 1024.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('Material loading rows fit at $width in $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final skeleton in const [
          TrackListSkeleton(itemCount: 3),
          AlbumTrackListSkeleton(itemCount: 3),
          HomeSearchSkeleton(),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.light
                  ? AppTheme.light()
                  : AppTheme.dark(),
              home: Scaffold(body: skeleton),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    for (final mornye in [false, true]) {
      testWidgets('store skeleton fits at $width with Mornye=$mornye', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          paths,
          (_) async => '/tmp/mornye-loading-test',
        );
        addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repoProvider.overrideWith(_LoadingRepo.new)],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const RepoTab(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(ExtensionRow), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
