import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/repo/extension_details_screen.dart';
import 'package:mornye/screens/settings/extension_detail_page.dart';
import 'package:mornye/widgets/app_menu_button.dart';
import 'package:mornye/widgets/extension_icon_image.dart';

import 'support/fixed_settings.dart';

class _Repo extends RepoNotifier {
  @override
  RepoState build() => const RepoState(isInitialized: true);
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.iconPath);

  final String iconPath;

  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example.icon',
        name: 'example.icon',
        displayName: 'Example extension',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
        iconPath: iconPath,
        searchBehavior: const SearchBehavior(enabled: true),
      ),
    ],
  );
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

const _displays = [
  (size: 20.0, dpr: 1.0),
  (size: 20.0, dpr: 3.0),
  (size: 56.0, dpr: 1.0),
  (size: 56.0, dpr: 3.0),
  (size: 100.0, dpr: 1.0),
  (size: 100.0, dpr: 3.0),
  (size: 20.0, dpr: 1.13),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final network in [false, true]) {
    for (final scenario in [
      (
        name: 'wide',
        source: const Size(1024, 256),
        expected: const [
          Size(80, 20),
          Size(240, 60),
          Size(224, 56),
          Size(672, 168),
          Size(400, 100),
          Size(1024, 256),
          Size(92, 23),
        ],
      ),
      (
        name: 'tall',
        source: const Size(256, 1024),
        expected: const [
          Size(20, 80),
          Size(60, 240),
          Size(56, 224),
          Size(168, 672),
          Size(100, 400),
          Size(256, 1024),
          Size(23, 92),
        ],
      ),
      (
        name: 'square',
        source: const Size(1024, 1024),
        expected: const [
          Size(20, 20),
          Size(60, 60),
          Size(56, 56),
          Size(168, 168),
          Size(100, 100),
          Size(300, 300),
          Size(23, 23),
        ],
      ),
      (
        name: 'small',
        source: const Size(16, 4),
        expected: List.filled(7, const Size(16, 4)),
      ),
    ]) {
      testWidgets('${scenario.name} icon crop decodes, network=$network', (
        tester,
      ) async {
        final fixture = await tester.runAsync(
          () => _IconFixture.create(scenario.source, network: network),
        );
        final cache = PaintingBinding.instance.imageCache;
        try {
          for (final (index, display) in _displays.indexed) {
            cache.clear();
            cache.clearLiveImages();
            final provider = ExtensionIconImage(
              fixture!.provider,
              extent: (display.size * display.dpr).ceil(),
            );
            final decoded = await tester.runAsync(() async {
              await tester.pumpWidget(
                MaterialApp(
                  home: Center(
                    child: Image(
                      image: provider,
                      width: display.size,
                      height: display.size,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
              return _decodedSize(provider);
            });
            expect(decoded, scenario.expected[index]);
            expect(
              decoded!.width / decoded.height,
              scenario.source.width / scenario.source.height,
            );
            expect(
              cache.currentSizeBytes,
              (decoded.width * decoded.height * 4).toInt(),
            );
            expect(cache.currentSize, 1);
            expect(
              tester.getSize(find.byType(Image)),
              Size.square(display.size),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          cache.clear();
          cache.clearLiveImages();
          await tester.runAsync(fixture!.dispose);
        }
      });
    }

    testWidgets('icon cache follows density and source, network=$network', (
      tester,
    ) async {
      final fixture = await tester.runAsync(
        () => _IconFixture.create(const Size(1024, 256), network: network),
      );
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      try {
        final keys = <Object>[];
        for (final density in [1.0, 3.0, 1.0]) {
          final provider = ExtensionIconImage(
            fixture!.provider,
            extent: (56 * density).ceil(),
          );
          keys.add(await provider.obtainKey(ImageConfiguration.empty));
          final decoded = await tester.runAsync(() => _decodedSize(provider));
          expect(
            decoded,
            density == 1 ? const Size(224, 56) : const Size(672, 168),
          );
          expect(
            provider,
            ExtensionIconImage(fixture.provider, extent: (56 * density).ceil()),
          );
        }
        expect(keys[0], keys[2]);
        expect(keys[0].hashCode, keys[2].hashCode);
        expect(keys[0], isNot(keys[1]));
        final original = await fixture!.provider.obtainKey(
          ImageConfiguration.empty,
        );
        expect(keys[0] == original, isFalse);
        expect(original == keys[0], isFalse);
        final other = ExtensionIconImage(
          const NetworkImage('https://example.com/other-icon.png'),
          extent: 56,
        );
        expect(await other.obtainKey(ImageConfiguration.empty), isNot(keys[0]));
        expect(cache.currentSize, 2);
        expect(cache.currentSizeBytes, (224 * 56 + 672 * 168) * 4);
      } finally {
        cache.clear();
        cache.clearLiveImages();
        await tester.runAsync(fixture!.dispose);
      }
    });
  }

  testWidgets('Store icon keeps its crop and bounds through density changes', (
    tester,
  ) async {
    final fixture = await tester.runAsync(
      () => _IconFixture.create(const Size(1024, 256), network: true),
    );
    try {
      final keys = <Object>[];
      for (final density in [1.0, 3.0, 1.0]) {
        final decoded = await tester.runAsync(() async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [repoProvider.overrideWith(_Repo.new)],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(devicePixelRatio: density),
                  child: child!,
                ),
                home: ExtensionDetailsScreen(
                  extension: RepoExtension(
                    id: 'example.icon',
                    name: 'example.icon',
                    displayName: 'Example extension',
                    version: '1.0.0',
                    description: '',
                    iconUrl: (fixture!.provider as NetworkImage).url,
                    category: RepoCategory.utility,
                    updatedAt: '',
                  ),
                ),
              ),
            ),
          );
          final image = tester.widget<Image>(find.byType(Image));
          expect(image.fit, BoxFit.cover);
          expect(tester.getSize(find.byType(Image)), const Size(100, 100));
          keys.add(await image.image.obtainKey(ImageConfiguration.empty));
          return _decodedSize(image.image);
        });
        expect(
          decoded,
          density == 1 ? const Size(400, 100) : const Size(1024, 256),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      expect(keys[0], keys[2]);
      expect(keys[0], isNot(keys[1]));
    } finally {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.runAsync(fixture!.dispose);
    }
  });

  for (final home in [false, true]) {
    testWidgets('installed icons decode the crop at live density, Home=$home', (
      tester,
    ) async {
      final fixture = await tester.runAsync(
        () => _IconFixture.create(const Size(1024, 256), network: false),
      );
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getExtensionSettings' ? '{}' : null,
      );
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      try {
        final keys = <Object>[];
        for (final density in [1.0, 3.0, 1.0]) {
          await tester.runAsync(() async {
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  settingsProvider.overrideWith(FixedSettingsNotifier.new),
                  extensionProvider.overrideWith(
                    () =>
                        _Extensions((fixture!.provider as FileImage).file.path),
                  ),
                  if (home) ...[
                    exploreProvider.overrideWith(_Explore.new),
                    recentAccessProvider.overrideWith(_Recent.new),
                    downloadHistoryProvider.overrideWith(_History.new),
                  ],
                ],
                child: MaterialApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(devicePixelRatio: density),
                    child: child!,
                  ),
                  home: home
                      ? const Scaffold(body: HomeTab(mode: HomeTabMode.search))
                      : const ExtensionDetailPage(extensionId: 'example.icon'),
                ),
              ),
            );
          });
          await tester.pumpAndSettle();
          final size = home ? 20.0 : 56.0;
          Future<void> checkImages(int count) async {
            final images = tester
                .widgetList<Image>(find.byType(Image))
                .where((image) => image.image is ExtensionIconImage)
                .toList();
            expect(images, hasLength(count));
            for (final image in images) {
              expect(image.fit, BoxFit.cover);
              expect(image.width, size);
              expect(image.height, size);
              final decoded = await tester.runAsync(
                () => _decodedSize(image.image),
              );
              expect(
                decoded,
                home
                    ? (density == 1 ? const Size(80, 20) : const Size(240, 60))
                    : (density == 1
                          ? const Size(224, 56)
                          : const Size(672, 168)),
              );
              final key = await image.image.obtainKey(ImageConfiguration.empty);
              if (count == 1) {
                keys.add(key);
              } else {
                expect(key, keys.last);
              }
            }
          }

          await checkImages(1);
          if (home) {
            await tester.tap(find.byType(AppMenuButton<String>));
            await tester.pumpAndSettle();
            await checkImages(2);
            await tester.tapAt(const Offset(5, 5));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }
        expect(keys[0], keys[2]);
        expect(keys[0], isNot(keys[1]));
        expect(cache.currentSize, 2);
      } finally {
        await tester.pumpWidget(const SizedBox());
        cache.clear();
        cache.clearLiveImages();
        messenger.setMockMethodCallHandler(channel, null);
        await tester.runAsync(fixture!.dispose);
      }
    });
  }
}

class _IconFixture {
  _IconFixture(this.directory, this.provider, this.server, this.httpOverrides);

  final Directory directory;
  final ImageProvider<Object> provider;
  final HttpServer? server;
  final HttpOverrides? httpOverrides;

  static Future<_IconFixture> create(Size size, {required bool network}) async {
    final directory = await Directory.systemTemp.createTemp('extension-icon-');
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & size, Paint()..color = Colors.blue);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    final bytes = data!.buffer.asUint8List();
    final file = await File('${directory.path}/icon.png').writeAsBytes(bytes);
    final previous = HttpOverrides.current;
    if (!network) {
      return _IconFixture(directory, FileImage(file), null, previous);
    }
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(bytes);
      unawaited(request.response.close());
    });
    return _IconFixture(
      directory,
      NetworkImage('http://127.0.0.1:${server.port}/icon.png'),
      server,
      previous,
    );
  }

  Future<void> dispose() async {
    await server?.close(force: true);
    HttpOverrides.global = httpOverrides;
    await directory.delete(recursive: true);
  }
}

Future<Size> _decodedSize(ImageProvider<Object> provider) async {
  final result = Completer<Size>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, _) {
    if (!result.isCompleted) {
      result.complete(
        Size(info.image.width.toDouble(), info.image.height.toDouble()),
      );
    }
    info.dispose();
  }, onError: result.completeError);
  stream.addListener(listener);
  try {
    return await result.future.timeout(const Duration(seconds: 10));
  } finally {
    stream.removeListener(listener);
  }
}
