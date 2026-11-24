import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Mornye loading layouts fit a narrow screen in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final skeleton in const [
        ArtistScreenSkeleton(showCoverHeader: false),
        AlbumTrackListSkeleton(showCoverHeader: true),
        TrackListSkeleton(showCoverHeader: true),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: MornyeTheme.build(brightness),
            home: Scaffold(body: skeleton),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -350),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'chrome follows the visible artist and restores for albums and tabs',
    (tester) async {
      final key = ShellNavigationService.homeTabNavigatorKey;
      final observer = ShellChromeObserver(key);
      ShellNavigationService.syncState(currentTabIndex: 0, showRepoTab: true);
      addTearDown(observer.detach);
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(Brightness.light),
          home: Navigator(
            key: key,
            observers: [observer],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, isNull);
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const MornyeArtistSurface(
            imageSource: null,
            child: Scaffold(body: Text('Artist')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, Brightness.dark);
      final artistSurface = Theme.of(
        tester.element(find.text('Artist')),
      ).colorScheme.surface;
      expect(ShellNavigationService.chromeSurface.value, artistSurface);

      // Menus do not turn the bars light over a dark artist.
      showDialog<void>(
        context: tester.element(find.text('Artist')),
        useRootNavigator: false,
        builder: (_) => const AlertDialog(title: Text('Options')),
      );
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, Brightness.dark);
      key.currentState!.pop();
      await tester.pumpAndSettle();

      // The mounted artist under a pushed album must not keep a stale override.
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Album')),
        ),
      );
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, isNull);
      expect(ShellNavigationService.chromeSurface.value, isNull);
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, Brightness.dark);
      expect(ShellNavigationService.chromeSurface.value, artistSurface);

      ShellNavigationService.syncState(currentTabIndex: 3, showRepoTab: true);
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, isNull);
      expect(ShellNavigationService.chromeSurface.value, isNull);
      ShellNavigationService.syncState(currentTabIndex: 0, showRepoTab: true);
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, Brightness.dark);
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(ShellNavigationService.chromeBrightness.value, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
