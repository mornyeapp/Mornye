import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _albums = [
  for (var i = 0; i < 5; i++)
    ArtistAlbum(
      id: 'album-$i',
      name: 'Album $i',
      releaseDate: '2020',
      totalTracks: 1,
      // A different shelf must not enter the range between albums 0 and 3.
      albumType: i == 1 ? 'single' : 'album',
      artists: 'Example Artist',
    ),
];

Future<void> _pumpArtist(
  WidgetTester tester, {
  required bool mornye,
  List<ArtistAlbum>? albums,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1200, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (_) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArtistScreen(
          artistId: 'example-artist',
          artistName: 'Example Artist',
          albums: albums ?? _albums,
          topTracks: const [
            Track(
              id: 'example-track',
              name: 'Example Track',
              artistName: 'Example Artist',
              albumName: 'Example Album',
              duration: 180,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _card(int index) => find.byKey(ValueKey('album-$index'));

Future<void> _click(
  WidgetTester tester,
  int index, {
  bool secondary = false,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(_card(index)),
    kind: PointerDeviceKind.mouse,
    buttons: secondary ? kSecondaryButton : kPrimaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void _expectSelection(WidgetTester tester, Set<int> selected) {
  expect(
    tester
        .widget<SelectionBottomBar>(find.byType(SelectionBottomBar))
        .selectedCount,
    selected.length,
  );
  for (var i = 0; i < _albums.length; i++) {
    final checkbox = find.descendant(
      of: _card(i),
      matching: find.byType(AnimatedSelectionCheckbox),
    );
    expect(
      tester.widget<AnimatedSelectionCheckbox>(checkbox).selected,
      selected.contains(i),
    );
  }
}

Future<void> _disposeArtist(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    debugDesktopPlatformOverride = null;
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      testWidgets(
        '$style $platform: modifier clicks select albums and keyboard clears them',
        (tester) async {
          debugDesktopPlatformOverride = true;
          await _pumpArtist(tester, mornye: mornye);
          final modifier = platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft;
          await tester.sendKeyDownEvent(modifier);
          await _click(tester, 0);
          await tester.sendKeyUpEvent(modifier);
          _expectSelection(tester, {0});

          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await _click(tester, 3);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          _expectSelection(tester, {0, 2, 3});

          await tester.sendKeyDownEvent(modifier);
          await _click(tester, 2);
          await tester.sendKeyUpEvent(modifier);
          _expectSelection(tester, {0, 3});

          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(modifier);
          await tester.pumpAndSettle();
          _expectSelection(tester, {0, 1, 2, 3, 4});

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(SelectionBottomBar), findsNothing);
          expect(find.byType(AnimatedSelectionCheckbox), findsNothing);
          await _disposeArtist(tester);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }

    testWidgets('$style: context menu starts lasting album selection', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      await _pumpArtist(tester, mornye: mornye);
      await _click(tester, 2, secondary: true);
      expect(find.byType(SelectionBottomBar), findsNothing);
      expect(find.byType(AnimatedSelectionCheckbox), findsNothing);
      expect(find.text('Select Albums...'), findsOneWidget);

      // Dismissing a temporary menu does not leave selection controls behind.
      await tester.tapAt(const Offset(10, 100));
      await tester.pumpAndSettle();
      expect(find.byType(SelectionBottomBar), findsNothing);
      await _click(tester, 2, secondary: true);
      await tester.tap(find.text('Select Albums...'));
      await tester.pumpAndSettle();
      _expectSelection(tester, {2});

      await _click(tester, 3);
      _expectSelection(tester, {2, 3});
      await _click(tester, 2, secondary: true);
      await tester.tapAt(const Offset(10, 100));
      await tester.pumpAndSettle();
      _expectSelection(tester, {2, 3});
      await _click(tester, 2);
      _expectSelection(tester, {3});
      await _disposeArtist(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('$style: selecting an album keeps the shelf scroll position', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      final albums = [
        for (var i = 0; i < 24; i++)
          ArtistAlbum(
            id: 'album-$i',
            name: 'Album $i',
            releaseDate: '2020',
            totalTracks: 1,
            albumType: 'album',
            artists: 'Example Artist',
          ),
      ];
      await _pumpArtist(tester, mornye: mornye, albums: albums);
      // Mornye's highlights row scrolls too; the albums are the last shelf.
      final shelf = find.byType(DesktopScrollArrows).last;
      final list = find.descendant(of: shelf, matching: find.byType(ListView));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(_card(2)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Scroll forward'));
      await tester.pumpAndSettle();
      final offset = tester.widget<ListView>(list).controller!.offset;
      expect(offset, greaterThan(0));
      // Select a card whose center is within the viewport after paging.
      final visible = [
        for (var i = 0; i < albums.length; i++)
          if (_card(i).evaluate().isNotEmpty &&
              tester.getRect(shelf).contains(tester.getCenter(_card(i))))
            i,
      ];
      final target = visible[visible.length ~/ 2];
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _click(tester, target);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(tester.widget<ListView>(list).controller!.offset, offset);
      expect(_card(target).hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<SelectionBottomBar>(find.byType(SelectionBottomBar))
            .selectedCount,
        1,
      );
      await _click(tester, target);
      expect(find.byType(SelectionBottomBar), findsNothing);
      expect(tester.widget<ListView>(list).controller!.offset, offset);
      expect(_card(target).hitTestable(), findsOneWidget);
      await _disposeArtist(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('$style: touch long press still selects albums', (
      tester,
    ) async {
      debugDesktopPlatformOverride = false;
      await _pumpArtist(tester, mornye: mornye);
      await tester.longPress(_card(2));
      await tester.pumpAndSettle();
      _expectSelection(tester, {2});
      await tester.tap(_card(3));
      await tester.pumpAndSettle();
      _expectSelection(tester, {2, 3});
      await _disposeArtist(tester);
    });

    testWidgets('$style: select all toggle clears but keeps selection mode', (
      tester,
    ) async {
      debugDesktopPlatformOverride = false;
      await _pumpArtist(tester, mornye: mornye);
      await tester.longPress(_card(2));
      await tester.pumpAndSettle();
      SelectionBottomBar bar() =>
          tester.widget<SelectionBottomBar>(find.byType(SelectionBottomBar));
      expect(bar().allSelected, isFalse);
      bar().onToggleSelectAll();
      await tester.pumpAndSettle();
      _expectSelection(tester, {0, 1, 2, 3, 4});
      expect(bar().allSelected, isTrue);
      bar().onToggleSelectAll();
      await tester.pumpAndSettle();
      _expectSelection(tester, {});
      expect(bar().allSelected, isFalse);
      await _disposeArtist(tester);
    });
  }
}
