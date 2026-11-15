import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/settings_group.dart';

import 'support/tooltip_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late UserProfileStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('profile-test-');
    store = UserProfileStore(documents: () async => directory);
  });

  tearDown(() async => directory.delete(recursive: true));

  test(
    'profile persists locally and replaces/removes only its previous photo',
    () async {
      expect((await store.read()).name, isEmpty);
      final first = await store.save(
        name: '  Listener  ',
        photo: Uint8List.fromList([1, 2, 3]),
      );
      expect((await store.read()).name, 'Listener');
      expect(await File(first.photoPath!).readAsBytes(), [1, 2, 3]);
      final renamed = await store.save(name: 'New name');
      expect(renamed.photoPath, first.photoPath);
      final second = await store.save(
        name: 'New name',
        photo: Uint8List.fromList([4, 5]),
      );
      expect(await File(first.photoPath!).exists(), isFalse);
      expect(await File(second.photoPath!).exists(), isTrue);
      await store.save(name: 'New name', removePhoto: true);
      final restored = await store.read();
      expect(restored.name, 'New name');
      expect(restored.photoPath, isNull);
      expect(await File(second.photoPath!).exists(), isFalse);
    },
  );

  test('stored photo follows relocated documents directory', () async {
    final profile = await store.save(
      name: 'Listener',
      photo: Uint8List.fromList([1]),
    );
    final relocated = await Directory(
      p.join(directory.path, 'new-container'),
    ).create();
    final photoDirectory = await Directory(
      p.join(relocated.path, 'profile'),
    ).create();
    await File(
      profile.photoPath!,
    ).copy(p.join(photoDirectory.path, p.basename(profile.photoPath!)));
    final restored = await UserProfileStore(
      documents: () async => relocated,
    ).read();
    expect(restored.photoPath, startsWith(relocated.path));
    expect(restored.name, 'Listener');
  });

  test('backup restores profile and photo into a new app directory', () async {
    final sourcePreferences = await SharedPreferences.getInstance();
    final sourceStore = UserProfileStore(
      preferences: () async => sourcePreferences,
      documents: () async => directory,
    );
    SharedPreferences.setMockInitialValues({});
    final destinationPreferences = await SharedPreferences.getInstance();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(16, 16);
    final photo = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();

    final destination = Directory(p.join(directory.path, 'restored-app'));
    final destinationStore = UserProfileStore(
      preferences: () async => destinationPreferences,
      documents: () async => destination,
    );
    final container = ProviderContainer(
      overrides: [userProfileStoreProvider.overrideWithValue(destinationStore)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(userProfileProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(userProfileProvider.future);

    for (final withPhoto in [true, false]) {
      final source = await sourceStore.save(
        name: 'Backed up listener',
        photo: withPhoto ? photo : null,
        removePhoto: !withPhoto,
      );
      final file = await BackupService.writeBackupArchive(
        settings: {'theme': 'dark'},
        profile: source,
        includeHistory: false,
        loadHistoryPage: (_, _) async => [],
        collections: {},
        playlistCoverFiles: {},
        extensions: {},
        outputDirectory: directory,
        temporaryDirectory: directory,
      );
      final bundle = (await BackupService.parseFile(
        file.path,
        temporaryDirectory: directory,
      ))!;
      final restoredPhoto = bundle.profile!.photoPath;
      expect(restoredPhoto != null, withPhoto);
      final previousPhoto = (await destinationStore.read()).photoPath;
      await container
          .read(userProfileProvider.notifier)
          .restoreFromBackup(bundle.profile!);
      await bundle.cleanup();
      final restored = await destinationStore.read();
      expect(restored.name, 'Backed up listener');
      expect(container.read(userProfileProvider).value!.name, restored.name);
      if (withPhoto) {
        expect(restored.photoPath, startsWith(destination.path));
        expect(await File(restored.photoPath!).readAsBytes(), photo);
        expect(await File(restoredPhoto!).exists(), isFalse);
      } else {
        expect(restored.photoPath, isNull);
        expect(await File(previousPhoto!).exists(), isFalse);
      }
    }
  });

  test('invalid backup photo leaves the current profile intact', () async {
    await store.save(name: 'Keep me');
    final invalid = File(p.join(directory.path, 'invalid.png'));
    await invalid.writeAsBytes([0, 1]);
    final container = ProviderContainer(
      overrides: [userProfileStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container
          .read(userProfileProvider.notifier)
          .restoreFromBackup(
            UserProfile(name: 'Do not save', photoPath: invalid.path),
          ),
      throwsException,
    );
    expect((await store.read()).name, 'Keep me');
  });

  test('malformed profile and foreign photo paths fall back safely', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_profile_v1', 'broken JSON');
    expect((await store.read()).name, isEmpty);
    await prefs.setString(
      'user_profile_v1',
      jsonEncode({'name': 'Listener', 'photo': '../music.flac'}),
    );
    final profile = await store.read();
    expect(profile.name, 'Listener');
    expect(profile.photoPath, isNull);
  });

  test('photo decoding bounds dimensions and preserves aspect ratio', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final input = await picture.toImage(1600, 800);
    final bytes = (await input.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    input.dispose();
    picture.dispose();
    final png = await prepareProfilePhoto(bytes);
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, 512);
    expect(image.height, 256);
    image.dispose();
    codec.dispose();
    await expectLater(
      prepareProfilePhoto(Uint8List.fromList([0, 1])),
      throwsException,
    );
  });

  testWidgets(
    'profile card stays separate, saves the name, and cancel keeps it',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [userProfileStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container.read(userProfileProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SettingsTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.ancestor(
        of: find.text('Set up your profile'),
        matching: find.byType(SettingsGroup),
      );
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text('Extensions')),
        findsNothing,
      );
      await tester.tap(find.text('Set up your profile'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Listener');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Listener'), findsOneWidget);
      expect(container.read(userProfileProvider).value?.name, 'Listener');
      await tester.tap(find.text('Listener'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Unsaved');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Listener'), findsOneWidget);
      expect(container.read(userProfileProvider).value?.name, 'Listener');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop Settings keeps the profile page open after Save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final container = ProviderContainer(
      overrides: [userProfileStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await container.read(userProfileProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SettingsTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-category:profile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Listener');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(container.read(userProfileProvider).value?.name, 'Listener');
    // The detail pane still shows the profile page, not an empty pane.
    expect(find.text('Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home avatar opens Settings and reflects the saved name', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [userProfileStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    await container.read(userProfileProvider.future);
    final owner = Object();
    ShellTab? requested;
    ShellNavigationService.registerTabSelectionHandler(
      owner: owner,
      handler: (tab) => requested = tab,
    );
    addTearDown(
      () => ShellNavigationService.unregisterTabSelectionHandler(owner),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: HomeProfileButton()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findByTooltip('Settings'));
    expect(requested, ShellTab.settings);
    await container.read(userProfileProvider.notifier).save(name: 'Listener');
    await tester.pumpAndSettle();
    expect(find.text('L'), findsOneWidget);
  });
}
