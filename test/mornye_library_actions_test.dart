import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/re_enrich_field_dialog.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/destructive_selection_button.dart';

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.dark,
  TargetPlatform? platform,
}) => ProviderScope(
  child: MaterialApp(
    theme: MornyeTheme.build(brightness).copyWith(platform: platform),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _mockMetadataFile(WidgetTester tester) {
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    channel,
    (call) async => switch (call.method) {
      'safStat' => jsonEncode({'exists': true, 'size': 100}),
      'readAudioMetadata' ||
      'readFileMetadata' => jsonEncode({'title': 'Track', 'artist': 'Artist'}),
      'getLyricsLRCWithSource' => jsonEncode({'lyrics': '', 'source': ''}),
      'getSafFileModTimes' => '{}',
      _ => null,
    },
  );
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('Mornye selection actions remain accessible on narrow screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selectedAll = false;
    var closed = false;
    var deleted = false;
    var converted = false;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Align(
            alignment: Alignment.bottomCenter,
            child: SelectionBottomBar(
              selectedCount: 1,
              allSelected: false,
              onClose: () => closed = true,
              onToggleSelectAll: () => selectedAll = true,
              bottomPadding: 0,
              children: [
                SelectionActionButton(
                  icon: Icons.swap_horiz,
                  label: 'Convert 1 track',
                  onPressed: () => converted = true,
                  colorScheme: Theme.of(context).colorScheme,
                ),
                const SizedBox(height: 8),
                DestructiveSelectionButton(
                  count: 1,
                  colorScheme: Theme.of(context).colorScheme,
                  onPressed: () => deleted = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Select All'));
    await _tapVisible(tester, find.text('Convert 1 track'));
    await _tapVisible(tester, find.byIcon(CupertinoIcons.trash));
    await _tapVisible(tester, find.byIcon(CupertinoIcons.xmark));
    expect((selectedAll, converted, deleted, closed), (true, true, true, true));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('Mornye conversion preserves selected options ($brightness)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      (String, String, bool)? result;
      await tester.pumpWidget(
        _app(
          BatchConvertSheet(
            formats: const [
              'ALAC',
              'FLAC',
              'WAV',
              'AIFF',
              'AAC',
              'MP3',
              'Opus',
            ],
            title: 'Batch Convert',
            confirmLabel: 'Convert tracks',
            sourceBitDepth: 24,
            sourceSampleRate: 48000,
            onConvert: (format, bitrate, quality, processing, keepOriginal) {
              result = (format, bitrate, keepOriginal);
            },
          ),
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Opus'));
      await _tapVisible(tester, find.text('160k'));
      await _tapVisible(tester, find.byType(AppSwitch));
      await _tapVisible(tester, find.text('Convert tracks'));
      expect(result, ('Opus', '160k', true));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Mornye Re-enrich retains field choices and disables empty review',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ReEnrichFieldSelection? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async {
                result = await showReEnrichFieldDialog(
                  context,
                  selectedCount: 2,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await _tapVisible(tester, find.text('Open'));
      await _tapVisible(tester, find.text('Update selected tags'));
      await _tapVisible(tester, find.text('Select All'));
      final review = find.widgetWithText(AppActionButton, 'Review changes');
      expect(tester.widget<AppActionButton>(review).onPressed, isNull);
      await _tapVisible(tester, find.text('Cover Art'));
      await _tapVisible(tester, find.text('Review changes'));
      expect(result?.mode, ReEnrichBatchMode.selectedFields);
      expect(result?.fields, [ReEnrichFields.cover]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Mornye ReplayGain cancellation restores selection without analysis',
    (tester) async {
      bool? confirmed;
      var exitedSelection = false;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => runBatchReplayGain(
                context,
                [
                  UnifiedLibraryItem(
                    id: 'track',
                    trackName: 'Track',
                    artistName: 'Artist',
                    albumName: 'Album',
                    filePath: '/missing/track.flac',
                    addedAt: DateTime(2026),
                    source: LibraryItemSource.local,
                  ),
                ],
                onExitSelectionMode: () => exitedSelection = true,
                onConfirmClosed: (value) async => confirmed = value,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await _tapVisible(tester, find.text('Open'));
      expect(find.byType(AppAlertDialog), findsOneWidget);
      await _tapVisible(tester, find.text('Cancel'));
      expect(confirmed, isFalse);
      expect(exitedSelection, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('Metadata menu scroll reaches the last action ($platform)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 540));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      _mockMetadataFile(tester);
      await tester.pumpWidget(
        _app(
          TrackMetadataScreen(
            item: DownloadHistoryItem(
              id: 'menu-track',
              trackName: 'Track',
              artistName: 'Artist',
              albumName: 'Album',
              filePath: 'content://library/document/menu-track.flac',
              service: 'provider-a',
              downloadedAt: DateTime(2026),
            ),
          ),
          platform: platform,
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byIcon(CupertinoIcons.ellipsis));
      expect(find.text('Edit audio file'), findsNothing);
      expect(find.text('Similar songs in Library'), findsNothing);
      expect(find.text('Edit Metadata'), findsOneWidget);
      final lastAction = find.text('Remove from device');
      expect(lastAction.hitTestable(), findsNothing);
      expect(find.byType(MornyeContextMenu), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      for (var drag = 0; drag < 4; drag++) {
        await tester.dragFrom(const Offset(195, 400), const Offset(0, -320));
        await tester.pumpAndSettle();
      }
      expect(find.text('Share').hitTestable(), findsOneWidget);
      expect(lastAction.hitTestable(), findsOneWidget);
      // Device Hub / Simulator users can also scroll with a trackpad or wheel.
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(195, 400),
          scrollDelta: Offset(0, -2000),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Play next').hitTestable(), findsOneWidget);
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(195, 400),
          scrollDelta: Offset(0, 2000),
        ),
      );
      await tester.pumpAndSettle();
      expect(lastAction.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye metadata editor keeps edited text and Save available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    _mockMetadataFile(tester);
    await tester.pumpWidget(
      _app(
        TrackMetadataScreen(
          item: DownloadHistoryItem(
            id: 'edit-track',
            trackName: 'Track',
            artistName: 'Artist',
            albumName: 'Album',
            filePath: 'content://library/document/edit-track.flac',
            service: 'provider-a',
            downloadedAt: DateTime(2026),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byIcon(CupertinoIcons.ellipsis));
    await tester.tap(find.text('Edit Metadata'));
    await tester.pump(const Duration(milliseconds: 400));
    // The editor extracts its preview through real temporary-file I/O.
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
      }
    });
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    final title = find.byWidgetPredicate(
      (widget) =>
          widget is CupertinoTextField && widget.controller?.text == 'Track',
    );
    await tester.ensureVisible(title);
    await tester.enterText(title, 'Edited track');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('Edited track'), findsOneWidget);
    expect(find.widgetWithText(AppActionButton, 'Save'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Auto-fill from online'),
      -250,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await _tapVisible(tester, find.text('Auto-fill from online'));
    await _tapVisible(tester, find.text('None'));
    final search = find.widgetWithText(AppActionButton, 'Find metadata');
    expect(tester.widget<AppActionButton>(search).onPressed, isNull);
    await _tapVisible(tester, find.text('All'));
    expect(tester.widget<AppActionButton>(search).onPressed, isNotNull);
    expect(
      tester
          .widgetList<MornyeFilterChip>(find.byType(MornyeFilterChip))
          .every((chip) => chip.selected),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
