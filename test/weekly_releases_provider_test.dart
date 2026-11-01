import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/services/platform_bridge.dart';

class _Collections extends LibraryCollectionsNotifier {
  _Collections(this.initial);
  final LibraryCollectionsState initial;

  @override
  LibraryCollectionsState build() => initial;

  void publish(
    LibraryCollectionsState Function(LibraryCollectionsState) update,
  ) => state = update(state);
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.initial);
  final ExtensionState initial;

  @override
  ExtensionState build() => initial;

  void publish(ExtensionState Function(ExtensionState) update) =>
      state = update(state);
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(searchProvider: 'provider-a');

  void publish(AppSettings Function(AppSettings) update) =>
      state = update(state);
}

CollectionArtistEntry _artist(String id, {String? providerId = 'provider-a'}) =>
    CollectionArtistEntry(
      key: '${providerId ?? 'legacy'}:$id',
      artistId: id,
      providerId: providerId,
      name: id,
      addedAt: DateTime(2026),
    );

Extension _extension(String id, {bool enabled = true}) => Extension(
  id: id,
  name: id,
  displayName: 'Example provider',
  version: '1.0.0',
  description: '',
  enabled: enabled,
  status: 'loaded',
  hasMetadataProvider: true,
  searchBehavior: const SearchBehavior(enabled: true),
);

({
  ProviderContainer container,
  _Collections collections,
  _Extensions extensions,
  _Settings settings,
})
_scope({bool loaded = true, bool initialized = true}) {
  final collections = _Collections(
    LibraryCollectionsState(
      isLoaded: loaded,
      favoriteArtists: [_artist('first')],
    ),
  );
  final extensions = _Extensions(
    ExtensionState(
      isInitialized: initialized,
      extensions: [_extension('provider-a'), _extension('provider-b')],
    ),
  );
  final settings = _Settings();
  final container = ProviderContainer(
    overrides: [
      libraryCollectionsProvider.overrideWith(() => collections),
      extensionProvider.overrideWith(() => extensions),
      settingsProvider.overrideWith(() => settings),
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    collections: collections,
    extensions: extensions,
    settings: settings,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var metadataCalls = 0;
  Completer<void>? started;
  Completer<void>? response;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    metadataCalls = 0;
    started = null;
    response = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clearTrackCache') return null;
      final arguments = call.arguments as Map;
      if (call.method == 'customSearchWithExtension') {
        return [
          {'id': arguments['query'], 'name': arguments['query']},
        ];
      }
      expect(call.method, 'getProviderMetadata');
      metadataCalls++;
      if (started?.isCompleted == false) started!.complete();
      await response?.future;
      return {
        'albums': [
          {
            'id': arguments['resource_id'],
            'name': 'Example release',
            'release_date': '2026-10-02',
          },
        ],
      };
    });
    await PlatformBridge.clearTrackCache();
  });

  tearDown(() async {
    await PlatformBridge.clearTrackCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final refresh in [false, true]) {
    test(
      'unrelated publications keep the same feed (refresh=$refresh)',
      () async {
        final scope = _scope();
        final container = scope.container;
        final provider = weeklyReleasesProvider(refresh);
        started = Completer<void>();
        response = Completer<void>();
        addTearDown(() {
          if (!response!.isCompleted) response!.complete();
        });
        final subscription = container.listen(provider, (_, _) {});
        addTearDown(subscription.close);
        final future = container.read(provider.future);
        await started!.future.timeout(const Duration(seconds: 5));
        final favorites = container
            .read(libraryCollectionsProvider)
            .favoriteArtists;
        final extensions = container.read(extensionProvider).extensions;

        Future<void> publishUnrelated() async {
          for (final publish in <void Function()>[
            () => scope.collections.publish(
              (s) => s.copyWith(
                playlists: [
                  UserPlaylistCollection(
                    id: 'example-playlist',
                    name: 'Example playlist',
                    createdAt: DateTime(2026),
                    updatedAt: DateTime(2026),
                    tracks: const [],
                  ),
                ],
              ),
            ),
            () => scope.collections.publish(
              (s) => s.copyWith(
                loved: [
                  CollectionTrackEntry(
                    key: 'example-track',
                    track: const Track(
                      id: 'example-track',
                      name: 'Example track',
                      artistName: 'Example artist',
                      albumName: 'Example album',
                      duration: 180,
                    ),
                    addedAt: DateTime(2026),
                  ),
                ],
              ),
            ),
            () => scope.extensions.publish(
              (s) => s.copyWith(
                healthStatuses: {
                  'provider-a': ExtensionHealthStatus(
                    status: 'healthy',
                    checkedAt: DateTime(2026),
                  ),
                },
              ),
            ),
            () => scope.extensions.publish((s) => s.copyWith(isLoading: true)),
            () => scope.extensions.publish(
              (s) => s.copyWith(error: 'Example error'),
            ),
            () => scope.extensions.publish((s) => s.copyWith(isLoading: false)),
            () => scope.settings.publish(
              (s) => s.copyWith(downloadDirectory: '/example'),
            ),
          ]) {
            publish();
            await container.pump();
            expect(
              container.read(libraryCollectionsProvider).favoriteArtists,
              same(favorites),
            );
            expect(
              container.read(extensionProvider).extensions,
              same(extensions),
            );
            expect(container.read(provider.future), same(future));
          }
        }

        await publishUnrelated();
        response!.complete();
        final feed = await future;
        expect(feed.releases.single.id, 'first');
        await publishUnrelated();
        // Result identity catches recomputation even when either cache hides calls.
        expect(await container.read(provider.future), same(feed));
        expect(metadataCalls, 1);
      },
    );
  }

  for (final collectionsFirst in [false, true]) {
    test(
      'waits for both readiness flags (collections first=$collectionsFirst)',
      () async {
        final scope = _scope(loaded: false, initialized: false);
        final container = scope.container;
        final provider = weeklyReleasesProvider(false);
        final subscription = container.listen(provider, (_, _) {});
        addTearDown(subscription.close);
        expect((await container.read(provider.future)).releases, isEmpty);
        void loadCollections() =>
            scope.collections.publish((s) => s.copyWith(isLoaded: true));
        void initializeExtensions() =>
            scope.extensions.publish((s) => s.copyWith(isInitialized: true));
        (collectionsFirst ? loadCollections : initializeExtensions)();
        expect((await container.read(provider.future)).releases, isEmpty);
        expect(metadataCalls, 0);
        (collectionsFirst ? initializeExtensions : loadCollections)();
        expect(
          (await container.read(provider.future)).releases.single.id,
          'first',
        );
        expect(metadataCalls, 1);
      },
    );
  }

  test('favorites reload and auto-disposal retains the daily cache', () async {
    final scope = _scope();
    final container = scope.container;
    final provider = weeklyReleasesProvider(false);
    final subscription = container.listen(provider, (_, _) {});
    await container.read(provider.future);
    scope.collections.publish(
      (s) => s.copyWith(favoriteArtists: [_artist('second')]),
    );
    final future = container.read(provider.future);
    expect((await future).releases.single.id, 'second');
    expect(metadataCalls, 2);
    subscription.close();
    await container.pump();
    expect(container.exists(provider), isFalse);
    // Remove bridge caching so only the weekly catalog cache can satisfy this.
    await PlatformBridge.clearTrackCache();
    final restored = container.listen(provider, (_, _) {});
    addTearDown(restored.close);
    expect(container.read(provider.future), isNot(same(future)));
    expect(
      (await container.read(provider.future)).releases.single.id,
      'second',
    );
    expect(metadataCalls, 2);
    scope.collections.publish((s) => s.copyWith(favoriteArtists: []));
    expect((await container.read(provider.future)).releases, isEmpty);
  });

  test(
    'extension list and search preference reload legacy favorites',
    () async {
      final scope = _scope();
      final container = scope.container;
      container.read(libraryCollectionsProvider);
      scope.collections.publish(
        (s) =>
            s.copyWith(favoriteArtists: [_artist('legacy', providerId: null)]),
      );
      final provider = weeklyReleasesProvider(true);
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      expect(
        (await container.read(provider.future)).releases.single.providerId,
        'provider-a',
      );
      scope.settings.publish((s) => s.copyWith(searchProvider: 'provider-b'));
      expect(
        (await container.read(provider.future)).releases.single.providerId,
        'provider-b',
      );
      scope.extensions.publish(
        (s) => s.copyWith(
          extensions: [
            _extension('provider-a'),
            _extension('provider-b', enabled: false),
          ],
        ),
      );
      expect(
        (await container.read(provider.future)).releases.single.providerId,
        'provider-a',
      );
      scope.extensions.publish((s) => s.copyWith(extensions: []));
      final unavailable = await container.read(provider.future);
      expect(unavailable.unavailableArtists, ['legacy']);
      expect(unavailable.releases.single.providerId, 'provider-a');
    },
  );
}
