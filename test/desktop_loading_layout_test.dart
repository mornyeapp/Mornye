import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/extension_collection_screens.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PendingMetadata implements NativeBackendTransport {
  late NativeMessageListener listener;
  int? metadataId;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    if (method == 'getProviderMetadata') {
      metadataId = id;
    } else {
      scheduleMicrotask(
        () => listener(id, NativeMessageKind.result, utf8.encode('null')),
      );
    }
  }

  void complete() =>
      listener(metadataId!, NativeMessageKind.result, utf8.encode('{}'));

  @override
  void subscribe(int kind) {}
  @override
  void unsubscribe(int kind) {}
}

void main() {
  setUp(() {
    debugDesktopPlatformOverride = true;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
  });

  Future<void> mount(
    WidgetTester tester, {
    required bool mornye,
    required double width,
    required Widget child,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(2000, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1300),
                  textScaler: TextScaler.linear(textScale),
                  disableAnimations: true,
                ),
                child: Scaffold(body: child),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  for (final mornye in [false, true]) {
    for (final width in [600.0, 1100.0, 1800.0]) {
      for (final album in [false, true]) {
        testWidgets(
          'desktop loading matches table at $width, Mornye=$mornye, album=$album',
          (tester) async {
            final albumLayout = album && mornye;
            final textScale = width == 600 ? 2.0 : 1.0;
            await mount(
              tester,
              mornye: mornye,
              width: width,
              textScale: textScale,
              child: Builder(
                builder: (context) => CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: wideListInset(context),
                      ),
                      sliver: SliverTrackTable(
                        albumLayout: albumLayout,
                        albumArtist: 'Artist',
                        rows: [
                          for (var index = 0; index < 2; index++)
                            TrackTableRow(
                              id: '$index',
                              number: index + 1,
                              title: 'Track $index',
                              artist: 'Artist',
                              album: 'Album',
                              quality: '24-bit/96kHz',
                              duration: const Duration(minutes: 3),
                              leading: album
                                  ? null
                                  : const SizedBox.square(dimension: 32),
                              trailing: const SizedBox(width: 32, height: 32),
                            ),
                        ],
                        columns: [
                          TrackTableColumn.number,
                          TrackTableColumn.title,
                          TrackTableColumn.artist,
                          if (!album) TrackTableColumn.album,
                          if (album) TrackTableColumn.quality,
                          TrackTableColumn.duration,
                        ],
                        selectedIds: const {},
                        onSelect: (_, _, _) {},
                        onActivate: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            );
            Rect loadedRow(int index) => tester.getRect(
              find
                  .ancestor(
                    of: find.text('Track $index'),
                    matching: find.byType(InkWell),
                  )
                  .first,
            );
            final first = loadedRow(0);
            final rowPitch = loadedRow(1).top - first.top;
            final titleLeft = tester.getTopLeft(find.text('Track 0')).dx;
            expect(tester.takeException(), isNull);

            await mount(
              tester,
              mornye: mornye,
              width: width,
              textScale: textScale,
              child: album
                  ? const AlbumTrackListSkeleton(
                      itemCount: 2,
                      showCoverHeader: true,
                      showQuality: true,
                    )
                  : const TrackListSkeleton(
                      itemCount: 2,
                      showCoverHeader: true,
                    ),
            );
            final placeholder = tester.getRect(
              find.byKey(const ValueKey('track-table-skeleton-row-0')),
            );
            expect(placeholder.height, closeTo(rowPitch, 0.1));
            expect(placeholder.center.dy, closeTo(first.center.dy, 0.1));
            if (!albumLayout) {
              final title = find.byKey(
                const ValueKey('track-table-skeleton-0-title'),
              );
              final titleBox = find
                  .descendant(of: title, matching: find.byType(SkeletonBox))
                  .last;
              expect(tester.getTopLeft(titleBox).dx, closeTo(titleLeft, 0.1));
            }
            // Cover placeholders belong to the real desktop header, so a
            // phone-sized duplicate must not push the rows down while loading.
            expect(placeholder.top, lessThan(60));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }

      testWidgets('artist loading fits scaled text at $width, Mornye=$mornye', (
        tester,
      ) async {
        await mount(
          tester,
          mornye: mornye,
          width: width,
          textScale: 2,
          child: const ArtistScreenSkeleton(showCoverHeader: false),
        );
        final context = tester.element(find.byType(ArtistScreenSkeleton));
        final side = artistAlbumTileSize(context);
        final covers = find.byWidgetPredicate(
          (widget) =>
              widget is SkeletonBox &&
              widget.width == side &&
              widget.height == side,
        );
        expect(covers, findsWidgets);
        expect(tester.getSize(covers.first), Size.square(side));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('collection loading keeps one desktop header, Mornye=$mornye', (
      tester,
    ) async {
      final pending = _PendingMetadata();
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: () => pending,
        loadConfig: () async => const DesktopBackendConfig(
          appSupportDir: '/support',
          documentsDir: '/documents',
          tempDir: '/tmp',
        ),
      );
      await PlatformBridge.clearTrackCache();
      await mount(
        tester,
        mornye: mornye,
        width: 900,
        child: ExtensionAlbumScreen(
          extensionId: 'example-metadata',
          albumId: 'loading-$mornye',
          albumName: 'Album',
        ),
      );
      expect(pending.metadataId, isNotNull);
      expect(find.text('Album'), findsWidgets);
      expect(
        find.byKey(const ValueKey('track-table-skeleton-row-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
