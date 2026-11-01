import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/explore_featured_section.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/l10n/app_localizations.dart';

import 'support/preference_blob_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('home feed cache ownership', () {
    late PreferenceBlobFixture blobs;
    setUp(() async => blobs = await PreferenceBlobFixture.create());
    tearDown(() => blobs.close());
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<
      ({
        ProviderContainer container,
        ExploreNotifier notifier,
        Completer<Map<String, Object?>> cache,
      })
    >
    pendingRestore() async {
      SharedPreferences.setMockInitialValues({
        'explore_home_feed_cache': jsonEncode(_feed('Cached')),
        'explore_home_feed_ts': DateTime.now()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      final cache = Completer<Map<String, Object?>>();
      final started = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_FeedSettings.new),
          extensionProvider.overrideWith(_FeedExtensions.new),
          exploreProvider.overrideWith(
            () => ExploreNotifier(
              decodeCache: (_) {
                started.complete();
                return cache.future;
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(exploreProvider.notifier);
      await started.future;
      return (container: container, notifier: notifier, cache: cache);
    }

    for (final disabled in [false, true]) {
      test('late cache cannot undo ${disabled ? 'Off' : 'Clear'}', () async {
        final restore = await pendingRestore();
        if (disabled) {
          (restore.container.read(settingsProvider.notifier) as _FeedSettings)
              .disableHomeFeed();
          await restore.notifier.fetchHomeFeed();
        } else {
          restore.notifier.clear();
        }
        restore.cache.complete(_feed('Cached'));
        await Future<void>.delayed(Duration.zero);
        final state = restore.container.read(exploreProvider);
        expect(state.hasContent, isFalse);
        expect(state.isLoading, isFalse);
      });
    }

    test('completed refresh wins over late cache', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getExtensionHomeFeed');
        return jsonEncode({
          'success': true,
          'sections': _feed('Fresh')['sections'],
        });
      });
      final restore = await pendingRestore();
      await restore.notifier.refresh();
      expect(
        restore.container.read(exploreProvider).sections.single.title,
        'Fresh',
      );
      restore.cache.complete(_feed('Cached'));
      await Future<void>.delayed(Duration.zero);
      expect(
        restore.container.read(exploreProvider).sections.single.title,
        'Fresh',
      );
    });

    test(
      'stale cache stays visible without duplicating the active refresh',
      () async {
        final response = Completer<String>();
        final started = Completer<void>();
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getExtensionHomeFeed');
          calls++;
          if (!started.isCompleted) started.complete();
          return response.future;
        });
        final restore = await pendingRestore();
        final refresh = restore.notifier.refresh();
        await started.future;
        restore.cache.complete(_feed('Cached'));
        await Future<void>.delayed(Duration.zero);
        final cached = restore.container.read(exploreProvider);
        expect(cached.sections.single.title, 'Cached');
        expect(cached.isLoading, isFalse);
        await restore.notifier.fetchHomeFeed();
        expect(calls, 1);
        response.complete(
          jsonEncode({'success': true, 'sections': _feed('Fresh')['sections']}),
        );
        await refresh;
        expect(
          restore.container.read(exploreProvider).sections.single.title,
          'Fresh',
        );
      },
    );
  });

  test('featured layout and artwork survive cache serialization', () {
    final section = ExploreSection.fromJson({
      'uri': 'featured',
      'title': 'New',
      'layout': 'featured',
      'items': [
        {
          'id': 'collection-1',
          'type': 'playlist',
          'name': 'Featured playlist',
          'cover_url': 'https://example.test/cover.jpg',
          'featured_cover_url': 'https://example.test/banner.jpg',
          'heading': 'Updated playlist',
          'provider_id': 'example-provider',
          'explicit': true,
        },
      ],
    });
    final restored = ExploreSection.fromJson(section.toJson());
    expect(restored.isFeatured, isTrue);
    expect(restored.items.single.heading, 'Updated playlist');
    expect(restored.items.single.featuredCoverUrl, endsWith('/banner.jpg'));
    expect(restored.items.single.coverUrl, endsWith('/cover.jpg'));
    expect(restored.items.single.providerId, 'example-provider');
    expect(restored.items.single.explicit, isTrue);
    expect(ExploreItem.fromJson({'explicit': false}).explicit, isFalse);
    expect(ExploreItem.fromJson({}).explicit, isNull);
    expect(ExploreSection.fromJson({'items': <Object?>[]}).isFeatured, isFalse);
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(320, 844), 2.0),
    (const Size(1024, 768), 1.0),
  ]) {
    testWidgets('featured cards scroll and open at $size, text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ExploreItem? opened;
      final items = List.generate(
        4,
        (index) => ExploreItem(
          id: 'collection-$index',
          uri: 'example:collection:$index',
          type: 'album',
          name: 'Featured $index',
          artists: 'Example artist',
          heading: 'New album',
          explicit: index == 0,
          description: 'An editorial description of the featured album.',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: ExploreFeaturedSection(
                  section: ExploreSection(
                    uri: 'featured',
                    title: 'New',
                    items: items,
                    isFeatured: true,
                  ),
                  onItemTap: (item, _) => opened = item,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ExplicitBadge), findsOneWidget);
      expect(
        tester
            .widget<ExplicitTrackTitle>(find.byType(ExplicitTrackTitle).first)
            .explicit,
        isTrue,
      );
      final firstTitle = find.byWidgetPredicate(
        (widget) =>
            widget is ExplicitTrackTitle && widget.title == 'Featured 0',
      );
      final card = find.ancestor(
        of: firstTitle,
        matching: find.byType(GestureDetector),
      );
      expect(tester.getSize(card).width, greaterThan(250));
      await tester.tap(firstTitle);
      expect(opened?.id, 'collection-0');
      await tester.drag(find.byType(ListView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Featured 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Map<String, Object?> _feed(String title) => {
  'provider_id': 'cache-race-provider',
  'sections': <Map<String, Object?>>[
    {'uri': 'example:feed', 'title': title, 'items': <Map<String, Object?>>[]},
  ],
};

class _FeedSettings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(homeFeedProvider: 'cache-race-provider');

  void disableHomeFeed() {
    state = state.copyWith(homeFeedProvider: AppSettings.homeFeedProviderOff);
  }
}

class _FeedExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'cache-race-provider',
        name: 'cache-race-provider',
        displayName: 'Cache race provider',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
        capabilities: {'homeFeed': true},
      ),
    ],
  );
}
