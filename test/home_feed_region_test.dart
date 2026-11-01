import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/explore_cache_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/home_feed_region_setting.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/preference_blob_fixture.dart';

const _extension = Extension(
  id: 'example.feed',
  name: 'example.feed',
  displayName: 'Example Music',
  version: '1.0.0',
  description: 'Regional recommendations',
  enabled: true,
  status: 'loaded',
  capabilities: {'homeFeed': true, 'homeFeedRegionSetting': 'market'},
  settings: [
    ExtensionSetting(
      key: 'market',
      label: 'Country',
      type: 'select',
      defaultValue: 'us',
      options: ['us', 'jp', 'gb'],
    ),
  ],
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(homeFeedProvider: 'example.feed');
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() =>
      const ExtensionState(extensions: [_extension], isInitialized: true);
}

class _ColdExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();

  @override
  Future<void> ensureInitialized() async {
    state = const ExtensionState(extensions: [_extension], isInitialized: true);
  }
}

Map<String, Object?> _feed(String region) => {
  'success': true,
  'provider_id': _extension.id,
  'region': region.toUpperCase(),
  'sections': [
    {
      'title': region,
      'items': [
        {
          'id': 'collection-$region',
          'type': 'album',
          'name': 'Music',
          'uri': 'https://example.test/$region/album',
        },
      ],
    },
  ],
};

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Home feed did not reach the expected country');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, dynamic> settings;
  late List<Map<String, dynamic>> writes;
  late bool failSave;
  Completer<String>? pendingFeed;
  late PreferenceBlobFixture blobs;

  setUp(() async {
    blobs = await PreferenceBlobFixture.create();
    SharedPreferences.setMockInitialValues({});
    settings = {'market': 'us', 'otherSetting': 'preserved'};
    writes = [];
    failSave = false;
    pendingFeed = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getExtensionSettings':
          return jsonEncode(settings);
        case 'setExtensionSettings':
          if (failSave) throw PlatformException(code: 'save_failed');
          settings = Map<String, dynamic>.from(
            jsonDecode((call.arguments as Map)['settings'] as String) as Map,
          );
          writes.add(Map.of(settings));
          return null;
        case 'getExtensionHomeFeed':
          final pending = pendingFeed;
          pendingFeed = null;
          return pending?.future ??
              jsonEncode(_feed(settings['market'] as String));
      }
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await blobs.close();
  });

  ProviderContainer container({bool coldStart = false}) {
    final result = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        extensionProvider.overrideWith(
          coldStart ? _ColdExtensions.new : _Extensions.new,
        ),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  test('region capability must reference declared country choices', () {
    expect(_extension.homeFeedRegionSetting?.key, 'market');
    expect(
      _extension
          .copyWith(
            settings: const [
              ExtensionSetting(
                key: 'market',
                label: 'Country',
                type: 'string',
                defaultValue: 'us',
                options: ['us', 'jp', 'gb'],
              ),
            ],
          )
          .homeFeedRegionSetting
          ?.type,
      'string',
    );
    for (final capabilities in [
      {'homeFeed': true},
      {'homeFeed': true, 'homeFeedRegionSetting': 'undeclared'},
      {'homeFeed': false, 'homeFeedRegionSetting': 'market'},
    ]) {
      expect(
        _extension.copyWith(capabilities: capabilities).homeFeedRegionSetting,
        isNull,
      );
    }
  });

  test(
    'saving country preserves settings and reloads the active feed',
    () async {
      final providers = container();
      final explore = providers.read(exploreProvider.notifier);
      await explore.fetchHomeFeed();
      expect(providers.read(exploreProvider).sections.single.title, 'us');
      expect(
        await providers
            .read(extensionProvider.notifier)
            .setHomeFeedRegion(_extension.id, 'jp'),
        isTrue,
      );
      await _until(
        () =>
            providers.read(exploreProvider).sections.firstOrNull?.title == 'jp',
      );
      expect(writes.single, {'market': 'jp', 'otherSetting': 'preserved'});
      final prefs = await SharedPreferences.getInstance();
      String? cached;
      for (var i = 0; i < 100; i++) {
        cached = (await ExploreCacheStore(prefs).read()).payload;
        if (cached?.contains('"JP"') == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cached, contains('"JP"'));
      expect(prefs.containsKey('explore_home_feed_cache'), isFalse);
    },
  );

  test(
    'late response from the previous country cannot replace the new feed',
    () async {
      final providers = container();
      final explore = providers.read(exploreProvider.notifier);
      final old = Completer<String>();
      pendingFeed = old;
      final request = explore.fetchHomeFeed();
      await _until(() => pendingFeed == null);
      await providers
          .read(extensionProvider.notifier)
          .setHomeFeedRegion(_extension.id, 'gb');
      await _until(
        () =>
            providers.read(exploreProvider).sections.firstOrNull?.title == 'gb',
      );
      old.complete(jsonEncode(_feed('us')));
      await request;
      expect(providers.read(exploreProvider).sections.single.title, 'gb');
    },
  );

  test(
    'cached Home from another country is not restored after relaunch',
    () async {
      SharedPreferences.setMockInitialValues({
        'explore_home_feed_cache': jsonEncode(_feed('us')),
        'explore_home_feed_ts': DateTime.now().millisecondsSinceEpoch,
      });
      settings['market'] = 'jp';
      final providers = container();
      providers.read(exploreProvider);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(providers.read(exploreProvider).hasContent, isFalse);
      await providers.read(exploreProvider.notifier).fetchHomeFeed();
      expect(providers.read(exploreProvider).sections.single.title, 'jp');
    },
  );

  test(
    'cached Home from the selected country is restored without fetching',
    () async {
      SharedPreferences.setMockInitialValues({
        'explore_home_feed_cache': jsonEncode(_feed('jp')),
        'explore_home_feed_ts': DateTime.now().millisecondsSinceEpoch,
      });
      settings['market'] = 'jp';
      final providers = container();
      providers.read(exploreProvider);
      await _until(() => providers.read(exploreProvider).hasContent);
      expect(providers.read(exploreProvider).sections.single.title, 'jp');
    },
  );

  test('regional cache waits for manifests on a cold launch', () async {
    SharedPreferences.setMockInitialValues({
      'explore_home_feed_cache': jsonEncode(_feed('jp')),
      'explore_home_feed_ts': DateTime.now().millisecondsSinceEpoch,
    });
    settings['market'] = 'jp';
    final providers = container(coldStart: true);
    providers.read(exploreProvider);
    await _until(() => providers.read(exploreProvider).hasContent);
    expect(providers.read(extensionProvider).isInitialized, isTrue);
    expect(providers.read(exploreProvider).sections.single.title, 'jp');
  });

  test(
    'failed saves and unsupported countries leave the current feed intact',
    () async {
      final providers = container();
      final explore = providers.read(exploreProvider.notifier);
      await explore.fetchHomeFeed();
      final extensions = providers.read(extensionProvider.notifier);
      expect(
        await extensions.setHomeFeedRegion(_extension.id, 'invalid'),
        isFalse,
      );
      failSave = true;
      expect(await extensions.setHomeFeedRegion(_extension.id, 'jp'), isFalse);
      expect(settings['market'], 'us');
      expect(providers.read(exploreProvider).sections.single.title, 'us');
      expect(providers.read(extensionProvider).settingsRevisions, isEmpty);
    },
  );

  for (final mornye in [false, true]) {
    testWidgets('country picker saves a country with either theme ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            extensionProvider.overrideWith(_Extensions.new),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) => AppScaffoldMessenger(child: child!),
            home: const Scaffold(
              body: SettingsGroup(children: [HomeFeedRegionSetting()]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('United States · Example Music'), findsOneWidget);
      await tester.tap(find.text('Home feed country'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Japan'));
      await tester.pumpAndSettle();
      expect(writes.single['market'], 'jp');
      expect(find.text('Japan · Example Music'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
