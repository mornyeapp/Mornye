import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/network_offline_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_storage_service.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.settings);
  final AppSettings settings;
  @override
  AppSettings build() => settings;
  @override
  void setLocalLibraryEnabled(bool enabled) =>
      state = state.copyWith(localLibraryEnabled: enabled);
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Library extends LocalLibraryNotifier {
  int _added = 0;
  @override
  LocalLibraryState build() => LocalLibraryState();
  @override
  Future<void> reloadFromStorage() async {}
  @override
  Future<LocalLibrarySource> addSource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
  }) async {
    final source = LocalLibrarySource(
      id: 'source-${++_added}',
      path: path,
      displayName: displayName,
    );
    await LibraryDatabase.instance.upsertSource(source);
    return source;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'NAS downloads keep one entry through save, repeat, local removal and server removal',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('offline-provider-');
      final previous = databaseFactoryOrNull;
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => root.path);
      addTearDown(() async {
        await LibraryDatabase.instance.close();
        await HistoryDatabase.instance.close();
        messenger.setMockMethodCallHandler(paths, null);
        databaseFactory = previous;
        await root.delete(recursive: true);
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var reads = 0;
      server.listen((request) async {
        reads++;
        expect(request.method, 'GET');
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.add([102, 76, 97, 67, 1, 2, 3]);
        await request.response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );
      addTearDown(storage.dispose);
      await storage.save(
        NetworkConnection(
          id: 'nas',
          name: 'Music NAS',
          protocol: NetworkProtocol.webdav,
          address: 'http://127.0.0.1:${server.port}/',
        ),
      );
      final settings = AppSettings(
        downloadDirectory: '${root.path}/downloads',
        networkDownloadFolder: 'network://nas/New downloads/',
      );
      final library = _Library();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(settings)),
          downloadHistoryProvider.overrideWith(_History.new),
          localLibraryProvider.overrideWith(() => library),
          networkOfflineStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      final originals = [
        for (final number in [1, 2])
          DownloadHistoryItem(
            id: 'download-$number',
            trackName: 'Song $number',
            artistName: 'Artist',
            albumName: 'Album',
            filePath: 'network://nas/Artist/Album/$number.flac',
            service: 'example-provider',
            spotifyId: 'catalog-$number',
            downloadedAt: DateTime(2026),
          ),
      ];
      await HistoryDatabase.instance.upsertBatch([
        for (final item in originals) item.toJson(),
      ]);
      final selected = [
        for (final item in originals)
          UnifiedLibraryItem.fromDownloadHistory(item),
      ];
      final result = await container
          .read(networkOfflineProvider.notifier)
          .save(selected);
      expect(result!.saved, 2);
      expect(result.failed, 0);
      expect(library._added, 1);
      expect(container.read(settingsProvider).localLibraryEnabled, isTrue);
      final sources = await LibraryDatabase.instance.getSources();
      expect(sources.single.path, 'network://nas/Artist/Album/');
      expect(sources.single.displayName, 'Music NAS');
      final saved = await HistoryDatabase.instance.getAll();
      expect(saved, hasLength(2));
      for (final row in saved) {
        final item = DownloadHistoryItem.fromJson(row);
        expect(item.filePath, startsWith(settings.downloadDirectory));
        expect(await File(item.filePath).readAsBytes(), [
          102,
          76,
          97,
          67,
          1,
          2,
          3,
        ]);
        final original = originals.firstWhere(
          (original) => original.id == item.id,
        );
        expect(item.originFilePath, original.filePath);
        expect(item.service, original.service);
        expect(item.spotifyId, original.spotifyId);
      }
      final page = await LibraryDatabase.instance.getQueueTrackPage(
        const QueueLibraryDbQuery(),
      );
      expect(page, hasLength(2));
      expect(page.every((row) => row['source'] == 'downloaded'), isTrue);
      final repeat = await container
          .read(networkOfflineProvider.notifier)
          .save(selected);
      expect(repeat!.skipped, 2);
      expect(reads, 2);
      expect(
        container.read(settingsProvider).networkDownloadFolder,
        settings.networkDownloadFolder,
      );

      final removed = DownloadHistoryItem.fromJson(saved.first);
      await File(removed.filePath).delete();
      await container
          .read(downloadHistoryProvider.notifier)
          .removePhysicalFiles([removed.filePath]);
      final afterLocal = await LibraryDatabase.instance.getQueueTrackPage(
        QueueLibraryDbQuery(
          includeLocal: container.read(settingsProvider).localLibraryEnabled,
        ),
      );
      expect(afterLocal, hasLength(2));
      expect(afterLocal.where((row) => row['source'] == 'local'), hasLength(1));
      final kept = DownloadHistoryItem.fromJson(saved.last);
      final originalsOnServer = await (await LibraryDatabase.instance.database)
          .query(
            'library',
            columns: ['id'],
            where: 'file_path = ?',
            whereArgs: [kept.originFilePath],
          );
      await LibraryDatabase.instance.deleteByIds([
        originalsOnServer.single['id'] as String,
      ]);
      final onDevice = await LibraryDatabase.instance.getQueueTrackPage(
        const QueueLibraryDbQuery(source: 'on-device'),
      );
      expect(onDevice, hasLength(1));
      expect((onDevice.single['item'] as Map)['originAvailable'], isFalse);
      expect(await File(kept.filePath).exists(), isTrue);
    },
  );
}
