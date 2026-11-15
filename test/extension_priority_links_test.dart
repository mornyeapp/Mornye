import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/download_fallback_extensions_page.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/metadata_provider_priority_page.dart';
import 'package:mornye/screens/settings/provider_priority_page.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  _Extensions(this.extension);
  final Extension extension;

  @override
  ExtensionState build() =>
      ExtensionState(isInitialized: true, extensions: [extension]);
}

void main() {
  const extension = Extension(
    id: 'example.music',
    name: 'example.music',
    displayName: 'Example Music',
    version: '1.0.0',
    description: 'Example provider',
    enabled: true,
    status: 'loaded',
    hasDownloadProvider: true,
    hasMetadataProvider: true,
  );
  final rows = [
    ('Download Priority', 'Set download service order', ProviderPriorityPage),
    (
      'Metadata Priority',
      'Set search & metadata source order',
      MetadataProviderPriorityPage,
    ),
    (
      'Fallback Extensions',
      'Choose which installed download extensions can be used as fallback',
      DownloadFallbackExtensionsPage,
    ),
  ];
  for (final mornye in [false, true]) {
    for (final (enabled, download, metadata) in [
      (true, true, true),
      (false, true, true),
      (true, false, true),
      (true, true, false),
    ]) {
      for (final (title, subtitle, destination) in rows) {
        testWidgets('$title ($mornye, $enabled, $download, $metadata)', (
          tester,
        ) async {
          final available =
              enabled &&
              (destination == MetadataProviderPriorityPage
                  ? metadata
                  : download);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(FixedSettingsNotifier.new),
                extensionProvider.overrideWith(
                  () => _Extensions(
                    extension.copyWith(
                      enabled: enabled,
                      hasDownloadProvider: download,
                      hasMetadataProvider: metadata,
                    ),
                  ),
                ),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: SettingsSearchHighlightScope(
                  targetLabel: title,
                  child: const ExtensionsPage(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final target = find.byWidgetPredicate(
            (widget) => widget is SettingsSearchTarget && widget.label == title,
          );
          expect(target, findsOneWidget);
          expect(
            find.byKey(ValueKey('settings-highlight:$title')),
            findsOneWidget,
          );
          expect(find.text(title).hitTestable(), findsOneWidget);
          expect(
            find.descendant(
              of: target,
              matching: find.text(
                available
                    ? subtitle
                    : 'No extensions with ${destination == MetadataProviderPriorityPage ? 'metadata' : 'download'} provider',
              ),
            ),
            findsOneWidget,
          );
          final settingsItem = find.ancestor(
            of: target,
            matching: find.byType(SettingsItem),
          );
          // Both styles use the standard row, so the link lines up with the
          // other rows of its group.
          expect(settingsItem, findsOneWidget);
          final opacity = find.ancestor(
            of: settingsItem,
            matching: find.byType(Opacity),
          );
          expect(
            tester.widget<Opacity>(opacity.first).opacity,
            available ? 1 : 0.5,
          );
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
          expect(
            find.byType(destination),
            available ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(ExtensionsPage),
            available ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
