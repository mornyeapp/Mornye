import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/lyrics_provider_picker.dart';

class _NoExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

void main() {
  test('previews drop timestamps, word timing and header tags', () {
    const lrc =
        '[ar:Example Artist]\n[ti:Example]\n\n'
        '[00:01.00]<00:01.00>First <00:01.50>line\n'
        '[00:02.00]Second line\n[00:03.00]Third line\n[00:04.00]Fourth';
    expect(lyricsPreviewLines(lrc), [
      'First line',
      'Second line',
      'Third line',
    ]);
    expect(lyricsPreviewLines(lrc, limit: -1), hasLength(4));

    // Singer marks and backing vocal groups stay out of the preview.
    const multiPerson =
        '[00:01.00]v1:<00:01.00>Lead line\n'
        '[bg:<00:01.20>Backing<00:01.80>]\n'
        '[00:02.00]v2:Answer line';
    expect(lyricsPreviewLines(multiPerson), ['Lead line', 'Answer line']);
  });

  test('results are classified by their timing', () {
    LyricsResultKind kind(Map<String, dynamic> result) =>
        LyricsProviderResult.fromBridge(result).kind;
    expect(
      kind({'lyrics': '[00:01.00]<00:01.00>Word', 'sync_type': 'LINE_SYNCED'}),
      LyricsResultKind.wordSynced,
    );
    expect(
      kind({'lyrics': '[00:01.00]Line', 'sync_type': 'LINE_SYNCED'}),
      LyricsResultKind.synced,
    );
    expect(
      kind({'lyrics': 'Line', 'sync_type': 'UNSYNCED'}),
      LyricsResultKind.plain,
    );
    expect(
      kind({'lyrics': '[instrumental:true]', 'instrumental': true}),
      LyricsResultKind.instrumental,
    );
    expect(kind({'lyrics': '[ar:Only tags]'}), LyricsResultKind.none);
  });

  for (final mornye in [false, true]) {
    testWidgets('lists each provider in order and returns the chosen lyrics '
        '(${mornye ? 'Mornye' : 'Material'})', (tester) async {
      final slow = Completer<Map<String, dynamic>>();
      String? chosen;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [extensionProvider.overrideWith(_NoExtensions.new)],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    chosen = await showLyricsProviderPicker(
                      context,
                      title: 'Song',
                      artist: 'Artist',
                      loadProviders: () async => [
                        'lrclib',
                        'netease',
                        'extension:example.lyrics',
                      ],
                      fetch: (provider) => switch (provider) {
                        'lrclib' => Future.value({
                          'lyrics': '[00:01.00]From LRCLIB',
                          'sync_type': 'LINE_SYNCED',
                        }),
                        'netease' => Future.error(
                          Exception('lyrics not found'),
                        ),
                        _ => slow.future,
                      },
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('LRCLIB'), findsOneWidget);
      expect(find.text('Netease'), findsOneWidget);
      expect(find.text('example.lyrics'), findsOneWidget);
      expect(find.text('From LRCLIB'), findsOneWidget);
      expect(find.textContaining('Synced'), findsOneWidget);
      expect(find.text('No lyrics found'), findsOneWidget);

      // A provider that has not answered yet cannot be chosen.
      await tester.tap(find.text('example.lyrics'));
      await tester.pump();
      expect(chosen, isNull);

      slow.complete({'lyrics': 'Plain words', 'sync_type': 'UNSYNCED'});
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Plain text'), findsOneWidget);

      await tester.tap(find.text('From LRCLIB'));
      await tester.pumpAndSettle();
      expect(chosen, '[00:01.00]From LRCLIB');
    });
  }
}
