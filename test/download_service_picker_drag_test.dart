import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/download_service_picker.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  _Extensions(
    this._qualityCount, {
    this.serviceCount = 1,
    this.hasHealth = false,
  });

  final int _qualityCount;
  final int serviceCount;
  final bool hasHealth;
  final healthRequests = <String>[];

  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      for (var service = 0; service < serviceCount; service++)
        Extension(
          id: service == 0 ? 'example' : 'example-$service',
          name: 'example',
          displayName: service == 0 ? 'Example' : 'Source $service',
          version: '1.0.0',
          description: '',
          enabled: true,
          status: 'loaded',
          hasDownloadProvider: true,
          serviceHealth: hasHealth
              ? const [ExtensionServiceHealthCheck()]
              : const [],
          qualityOptions: List.generate(
            _qualityCount,
            (index) => QualityOption(id: '$index', label: 'Quality $index'),
          ),
        ),
      if (hasHealth)
        const Extension(
          id: 'metadata-only',
          name: 'metadata-only',
          displayName: 'Metadata source',
          version: '1.0.0',
          description: '',
          enabled: true,
          status: 'loaded',
          hasMetadataProvider: true,
          serviceHealth: [ExtensionServiceHealthCheck()],
        ),
    ],
  );

  @override
  void refreshEnabledExtensionHealth({bool force = false}) {}

  void publishHealth(String id, String status) => state = state.copyWith(
    healthStatuses: {
      ...state.healthStatuses,
      id: ExtensionHealthStatus(status: status),
    },
  );

  @override
  Future<ExtensionHealthStatus?> checkExtensionHealth(
    String extensionId, {
    bool force = false,
  }) async {
    healthRequests.add(extensionId);
    return state.healthStatuses[extensionId];
  }
}

void main() {
  for (final (qualityCount, mornye) in [
    (3, false),
    (16, false),
    (3, true),
    (16, true),
  ]) {
    testWidgets(
      'picker fits $qualityCount options and dismisses (Mornye=$mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        (String, String)? selection;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              extensionProvider.overrideWith(() => _Extensions(qualityCount)),
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
            ],
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : ThemeData(platform: TargetPlatform.iOS),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => DownloadServicePicker.show(
                      context,
                      trackName: 'Example track',
                      onSelect: (quality, service) =>
                          selection = (quality, service),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        if (qualityCount == 3) {
          final sheetBottom = tester.getBottomLeft(find.byType(BottomSheet)).dy;
          final lastOptionBottom = tester
              .getBottomLeft(find.text('Quality 2'))
              .dy;
          expect(sheetBottom - lastOptionBottom, lessThan(100));
        }
        if (qualityCount == 16) {
          final scroll = find.descendant(
            of: find.byType(DownloadServicePicker),
            matching: find.byType(SingleChildScrollView),
          );
          await tester.drag(scroll, const Offset(0, -300));
          await tester.pumpAndSettle();
          expect(find.byType(DownloadServicePicker), findsOneWidget);
          await tester.drag(scroll, const Offset(0, 1500));
          await tester.pumpAndSettle();
        }
        final sheetTop = tester.getTopLeft(find.byType(BottomSheet));
        final sheetWidth = tester.getSize(find.byType(BottomSheet)).width;
        await tester.dragFrom(
          sheetTop + Offset(sheetWidth / 2, 16),
          const Offset(0, 600),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DownloadServicePicker), findsNothing);
        expect(selection, isNull);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final lastQuality = find.text('Quality ${qualityCount - 1}');
        await tester.ensureVisible(lastQuality);
        await tester.pumpAndSettle();
        await tester.tap(lastQuality);
        await tester.pumpAndSettle();
        expect(selection, ('${qualityCount - 1}', 'example'));
        expect(find.byType(DownloadServicePicker), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'source status stays local and checkmark space appears only on selection in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final extensions = _Extensions(3, serviceCount: 2, hasHealth: true);
        (String, String)? selection;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              extensionProvider.overrideWith(() => extensions),
              settingsProvider.overrideWith(FixedSettingsNotifier.new),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(brightness),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => DownloadServicePicker.show(
                      context,
                      trackName: 'Example track',
                      onSelect: (quality, service) =>
                          selection = (quality, service),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final qualityBefore = tester.widget(find.text('Quality 0'));
        expect(extensions.healthRequests, ['example', 'example-1']);
        final titleBefore = tester.widget(find.text('Example track'));
        final source1 = find.ancestor(
          of: find.text('Example'),
          matching: find.byType(CupertinoButton),
        );
        final source2 = find.ancestor(
          of: find.text('Source 1'),
          matching: find.byType(CupertinoButton),
        );
        final sourceRects = [tester.getRect(source1), tester.getRect(source2)];
        expect(
          tester.getTopLeft(find.text('Source 1')).dx - sourceRects[1].left,
          16,
        );
        extensions.publishHealth('example', 'offline');
        await tester.pumpAndSettle();
        expect(find.byTooltip('Service offline'), findsOneWidget);
        expect(
          identical(tester.widget(find.text('Quality 0')), qualityBefore),
          isTrue,
        );
        expect(
          identical(tester.widget(find.text('Example track')), titleBefore),
          isTrue,
        );
        expect([tester.getRect(source1), tester.getRect(source2)], sourceRects);
        await tester.tap(find.text('Example'));
        await tester.pumpAndSettle();
        expect(
          identical(tester.widget(find.text('Quality 0')), qualityBefore),
          isTrue,
        );
        expect(extensions.healthRequests, ['example', 'example-1']);
        await tester.tap(find.text('Source 1'));
        await tester.pumpAndSettle();
        expect(tester.getSize(source1).width, sourceRects[0].width - 26);
        expect(tester.getSize(source2).width, sourceRects[1].width + 26);
        expect(
          tester.getTopLeft(find.text('Source 1')).dx -
              tester.getTopLeft(source2).dx,
          42,
        );
        await tester.tap(find.text('Quality 1'));
        await tester.pumpAndSettle();
        expect(selection, ('1', 'example-1'));
        expect(find.byType(DownloadServicePicker), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
