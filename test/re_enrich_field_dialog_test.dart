import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/cover_image_picker.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/re_enrich_field_dialog.dart';

const _coverPath = '/picked/cover.png';

Widget _app(Widget child, {required bool mornye}) => ProviderScope(
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style Set common values picks, shows and returns a cover', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final covers = MetadataCoverResources();
      var picks = 0;
      ReEnrichFieldSelection? result;
      await tester.pumpWidget(
        _app(
          mornye: mornye,
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async {
                result = await showReEnrichFieldDialog(
                  context,
                  selectedCount: 3,
                  covers: covers,
                  pickCover: (owner) async {
                    expect(owner, same(covers));
                    picks++;
                    return (
                      preview: const MetadataCoverPreview(
                        path: _coverPath,
                        tempDir: '/picked',
                      ),
                      name: 'front.png',
                    );
                  },
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('Open'));
      await _tap(tester, find.text('Set common values'));

      expect(find.text('Cover Art'), findsOneWidget);
      expect(find.text('Pick Cover'), findsOneWidget);
      final review = find.widgetWithText(AppActionButton, 'Review changes');
      expect(tester.widget<AppActionButton>(review).onPressed, isNull);

      await _tap(tester, find.text('Pick Cover'));
      expect(picks, 1);
      expect(find.text('front.png'), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).imageProvider, isA<FileImage>());
      expect(
        ((image.image as ResizeImage).imageProvider as FileImage).file.path,
        _coverPath,
      );
      expect(tester.widget<AppActionButton>(review).onPressed, isNotNull);

      // Clearing takes the cover back out, and nothing is left to apply.
      await _tap(
        tester,
        mornye
            ? find.byIcon(CupertinoIcons.xmark_circle_fill)
            : find.byWidgetPredicate(
                (widget) =>
                    widget is AppIconButton &&
                    widget.tooltip == 'Clear selected cover',
              ),
      );
      expect(find.text('front.png'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.widget<AppActionButton>(review).onPressed, isNull);

      await _tap(tester, find.text('Pick Cover'));
      await _tap(tester, find.text('Review changes'));
      expect(result?.mode, ReEnrichBatchMode.manualValues);
      expect(result?.manualCoverPath, _coverPath);
      expect(result?.manualValues, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a cover is not offered without an owner for the file', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        mornye: false,
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () => showReEnrichFieldDialog(context, selectedCount: 2),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await _tap(tester, find.text('Open'));
    await _tap(tester, find.text('Set common values'));
    expect(find.text('Pick Cover'), findsNothing);
    expect(find.text('Genre'), findsWidgets);
  });

  testWidgets('a cover chosen before switching modes is not returned', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ReEnrichFieldSelection? result;
    Future<PickedCoverImage?> picker(MetadataCoverResources _) async => (
      preview: const MetadataCoverPreview(path: _coverPath, tempDir: '/x'),
      name: 'front.png',
    );
    await tester.pumpWidget(
      _app(
        mornye: false,
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              result = await showReEnrichFieldDialog(
                context,
                selectedCount: 2,
                covers: MetadataCoverResources(),
                pickCover: picker,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await _tap(tester, find.text('Open'));
    await _tap(tester, find.text('Set common values'));
    await _tap(tester, find.text('Pick Cover'));
    await _tap(tester, find.text('ISRC only'));
    await _tap(tester, find.text('Review changes'));
    expect(result?.mode, ReEnrichBatchMode.isrcOnly);
    expect(result?.manualCoverPath, isNull);
  });
}
