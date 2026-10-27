import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTransport implements NativeBackendTransport {
  _FakeTransport(this.handler);

  final Future<Object?> Function(MethodCall) handler;
  late NativeMessageListener listener;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    unawaited(() async {
      final args = jsonDecode(utf8.decode(argsJson));
      final result = await handler(MethodCall(method, args));
      listener(id, NativeMessageKind.result, utf8.encode(jsonEncode(result)));
    }());
  }

  @override
  void subscribe(int kind) {}

  @override
  void unsubscribe(int kind) {}
}

ArtistAlbum _album(String id, String date, {String type = 'album'}) =>
    ArtistAlbum(
      id: id,
      name: id,
      releaseDate: date,
      totalTracks: 1,
      albumType: type,
      artists: 'Example Artist',
      providerId: 'example-provider',
    );

const _topTracks = [
  Track(
    id: 'example-song',
    name: 'Example Song',
    artistName: 'Example Artist',
    albumName: 'Example Album',
    duration: 180,
  ),
];

Map<String, dynamic> _metadata(ArtistAlbum album) => {
  'id': album.id,
  'name': album.name,
  'release_date': album.releaseDate,
  'total_tracks': album.totalTracks,
  'album_type': album.albumType,
  'artists': album.artists,
};

Future<void> _pumpArtist(
  WidgetTester tester, {
  required bool desktop,
  required bool mornye,
  required String artistId,
  List<ArtistAlbum>? albums,
  Future<Object?> Function(MethodCall)? backend,
}) async {
  debugDesktopPlatformOverride = desktop;
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(
    desktop ? const Size(1200, 1600) : const Size(430, 932),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, backend ?? (_) async => null);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  if (desktop) {
    final transport = _FakeTransport(backend ?? (_) async => null);
    RustFfiBackend.debugShared = RustFfiBackend(
      openTransport: () => transport,
      loadConfig: () async => const DesktopBackendConfig(
        appSupportDir: '/support',
        documentsDir: '/documents',
        tempDir: '/tmp',
      ),
    );
  }
  await PlatformBridge.clearTrackCache();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ArtistScreen(
          artistId: artistId,
          artistName: 'Example Artist',
          extensionId: 'example-provider',
          albums: albums,
          topTracks: _topTracks,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('artist-albums')),
    240,
    scrollable: find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Finder _shelf(String section) => find.descendant(
  of: find.byKey(ValueKey('artist-$section')),
  matching: find.byType(ListView),
);

List<String> _shelfIds(WidgetTester tester, String section) {
  final shelf = _shelf(section);
  final delegate =
      tester.widget<ListView>(shelf).childrenDelegate
          as SliverChildBuilderDelegate;
  return [
    for (var i = 0; i < delegate.childCount!; i++)
      ((delegate.builder(tester.element(shelf), i) as KeyedSubtree).key!
              as ValueKey<String>)
          .value,
  ];
}

Future<void> _disposeArtist(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  await PlatformBridge.clearTrackCache();
}

void main() {
  tearDown(() {
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
  });

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      final variant =
          '${desktop ? 'desktop' : 'mobile'} '
          '${mornye ? 'Mornye' : 'Material'}';
      testWidgets('$variant: each artist shelf is newest first', (
        tester,
      ) async {
        await _pumpArtist(
          tester,
          desktop: desktop,
          mornye: mornye,
          artistId: 'supplied-$desktop-$mornye',
          albums: [
            _album('old-album', '2010'),
            _album('new-single', '2026-09', type: 'single'),
            _album('unknown-album', ''),
            _album('new-album', '2026-10-27'),
            _album('old-single', '2019-01-01', type: 'ep'),
            _album('middle-album', '2023-12-31'),
            _album('old-compilation', '2005', type: 'compilation'),
            _album('new-compilation', '2024', type: 'compilation'),
          ],
        );
        expect(_shelfIds(tester, 'albums'), [
          'new-album',
          'middle-album',
          'old-album',
          'unknown-album',
        ]);
        await tester.ensureVisible(
          find.byKey(const ValueKey('artist-singles')),
        );
        await tester.pumpAndSettle();
        expect(_shelfIds(tester, 'singles'), ['new-single', 'old-single']);
        await tester.ensureVisible(
          find.byKey(const ValueKey('artist-compilations')),
        );
        await tester.pumpAndSettle();
        expect(_shelfIds(tester, 'compilations'), [
          'new-compilation',
          'old-compilation',
        ]);
        await _disposeArtist(tester);
      });

      testWidgets('$variant: later pages merge by date without duplicates', (
        tester,
      ) async {
        final artistId = 'fetched-$desktop-$mornye';
        final next = '$artistId-page-2';
        final calls = <String>[];
        await _pumpArtist(
          tester,
          desktop: desktop,
          mornye: mornye,
          artistId: artistId,
          backend: (call) async {
            if (call.method != 'getProviderMetadata') return null;
            final args = call.arguments as Map<Object?, Object?>;
            final id = args['resource_id'] as String;
            calls.add(id);
            final albums = id == artistId
                ? [_album('old', '2010'), _album('middle', '2020')]
                : [_album('new', '2026'), _album('middle', '2020-12-31')];
            return {
              'albums': albums.map(_metadata).toList(),
              'artist_info': {'albums_next': id == artistId ? next : ''},
              'top_tracks': [
                {'id': 'example-song', 'name': 'Example Song'},
              ],
            };
          },
        );
        if (calls.length == 1) {
          expect(_shelfIds(tester, 'albums'), ['middle', 'old']);
          final shelf = _shelf('albums');
          final notification = ScrollUpdateNotification(
            metrics: FixedScrollMetrics(
              minScrollExtent: 0,
              maxScrollExtent: 100,
              pixels: 90,
              viewportDimension: 430,
              axisDirection: AxisDirection.right,
              devicePixelRatio: 1,
            ),
            context: tester.element(shelf),
            scrollDelta: 10,
          );
          tester
              .widget<NotificationListener<ScrollNotification>>(
                find
                    .descendant(
                      of: find.byKey(const ValueKey('artist-albums')),
                      matching: find.byType(
                        NotificationListener<ScrollNotification>,
                      ),
                    )
                    .first,
              )
              .onNotification!(notification);
          tester.binding.scheduleFrame();
          await tester.pump();
          await tester.pumpAndSettle();
        }
        expect(calls, [artistId, next]);
        expect(_shelfIds(tester, 'albums'), ['new', 'middle', 'old']);
        await _disposeArtist(tester);
      });
    }
  }
}
