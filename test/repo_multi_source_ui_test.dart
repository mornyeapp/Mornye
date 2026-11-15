import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/screens/repo/extension_details_screen.dart';
import 'package:mornye/screens/repo/repositories_screen.dart';
import 'package:mornye/screens/repo_tab.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

import 'support/tooltip_finder.dart';

const _first = 'https://example.com/registry.json';
const _second =
    'https://raw.githubusercontent.com/example/repo/main/registry.json';
const _third = 'https://example.com/third/registry.json';

RepoExtension _entry(String url, String name, String version) => RepoExtension(
  id: 'ext-a',
  name: 'ext-a',
  displayName: 'Example extension',
  version: version,
  description: 'An example',
  category: RepoCategory.utility,
  updatedAt: '',
  isInstalled: true,
  installedVersion: '1.0.0',
  registryUrl: url,
  registryName: name,
);

final _sources = [
  _entry(_first, 'Example One', '1.0.0'),
  _entry(_second, 'example/repo', '2.0.0'),
];

class _Repo extends RepoNotifier {
  _Repo({this.urls = const [_first, _second], this.missing = false});

  final List<String> urls;
  final bool missing;
  final removed = <String>[];
  final added = <String>[];
  final moved = <(String, String)>[];

  @override
  RepoState build() => RepoState(
    isInitialized: true,
    registryUrls: urls,
    sources: [
      if (urls.contains(_first))
        const RepoSource(
          registryUrl: _first,
          name: 'Example One',
          extensionCount: 3,
        ),
      if (urls.contains(_second))
        const RepoSource(
          registryUrl: _second,
          name: 'example/repo',
          error: 'Registry could not be reached',
        ),
    ],
    extensions: [
      missing
          ? _sources.first.copyWith(
              registryUrl: _third,
              registryName: 'Example Three',
              sourceMissing: true,
              sources: _sources,
            )
          : _sources.first.copyWith(sources: _sources),
    ],
  );

  @override
  Future<void> initialize(String cacheDir) async {}

  @override
  Future<void> refresh({bool forceRefresh = false}) async {}

  @override
  Future<void> removeRegistryUrl(String url) async {
    removed.add(url);
    state = state.copyWith(
      registryUrls: [
        for (final u in state.registryUrls)
          if (u != url) u,
      ],
    );
  }

  @override
  Future<RepoAddResult> addRegistryUrl(String url) async {
    if (state.registryUrls.contains(url)) {
      return RepoAddResult(RepoAddStatus.duplicate, registryUrl: url);
    }
    added.add(url);
    state = state.copyWith(registryUrls: [...state.registryUrls, url]);
    return RepoAddResult(RepoAddStatus.added, registryUrl: url);
  }

  @override
  Future<void> changeExtensionSource(String id, String url) async {
    moved.add((id, url));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    Widget app(_Repo repo, Widget home) => ProviderScope(
      overrides: [repoProvider.overrideWith(() => repo)],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

    testWidgets('$style repositories list, remove with confirmation', (
      tester,
    ) async {
      final repo = _Repo();
      await tester.pumpWidget(app(repo, const RepositoriesScreen()));
      await _settle(tester);

      expect(find.text('Example One'), findsOneWidget);
      expect(find.text(_first), findsOneWidget);
      expect(find.text('3 extensions'), findsOneWidget);
      expect(find.text('example/repo'), findsOneWidget);
      expect(find.text('Registry could not be reached'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('repository-$_second')),
          matching: findByTooltip('Remove repository'),
        ),
      );
      await _settle(tester);
      expect(find.textContaining('example/repo and its extensions'), findsOne);
      await tester.tap(find.text('Remove'));
      await _settle(tester);
      expect(repo.removed, [_second]);
      expect(find.byKey(const ValueKey('repository-$_second')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$style add repository rejects a duplicate and adds a new one',
      (tester) async {
        final repo = _Repo();
        await tester.pumpWidget(app(repo, const RepositoriesScreen()));
        await _settle(tester);

        Future<void> submit(String url) async {
          await tester.enterText(
            find.descendant(
              of: find.byKey(const ValueKey('repository-url-field')),
              matching: find.byType(EditableText),
            ),
            url,
          );
          await tester.tap(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.text('Add Repository'),
            ),
          );
          await _settle(tester);
        }

        await tester.tap(find.byKey(const ValueKey('repository-add')));
        await _settle(tester);
        await submit(_first);
        expect(find.text('This repository is already added'), findsOneWidget);
        expect(repo.added, isEmpty);

        await submit(_third);
        expect(repo.added, [_third]);
        expect(find.byType(Dialog), findsNothing);
        expect(
          find.byKey(const ValueKey('repository-$_third')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('$style store page moves an installed extension to another '
        'repository', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo();
      await tester.pumpWidget(
        app(repo, ExtensionDetailsScreen(extension: _sources.first)),
      );
      await _settle(tester);

      final row = find.byKey(const ValueKey('store-extension-repository'));
      expect(
        find.descendant(of: row, matching: find.text('Example One')),
        findsOneWidget,
      );
      await tester.tap(row);
      await _settle(tester);
      expect(find.text('Change repository'), findsOneWidget);
      expect(find.text('v2.0.0'), findsOneWidget);
      await tester.tap(find.text('example/repo').last);
      await _settle(tester);
      expect(repo.moved, [('ext-a', _second)]);
      expect(
        find.text('Example extension now updates from example/repo'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$style store page explains a repository that dropped the '
        'extension', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo(missing: true);
      await tester.pumpWidget(
        app(repo, ExtensionDetailsScreen(extension: _sources.first)),
      );
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('store-source-missing')),
        findsOneWidget,
      );
      final row = find.byKey(const ValueKey('store-extension-repository'));
      expect(
        find.descendant(of: row, matching: find.text('Example Three')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final urls in [
      [_first, _second],
      [_first],
    ]) {
      testWidgets('$style store rows name the repository only with several '
          '(${urls.length})', (tester) async {
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          paths,
          (_) async => '/tmp/mornye-repo-test',
        );
        addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
        final repo = _Repo(urls: urls);
        await tester.pumpWidget(app(repo, const RepoTab()));
        await _settle(tester);
        expect(find.text('Example extension'), findsOneWidget);
        expect(
          find.text('Example One'),
          urls.length > 1 ? findsOne : findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
