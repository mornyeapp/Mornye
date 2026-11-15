import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/ios_library_folder_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory documents;
  late List<String> calls;
  IosPickedDirectory? selection;
  Object? failure;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ios-library-picker-');
    documents = Directory('${root.path}/Documents');
    calls = [];
    selection = null;
    failure = null;
    messenger.setMockMethodCallHandler(paths, (_) async => documents.path);
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      return {'path': '/external/Music', 'bookmark': 'granted-folder-bookmark'};
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(backend, null);
    await root.delete(recursive: true);
  });

  Future<void> openSheet(WidgetTester tester, {bool mornye = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  try {
                    selection = await showIosLibraryFolderSheet(context);
                  } catch (error) {
                    failure = error;
                  }
                },
                child: const Text('Add folder'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
  }

  for (final mornye in [false, true]) {
    testWidgets('internal music bypasses Files (Mornye=$mornye)', (
      tester,
    ) async {
      final music = File('${documents.path}/Mornye/example.flac');
      music.parent.createSync(recursive: true);
      music.writeAsBytesSync([1, 2, 3]);
      await openSheet(tester, mornye: mornye);
      expect(find.text('Choose from Files'), findsOneWidget);
      await tester.tap(find.text('App Documents Folder'));
      await tester.pumpAndSettle();
      expect(selection?.path, documents.path);
      expect(selection?.bookmark, isEmpty);
      expect(calls, isEmpty);
      expect(music.readAsBytesSync(), [1, 2, 3]);
      expect(failure, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('external selection retains its native access bookmark', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.tap(find.text('Choose from Files'));
    await tester.pumpAndSettle();
    expect(calls, ['pickIosDirectory']);
    expect(selection?.path, '/external/Music');
    expect(selection?.bookmark, 'granted-folder-bookmark');
    expect(failure, isNull);
  });

  testWidgets('dismissing the choice does not select or create a folder', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(selection, isNull);
    expect(calls, isEmpty);
    expect(documents.existsSync(), isFalse);
  });

  testWidgets('cancelling Files leaves the library selection unchanged', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(backend, (_) async => null);
    await openSheet(tester);
    await tester.tap(find.text('Choose from Files'));
    await tester.pumpAndSettle();
    expect(selection, isNull);
    expect(failure, isNull);
    expect(documents.existsSync(), isFalse);
  });

  testWidgets('Files errors return to the caller for a visible error', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(backend, (_) async {
      throw PlatformException(code: 'BOOKMARK_FAILED');
    });
    await openSheet(tester);
    await tester.tap(find.text('Choose from Files'));
    await tester.pumpAndSettle();
    expect(selection, isNull);
    expect(failure, isA<PlatformException>());
    expect(documents.existsSync(), isFalse);
  });
}
