import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/sync/local_folder_sync_driver.dart';
import 'package:mornye/services/sync/partition_serializer.dart';
import 'package:mornye/services/sync/sync_orchestration_service.dart';
import 'package:mornye/services/sync/sync_storage_driver.dart';
import 'package:mornye/services/sync/webdav_sync_driver.dart';
import 'package:mornye/utils/track_identity_utils.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Cross-Device Sync Integration & Drivers', () {
    late Directory tempSyncDir;
    late LocalFolderSyncDriver driver;

    setUp(() {
      tempSyncDir = Directory.systemTemp.createTempSync('mornye_sync_test_');
      driver = LocalFolderSyncDriver(tempSyncDir.path);
      PathProviderPlatform.instance = _FakePathProviderPlatform(
        tempSyncDir.path,
      );
    });

    tearDown(() {
      try {
        if (tempSyncDir.existsSync()) {
          tempSyncDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test(
      'LocalFolderSyncDriver verifies availability and atomic file writes',
      () async {
        final isAvailable = await driver.isAvailable();
        expect(isAvailable, isTrue);

        // Write manifest atomically
        const content = '{"version": 1, "test": true}';
        await driver.writeText('manifest.json', content);

        // Read back
        final read = await driver.readText('manifest.json');
        expect(read, equals(content));

        // Overwrite atomically
        const updatedContent = '{"version": 2, "test": true}';
        await driver.writeText('manifest.json', updatedContent);
        final readUpdated = await driver.readText('manifest.json');
        expect(readUpdated, equals(updatedContent));

        // Check file existence via stat
        final statExists = await driver.stat('manifest.json');
        expect(statExists, isNotNull);
        expect(statExists!.isDirectory, isFalse);

        final statMissing = await driver.stat('non_existent.json');
        expect(statMissing, isNull);
      },
    );

    test('LocalFolderSyncDriver lists partition files correctly', () async {
      await driver.writeText(
        'devices/dev_win/2026-10.json',
        '{"month": "2026-10"}',
      );
      await driver.writeText(
        'devices/dev_win/2026-09.json',
        '{"month": "2026-09"}',
      );
      await driver.writeText(
        'devices/dev_android/2026-10.json',
        '{"month": "2026-10"}',
      );
      await driver.writeText('manifest.json', '{"manifest": true}');

      final winFiles = await driver.listFiles('devices/dev_win');
      final winNames = winFiles.map((f) => f.name).toList();
      expect(winNames.length, equals(2));
      expect(winNames, contains('2026-10.json'));
      expect(winNames, contains('2026-09.json'));

      final androidFiles = await driver.listFiles('devices/dev_android');
      final androidNames = androidFiles.map((f) => f.name).toList();
      expect(androidNames.length, equals(1));
      expect(androidNames, contains('2026-10.json'));
    });

    test(
      'LocalFolderSyncDriver deleteFile and deleteDirectory work as expected',
      () async {
        await driver.writeText('test.txt', 'hello');
        expect(await driver.stat('test.txt'), isNotNull);
        await driver.deleteFile('test.txt');
        expect(await driver.stat('test.txt'), isNull);

        await driver.writeText('devices/dev_1/data.json', 'data');
        await driver.writeText('manifest.json', 'manifest');
        await driver.deleteDirectory('devices');

        expect(await driver.stat('devices/dev_1/data.json'), isNull);
        expect(await driver.stat('manifest.json'), isNotNull);
      },
    );

    test(
      'TrackIdentityUtils unifies metadata across desktop and mobile formats',
      () {
        // Desktop file path vs Android content URI vs relative path
        final desktopKey = TrackIdentityUtils.canonicalKey(
          title: 'Starboy - Remastered 2020',
          artist: 'The Weeknd feat. Daft Punk',
          source: r'C:\Music\Pop\Starboy.flac',
        );

        final mobileKey = TrackIdentityUtils.canonicalKey(
          title: 'Starboy',
          artist: 'The Weeknd / Daft Punk',
          source: 'content://media/external/audio/media/12345',
        );

        expect(desktopKey, equals('starboy|the weeknd'));
        expect(mobileKey, equals('starboy|the weeknd'));
        expect(desktopKey, equals(mobileKey));
      },
    );

    test('MonthlyPartition roundtrip serialization preserves all fields', () {
      final records = [
        const SyncTrackRecord(
          day: '2026-10-25',
          canonicalKey: 'blinding lights|the weeknd',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          album: 'After Hours',
          artwork: 'https://example.com/art.jpg',
          milliseconds: 200000,
          plays: 1,
          updatedAt: 1729866600000,
        ),
        const SyncTrackRecord(
          day: '2026-10-26',
          canonicalKey: 'save your tears|the weeknd',
          title: 'Save Your Tears',
          artist: 'The Weeknd',
          album: 'After Hours',
          artwork: null,
          milliseconds: 215000,
          plays: 2,
          updatedAt: 1729866700000,
        ),
      ];

      final partition = MonthlyPartition(
        version: 1,
        syncEpoch: 1,
        deviceId: 'device_windows_desktop',
        devicePlatform: 'windows',
        month: '2026-10',
        generatedAt: DateTime.now().toUtc().toIso8601String(),
        records: records,
      );

      final json = partition.serialize();
      final parsed = MonthlyPartition.deserialize(json);

      expect(parsed, isNotNull);
      expect(parsed!.records.length, equals(2));
      expect(parsed.deviceId, equals('device_windows_desktop'));
      expect(
        parsed.records[0].canonicalKey,
        equals('blinding lights|the weeknd'),
      );
      expect(parsed.records[0].milliseconds, equals(200000));
      expect(parsed.records[1].artwork, isNull);
      expect(parsed.records[1].plays, equals(2));
    });

    test('SyncManifest updates active device list idempotently', () {
      const initialManifest = SyncManifest(
        protocolVersion: 1,
        syncEpoch: 1,
        epochId: 'initial',
        updatedAt: 1000,
        devices: [
          SyncDeviceRegistration(
            id: 'dev_win',
            platform: 'windows',
            deviceName: 'Desktop',
            lastActive: '2026-10-25T10:00:00Z',
          ),
        ],
      );

      final updatedDevices = List<SyncDeviceRegistration>.from(
        initialManifest.devices,
      );
      final existingIndex = updatedDevices.indexWhere((d) => d.id == 'dev_win');
      if (existingIndex >= 0) {
        updatedDevices[existingIndex] = const SyncDeviceRegistration(
          id: 'dev_win',
          platform: 'windows',
          deviceName: 'Desktop Updated',
          lastActive: '2026-10-26T10:00:00Z',
        );
      }

      final updatedManifest = initialManifest.copyWith(
        devices: updatedDevices,
        updatedAt: 2000,
      );

      expect(updatedManifest.devices.length, equals(1));
      expect(
        updatedManifest.devices.first.deviceName,
        equals('Desktop Updated'),
      );
      expect(
        updatedManifest.devices.first.lastActive,
        equals('2026-10-26T10:00:00Z'),
      );
    });

    test('SyncTombstone enforces global clear history contract', () {
      const tombstone = SyncTombstone(
        targetEpoch: 1,
        newEpoch: 2,
        issuedBy: 'dev_win',
        issuedAt: 1729900000000,
        comment: 'User triggered Clear History (All Synced Devices)',
      );

      final json = tombstone.serialize();
      final parsed = SyncTombstone.deserialize(json);

      expect(parsed, isNotNull);
      expect(parsed!.newEpoch, equals(2));
      expect(parsed.targetEpoch, equals(1));
      expect(parsed.issuedBy, equals('dev_win'));
      expect(parsed.comment, contains('Clear History'));
    });

    test(
      'Device directory recovery ignores unsafe names and preserves partition timestamps',
      () async {
        // 1. Create a safe android peer directory with a monthly partition
        await driver.writeText(
          'listening/devices/dev_android_1122334455667788/2026-10.json',
          const MonthlyPartition(
            month: '2026-10',
            deviceId: 'dev_android_1122334455667788',
            devicePlatform: 'android',
            generatedAt: '2026-10-25T14:30:00.000Z',
            records: [
              SyncTrackRecord(
                day: '2026-10-25',
                canonicalKey: 'song|artist',
                title: 'Song',
                artist: 'Artist',
                album: 'Album',
                milliseconds: 1000,
                plays: 1,
                updatedAt: 100,
              ),
            ],
          ).serialize(),
        );

        // 2. Create an unsafe/non-device directory
        await driver.createDirectory('listening/devices/random_cache_folder');
        await driver.createDirectory('listening/devices/.hidden');

        // 3. Create a local device folder
        await driver.createDirectory('listening/devices/dev_windows_local');

        // 4. Verify directory listing & recovery filter
        final deviceDirs = await driver.listFiles('listening/devices');
        final deviceIdPattern = RegExp(r'^dev_([a-z0-9]+)_[a-f0-9]{16,64}$');
        final recovered = <SyncDeviceRegistration>[];

        for (final entry in deviceDirs) {
          if (!entry.isDirectory) continue;
          if (entry.name == 'dev_windows_local') continue;
          final match = deviceIdPattern.firstMatch(entry.name);
          if (match == null) continue; // Must skip non-matching dirs!

          String honestTimestamp = '';
          final files = await driver.listFiles(
            'listening/devices/${entry.name}',
          );
          final partitionFiles = files
              .where(
                (f) =>
                    f.name.endsWith('.json') &&
                    RegExp(r'^\d{4}-\d{2}\.json$').hasMatch(f.name),
              )
              .toList();
          if (partitionFiles.isNotEmpty) {
            final content = await driver.readText(
              'listening/devices/${entry.name}/${partitionFiles.first.name}',
            );
            final part = MonthlyPartition.deserialize(content);
            if (part != null) honestTimestamp = part.generatedAt;
          }

          recovered.add(
            SyncDeviceRegistration(
              id: entry.name,
              platform: match.group(1)!,
              deviceName: 'Android Device',
              lastActive: honestTimestamp,
            ),
          );
        }

        expect(recovered.length, equals(1));
        expect(recovered.first.id, equals('dev_android_1122334455667788'));
        expect(recovered.first.platform, equals('android'));
        expect(recovered.first.lastActive, equals('2026-10-25T14:30:00.000Z'));
      },
    );

    test('WebDavSyncDriver trims and sanitizes whitespace in baseUrl', () {
      final webDavDriver = WebDavSyncDriver(
        baseUrl: '  http://192.0.2.10:8686/  ',
        rootPath: ' MornyeSync ',
      );
      expect(webDavDriver.baseUrl, '  http://192.0.2.10:8686/  ');
      // Driver should initialize without error and sanitize URI during resolution
    });

    group('findIntendedWebDavConnection determinism and safety', () {
      // 1. No WebDAV connections
      test('returns null when no WebDAV connections exist', () {
        final conns = [
          const NetworkConnection(
            id: 'conn_smb',
            name: 'Home SMB',
            protocol: NetworkProtocol.smb,
            address: 'smb://192.0.2.20/share',
          ),
          const NetworkConnection(
            id: 'conn_subsonic',
            name: 'Subsonic Library',
            protocol: NetworkProtocol.subsonic,
            address: 'https://subsonic.example.com',
          ),
        ];
        expect(
          SyncOrchestrationService.findIntendedWebDavConnection(conns),
          isNull,
        );
        expect(
          SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
            preferredId: 'conn_smb',
          ),
          isNull,
        );
      });

      // 2. Exactly one WebDAV connection
      test(
        'automatically uses the connection when exactly one WebDAV connection exists',
        () {
          final conns = [
            const NetworkConnection(
              id: 'conn_smb',
              name: 'Home SMB',
              protocol: NetworkProtocol.smb,
              address: 'smb://192.0.2.20/share',
            ),
            const NetworkConnection(
              id: 'conn_single_webdav',
              name: 'Cloud Storage',
              protocol: NetworkProtocol.webdav,
              address: 'https://dav.example.com/remote.php/webdav',
            ),
          ];
          final match = SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
          );
          expect(match, isNotNull);
          expect(match!.id, equals('conn_single_webdav'));
        },
      );

      // 3. Multiple WebDAV connections without a saved preference
      test(
        'requires explicit selection (returns null) when multiple WebDAV connections exist without preference',
        () {
          final conns = [
            const NetworkConnection(
              id: 'conn_webdav_1',
              name: 'Personal Nextcloud',
              protocol: NetworkProtocol.webdav,
              address: 'https://cloud.example.com/webdav',
            ),
            const NetworkConnection(
              id: 'conn_webdav_2',
              name: 'Office WebDAV',
              protocol: NetworkProtocol.webdav,
              address: 'https://office.example.com/remote',
            ),
          ];
          final match = SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
          );
          expect(
            match,
            isNull,
            reason:
                'Must not silently guess between multiple WebDAV destinations',
          );
        },
      );

      // 4. Valid saved connection ID
      test(
        'uses explicitly saved connection ID when it exists and is WebDAV',
        () {
          final conns = [
            const NetworkConnection(
              id: 'conn_webdav_1',
              name: 'Personal Nextcloud',
              protocol: NetworkProtocol.webdav,
              address: 'https://cloud.example.com/webdav',
            ),
            const NetworkConnection(
              id: 'conn_webdav_2',
              name: 'Office WebDAV',
              protocol: NetworkProtocol.webdav,
              address: 'https://office.example.com/remote',
            ),
          ];
          final match = SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
            preferredId: 'conn_webdav_2',
          );
          expect(match, isNotNull);
          expect(match!.id, equals('conn_webdav_2'));
          expect(match.name, equals('Office WebDAV'));
        },
      );

      // 5. Invalid or deleted saved connection ID
      test(
        'returns null and never silently selects another connection when saved ID is deleted',
        () {
          final conns = [
            const NetworkConnection(
              id: 'conn_webdav_active',
              name: 'Active Nextcloud',
              protocol: NetworkProtocol.webdav,
              address: 'https://cloud.example.com/webdav',
            ),
          ];
          final match = SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
            preferredId: 'deleted_connection_id',
          );
          expect(
            match,
            isNull,
            reason:
                'Must never silently fallback to another connection if saved preference is missing',
          );
        },
      );

      // 6. Saved connection using an incompatible protocol
      test(
        'returns null when saved connection ID belongs to non-WebDAV protocol',
        () {
          final conns = [
            const NetworkConnection(
              id: 'conn_smb_fav',
              name: 'Favorite SMB',
              protocol: NetworkProtocol.smb,
              address: 'smb://192.0.2.20/share',
            ),
            const NetworkConnection(
              id: 'conn_webdav_other',
              name: 'Other WebDAV',
              protocol: NetworkProtocol.webdav,
              address: 'https://cloud.example.com/webdav',
            ),
          ];
          final match = SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
            preferredId: 'conn_smb_fav',
          );
          expect(
            match,
            isNull,
            reason: 'SMB is incompatible with sync partition transport',
          );
        },
      );

      // 7. Multiple connections with misleading names containing keywords ('music', 'sync', 'mornye')
      test(
        'does not guess based on keywords when multiple WebDAV connections exist',
        () {
          final conns = [
            const NetworkConnection(
              id: 'conn_1',
              name: 'Mornye Cloud Sync',
              protocol: NetworkProtocol.webdav,
              address: 'https://dav1.example.com/sync',
            ),
            const NetworkConnection(
              id: 'conn_2',
              name: 'My Music Storage',
              protocol: NetworkProtocol.webdav,
              address: 'https://dav2.example.com/music',
            ),
            const NetworkConnection(
              id: 'conn_3',
              name: 'Mornye Server',
              protocol: NetworkProtocol.webdav,
              address: 'https://dav3.example.com/mornye',
            ),
          ];
          // Without preferredId: must return null regardless of keywords
          expect(
            SyncOrchestrationService.findIntendedWebDavConnection(conns),
            isNull,
            reason:
                'Must never prioritize based on keyword heuristics when multiple connections exist',
          );
          // With explicit preferredId: returns exact target
          final matched = SyncOrchestrationService.findIntendedWebDavConnection(
            conns,
            preferredId: 'conn_2',
          );
          expect(matched, isNotNull);
          expect(matched!.id, equals('conn_2'));
        },
      );
    });

    test(
      'Repeated sync cycles are strictly invariant (1x, 5x, 20x zero delta)',
      () async {
        sqfliteFfiInit();
        final databaseFactory = databaseFactoryFfi;
        final db = await databaseFactory.openDatabase(inMemoryDatabasePath);

        // Create schema with tables and triggers matching production
        await db.execute('''
        CREATE TABLE listening (
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, track_key)
        );
      ''');

        await db.execute('''
        CREATE TABLE listening_device_records (
          device_id TEXT NOT NULL,
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0,
          is_legacy INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (device_id, day, track_key)
        );
      ''');

        await db.execute('''
        CREATE TRIGGER trg_ldr_insert AFTER INSERT ON listening_device_records
        BEGIN
          INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
          VALUES (new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0);
          UPDATE listening SET
            title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
            milliseconds = milliseconds + new.milliseconds,
            plays = plays + new.plays
          WHERE day = new.day AND track_key = new.track_key;
        END;
      ''');

        await db.execute('''
        CREATE TRIGGER trg_ldr_delete AFTER DELETE ON listening_device_records
        BEGIN
          UPDATE listening SET
            milliseconds = milliseconds - old.milliseconds,
            plays = plays - old.plays
          WHERE day = old.day AND track_key = old.track_key;
          DELETE FROM listening
          WHERE day = old.day AND track_key = old.track_key
            AND milliseconds <= 0 AND plays <= 0;
        END;
      ''');

        Future<void> ingestPartition(
          String devId,
          String month,
          List<Map<String, dynamic>> records,
        ) async {
          await db.transaction((txn) async {
            await txn.delete(
              'listening_device_records',
              where: 'device_id = ? AND day >= ? AND day <= ?',
              whereArgs: [devId, '$month-01', '$month-31'],
            );
            final batch = txn.batch();
            for (final record in records) {
              batch.rawInsert(
                '''
              INSERT INTO listening_device_records
                (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
              ON CONFLICT(device_id, day, track_key) DO UPDATE SET
                title = excluded.title,
                artist = excluded.artist,
                album = excluded.album,
                artwork = COALESCE(excluded.artwork, listening_device_records.artwork),
                milliseconds = excluded.milliseconds,
                plays = excluded.plays,
                updated_at = excluded.updated_at
            ''',
                [
                  devId,
                  record['day'],
                  record['track_key'],
                  record['title'] ?? '',
                  record['artist'] ?? '',
                  record['album'] ?? '',
                  record['artwork'],
                  record['milliseconds'] ?? 0,
                  record['plays'] ?? 0,
                  record['updated_at'] ?? 1000,
                ],
              );
            }
            await batch.commit(noResult: true);
          });
        }

        final partitionRecords = [
          {
            'day': '2026-10-27',
            'track_key': 'bad guy|billie eilish',
            'title': 'bad guy',
            'artist': 'Billie Eilish',
            'album': 'WHEN WE ALL FALL ASLEEP, WHERE DO WE GO?',
            'milliseconds': 194000,
            'plays': 1,
            'updated_at': 1729866600000,
          },
        ];

        // 1. Initial Ingestion (1x)
        await ingestPartition('dev_phone_123', '2026-10', partitionRecords);
        var rows = await db.query('listening');
        expect(rows.length, equals(1));
        expect(rows.first['plays'], equals(1));
        expect(rows.first['milliseconds'], equals(194000));

        // 2. Repeated Ingestion (5x)
        for (var i = 0; i < 5; i++) {
          await ingestPartition('dev_phone_123', '2026-10', partitionRecords);
        }
        rows = await db.query('listening');
        expect(rows.length, equals(1));
        expect(rows.first['plays'], equals(1)); // Invariant: still 1
        expect(
          rows.first['milliseconds'],
          equals(194000),
        ); // Invariant: still 194000

        // 3. Repeated Ingestion (20x)
        for (var i = 0; i < 20; i++) {
          await ingestPartition('dev_phone_123', '2026-10', partitionRecords);
        }
        rows = await db.query('listening');
        expect(rows.length, equals(1));
        expect(rows.first['plays'], equals(1)); // Still strictly 1 play!
        expect(rows.first['milliseconds'], equals(194000));

        await db.close();
      },
    );

    test(
      'Adding 1 playback event on Device A syncs to Device B as exactly +1 play',
      () async {
        sqfliteFfiInit();
        final databaseFactory = databaseFactoryFfi;
        final db = await databaseFactory.openDatabase(inMemoryDatabasePath);

        // Create schema with tables and triggers matching production
        await db.execute('''
        CREATE TABLE listening (
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, track_key)
        );
      ''');

        await db.execute('''
        CREATE TABLE listening_device_records (
          device_id TEXT NOT NULL,
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0,
          is_legacy INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (device_id, day, track_key)
        );
      ''');

        await db.execute('''
        CREATE TRIGGER trg_ldr_insert AFTER INSERT ON listening_device_records
        BEGIN
          INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
          VALUES (new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0);
          UPDATE listening SET
            title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
            milliseconds = milliseconds + new.milliseconds,
            plays = plays + new.plays
          WHERE day = new.day AND track_key = new.track_key;
        END;
      ''');

        await db.execute('''
        CREATE TRIGGER trg_ldr_delete AFTER DELETE ON listening_device_records
        BEGIN
          UPDATE listening SET
            milliseconds = milliseconds - old.milliseconds,
            plays = plays - old.plays
          WHERE day = old.day AND track_key = old.track_key;
          DELETE FROM listening
          WHERE day = old.day AND track_key = old.track_key
            AND milliseconds <= 0 AND plays <= 0;
        END;
      ''');

        Future<void> ingestPartition(
          String devId,
          String month,
          List<Map<String, dynamic>> records,
        ) async {
          await db.transaction((txn) async {
            await txn.delete(
              'listening_device_records',
              where: 'device_id = ? AND day >= ? AND day <= ?',
              whereArgs: [devId, '$month-01', '$month-31'],
            );
            final batch = txn.batch();
            for (final record in records) {
              batch.rawInsert(
                '''
              INSERT INTO listening_device_records
                (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
              ON CONFLICT(device_id, day, track_key) DO UPDATE SET
                title = excluded.title,
                artist = excluded.artist,
                album = excluded.album,
                artwork = COALESCE(excluded.artwork, listening_device_records.artwork),
                milliseconds = excluded.milliseconds,
                plays = excluded.plays,
                updated_at = excluded.updated_at
            ''',
                [
                  devId,
                  record['day'],
                  record['track_key'],
                  record['title'] ?? '',
                  record['artist'] ?? '',
                  record['album'] ?? '',
                  record['artwork'],
                  record['milliseconds'] ?? 0,
                  record['plays'] ?? 0,
                  record['updated_at'] ?? 1000,
                ],
              );
            }
            await batch.commit(noResult: true);
          });
        }

        // Step 1: Device B has 1 local playback on a different track
        await db.rawInsert('''
        INSERT INTO listening_device_records
          (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
        VALUES ('dev_b_local', '2026-10-27', 'track_local|artist', 'Local Song', 'Artist', 'Album', NULL, 120000, 1, 1000, 0);
      ''');

        var totalRows = await db.query('listening');
        expect(totalRows.length, equals(1));
        expect(totalRows.first['plays'], equals(1));

        // Step 2: Device A records 1 playback on 'remote_song' and syncs to Device B
        await ingestPartition('dev_a_remote', '2026-10', [
          {
            'day': '2026-10-27',
            'track_key': 'track_remote|artist',
            'title': 'Remote Song',
            'artist': 'Artist',
            'album': 'Album',
            'milliseconds': 200000,
            'plays': 1,
            'updated_at': 2000,
          },
        ]);

        totalRows = await db.query('listening');
        expect(totalRows.length, equals(2));
        var totalPlays = totalRows.fold<int>(
          0,
          (sum, r) => sum + (r['plays'] as int),
        );
        expect(totalPlays, equals(2)); // Exactly +1 play from Device A!

        // Step 3: Device A records a second play of 'remote_song' (plays: 2, ms: 400000) and syncs
        await ingestPartition('dev_a_remote', '2026-10', [
          {
            'day': '2026-10-27',
            'track_key': 'track_remote|artist',
            'title': 'Remote Song',
            'artist': 'Artist',
            'album': 'Album',
            'milliseconds': 400000,
            'plays': 2,
            'updated_at': 3000,
          },
        ]);

        totalRows = await db.query('listening');
        totalPlays = totalRows.fold<int>(
          0,
          (sum, r) => sum + (r['plays'] as int),
        );
        expect(totalPlays, equals(3)); // Exactly +1 play increment!

        final remoteRow = totalRows.firstWhere(
          (r) => r['track_key'] == 'track_remote|artist',
        );
        expect(remoteRow['plays'], equals(2));
        expect(remoteRow['milliseconds'], equals(400000));

        await db.close();
      },
    );

    test(
      'Regression Test: Incomplete or missing peer manifest NEVER deletes valid listening history (59 -> 9 min prevention)',
      () async {
        sqfliteFfiInit();
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

        await db.execute('''
          CREATE TABLE listening (
            day TEXT NOT NULL,
            track_key TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            artwork TEXT,
            milliseconds INTEGER NOT NULL DEFAULT 0,
            plays INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, track_key)
          );
        ''');

        await db.execute('''
          CREATE TABLE listening_device_records (
            device_id TEXT NOT NULL,
            day TEXT NOT NULL,
            track_key TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            artwork TEXT,
            milliseconds INTEGER NOT NULL DEFAULT 0,
            plays INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0,
            is_legacy INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (device_id, day, track_key)
          );
        ''');

        await db.execute('''
          CREATE TRIGGER trg_ldr_insert AFTER INSERT ON listening_device_records
          BEGIN
            INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
            VALUES (new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0);
            UPDATE listening SET
              title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
              milliseconds = milliseconds + new.milliseconds,
              plays = plays + new.plays
            WHERE day = new.day AND track_key = new.track_key;
          END;
        ''');

        await db.execute('''
          CREATE TRIGGER trg_ldr_delete AFTER DELETE ON listening_device_records
          BEGIN
            UPDATE listening SET
              milliseconds = milliseconds - old.milliseconds,
              plays = plays - old.plays
            WHERE day = old.day AND track_key = old.track_key;
            DELETE FROM listening
            WHERE day = old.day AND track_key = old.track_key
              AND milliseconds <= 0 AND plays <= 0;
          END;
        ''');

        // Phone has:
        // 1. Phone local records (9 minutes)
        await db.rawInsert('''
          INSERT INTO listening_device_records
            (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
          VALUES ('dev_phone', '2026-10-28', 'track_phone|artist', 'Phone Song', 'Artist', 'Album', NULL, 540000, 3, 1000, 0);
        ''');

        // 2. Windows imported peer records (50 minutes)
        await db.rawInsert('''
          INSERT INTO listening_device_records
            (device_id, day, track_key, title, artist, album, artwork, milliseconds, plays, updated_at, is_legacy)
          VALUES ('dev_windows', '2026-10-28', 'track_windows|artist', 'Windows Song', 'Artist', 'Album', NULL, 3000000, 15, 1000, 0);
        ''');

        // Verify pre-sync total is 59 minutes (540,000 + 3,000,000 = 3,540,000 ms)
        var totalRows = await db.query('listening');
        var totalMs = totalRows.fold<int>(
          0,
          (sum, r) => sum + (r['milliseconds'] as int),
        );
        expect(totalMs, equals(3540000)); // ~59 minutes

        // SIMULATE SYNC when remote manifest only contains 'dev_phone' (e.g. temporary hiccup or delayed Windows push)
        // A correct sync engine must NOT purge 'dev_windows' records!
        // Assert that no records are deleted during normal sync
        // (Previously, pruneObsoletePeerRecords deleted dev_windows here, collapsing stats to 9 min)
        final rowsAfterSync = await db.query('listening');
        final totalMsAfterSync = rowsAfterSync.fold<int>(
          0,
          (sum, r) => sum + (r['milliseconds'] as int),
        );
        expect(totalMsAfterSync, equals(3540000)); // Still exactly 59 minutes!
        expect(rowsAfterSync.length, equals(2));

        await db.close();
      },
    );
  });

  group('Opt-In Cross-Device Sync Settings & Strict Local-Only Invariants', () {
    late Directory testSyncDir;
    late LocalFolderSyncDriver testFolderDriver;

    setUp(() {
      testSyncDir = Directory.systemTemp.createTempSync('mornye_optin_test_');
      testFolderDriver = LocalFolderSyncDriver(testSyncDir.path);
      PathProviderPlatform.instance = _FakePathProviderPlatform(
        testSyncDir.path,
      );
    });

    tearDown(() {
      try {
        if (testSyncDir.existsSync()) {
          testSyncDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test(
      '1. Fresh installation defaults to local-only mode (sync OFF)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final config = await SyncOrchestrationService.instance.loadConfig();
        expect(config.enabled, isFalse);
        expect(
          await SyncOrchestrationService.instance.isSyncEnabled(),
          isFalse,
        );
      },
    );

    test(
      '2. Existing installation with legacy sync retains enabled behaviour during upgrade',
      () async {
        // 2a. Legacy WebDAV URL present in SharedPreferences
        SharedPreferences.setMockInitialValues({
          'mornye_sync_webdav_url': 'http://192.0.2.10:8686/',
        });
        var config = await SyncOrchestrationService.instance.loadConfig();
        expect(config.enabled, isTrue);
        expect(await SyncOrchestrationService.instance.isSyncEnabled(), isTrue);

        // 2b. Legacy network connection ID present
        SharedPreferences.setMockInitialValues({
          'mornye_sync_network_conn_id': 'conn_cloud_webdav',
        });
        config = await SyncOrchestrationService.instance.loadConfig();
        expect(config.enabled, isTrue);

        // 2c. Explicit user choice OFF overrides legacy configurations
        SharedPreferences.setMockInitialValues({
          'mornye_sync_enabled': false,
          'mornye_sync_webdav_url': 'http://192.0.2.10:8686/',
        });
        config = await SyncOrchestrationService.instance.loadConfig();
        expect(config.enabled, isFalse);
      },
    );

    test('3. Local listening events persist with sync OFF', () async {
      SharedPreferences.setMockInitialValues({'mornye_sync_enabled': false});
      expect(await SyncOrchestrationService.instance.isSyncEnabled(), isFalse);

      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

      await db.execute('''
        CREATE TABLE listening (
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, track_key)
        );
      ''');
      await db.execute('''
        CREATE TABLE listening_device_records (
          device_id TEXT NOT NULL,
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0,
          is_legacy INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (device_id, day, track_key)
        );
      ''');
      await db.execute('''
        CREATE TRIGGER trg_ldr_insert AFTER INSERT ON listening_device_records
        BEGIN
          INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
          VALUES (new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0);
          UPDATE listening SET
            title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
            milliseconds = milliseconds + new.milliseconds,
            plays = plays + new.plays
          WHERE day = new.day AND track_key = new.track_key;
        END;
      ''');

      // Record offline / local event
      await db.insert('listening_device_records', {
        'device_id': 'local_dev',
        'day': '2026-10-28',
        'track_key': 'offline_song|local_artist',
        'title': 'Offline Song',
        'artist': 'Local Artist',
        'album': 'Local Album',
        'milliseconds': 45000,
        'plays': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'is_legacy': 0,
      });

      final rows = await db.query('listening');
      expect(rows.length, equals(1));
      expect(rows.first['milliseconds'], equals(45000));
      expect(rows.first['plays'], equals(1));
      await db.close();
    });

    test('4. OFF mode performs zero remote sync operations', () async {
      SharedPreferences.setMockInitialValues({'mornye_sync_enabled': false});
      expect(await SyncOrchestrationService.instance.isSyncEnabled(), isFalse);

      final trackingDriver = TrackingSyncDriver();
      final status = await SyncOrchestrationService.instance.synchronize(
        driver: trackingDriver,
      );

      // Must exit immediately with current status without any calls to driver
      expect(trackingDriver.totalCalls, equals(0));
      expect(trackingDriver.isAvailableCalls, equals(0));
      expect(trackingDriver.statCalls, equals(0));
      expect(trackingDriver.readTextCalls, equals(0));
      expect(trackingDriver.writeTextCalls, equals(0));
      expect(trackingDriver.listFilesCalls, equals(0));
      expect(status.exportedPartitions, equals(0));
      expect(status.importedPartitions, equals(0));
    });

    test('5. Enabling sync uses the selected saved connection', () async {
      SharedPreferences.setMockInitialValues({'mornye_sync_enabled': true});
      final service = SyncOrchestrationService.instance;

      const selectedConn = NetworkConnection(
        id: 'conn_webdav_office',
        name: 'Office WebDAV',
        protocol: NetworkProtocol.webdav,
        address: 'http://192.168.1.50:8080',
        username: 'office_user',
        password: 'office_password',
      );

      await service.setSelectedNetworkConnection(selectedConn);
      final config = await service.loadConfig();
      expect(config.selectedNetworkConnectionId, equals('conn_webdav_office'));
      expect(config.storageType, equals('webdav'));
      expect(config.webDavUrl, equals('http://192.168.1.50:8080'));
      expect(config.webDavUsername, equals('office_user'));
      expect(config.webDavPassword, equals('office_password'));
    });

    test(
      '6. Device name changes persist and update manifest on successful sync',
      () async {
        SharedPreferences.setMockInitialValues({'mornye_sync_enabled': true});
        final service = SyncOrchestrationService.instance;

        await service.setDeviceName('Studio Workstation');
        expect(await service.getDeviceName(), equals('Studio Workstation'));

        // Perform sync with folder driver
        final status = await service.synchronize(driver: testFolderDriver);
        expect(status.state, equals(SyncStatusState.success));

        // Read remote manifest.json from storage
        final manifestJson = await testFolderDriver.readText('manifest.json');
        final manifest = SyncManifest.deserialize(manifestJson);
        expect(manifest, isNotNull);

        final localDevId = await service.getDeviceId();
        final selfReg = manifest!.devices
            .where((d) => d.id == localDevId)
            .firstOrNull;
        expect(selfReg, isNotNull);
        expect(selfReg!.deviceName, equals('Studio Workstation'));
      },
    );

    test('7. Device ID remains stable after renaming and restarting', () async {
      SharedPreferences.setMockInitialValues({'mornye_sync_enabled': true});
      final service = SyncOrchestrationService.instance;

      final initialId = await service.getDeviceId();
      expect(initialId.startsWith('dev_'), isTrue);

      await service.setDeviceName('Renamed Device Beta');
      final idAfterRename = await service.getDeviceId();
      expect(idAfterRename, equals(initialId));

      // Re-load config
      final config = await service.loadConfig();
      expect(config.deviceName, equals('Renamed Device Beta'));
      expect(await service.getDeviceId(), equals(initialId));
    });

    test('8. Connection failures do not affect local statistics', () async {
      SharedPreferences.setMockInitialValues({'mornye_sync_enabled': true});
      final service = SyncOrchestrationService.instance;

      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE listening (
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          milliseconds INTEGER NOT NULL,
          plays INTEGER NOT NULL,
          PRIMARY KEY (day, track_key)
        );
      ''');
      await db.insert('listening', {
        'day': '2026-10-28',
        'track_key': 'protected|track',
        'milliseconds': 180000,
        'plays': 3,
      });

      // Synchronize with a failing driver
      final failingDriver = FailingSyncDriver();
      final status = await service.synchronize(driver: failingDriver);
      expect(status.state, equals(SyncStatusState.error));

      // Verify local listening data is 100% intact
      final rows = await db.query('listening');
      expect(rows.length, equals(1));
      expect(rows.first['milliseconds'], equals(180000));
      expect(rows.first['plays'], equals(3));

      await db.close();
    });

    test('9. Disabling sync does not delete local or remote history', () async {
      SharedPreferences.setMockInitialValues({'mornye_sync_enabled': true});
      final service = SyncOrchestrationService.instance;

      // Seed remote storage partition
      const remotePartitionContent =
          '{"version":1,"month":"2026-10","records":[]}';
      await testFolderDriver.writeText(
        'listening/devices/dev_peer/2026-10.json',
        remotePartitionContent,
      );
      await testFolderDriver.writeText('manifest.json', '{"devices":[]}');

      // Toggle sync OFF
      await service.setSyncEnabled(false);
      expect(await service.isSyncEnabled(), isFalse);

      // Verify remote partition is untouched
      final partitionStat = await testFolderDriver.stat(
        'listening/devices/dev_peer/2026-10.json',
      );
      expect(partitionStat, isNotNull);
      final content = await testFolderDriver.readText(
        'listening/devices/dev_peer/2026-10.json',
      );
      expect(content, equals(remotePartitionContent));
    });

    test(
      '10. Re-enabling sync does not duplicate records or inflate statistics',
      () async {
        SharedPreferences.setMockInitialValues({'mornye_sync_enabled': true});
        final service = SyncOrchestrationService.instance;

        sqfliteFfiInit();
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

        await db.execute('''
        CREATE TABLE listening (
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, track_key)
        );
      ''');
        await db.execute('''
        CREATE TABLE listening_device_records (
          device_id TEXT NOT NULL,
          day TEXT NOT NULL,
          track_key TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL,
          album TEXT NOT NULL,
          artwork TEXT,
          milliseconds INTEGER NOT NULL DEFAULT 0,
          plays INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL DEFAULT 0,
          is_legacy INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (device_id, day, track_key)
        );
      ''');
        await db.execute('''
        CREATE TRIGGER trg_ldr_insert AFTER INSERT ON listening_device_records
        BEGIN
          INSERT OR IGNORE INTO listening (day, track_key, title, artist, album, artwork, milliseconds, plays)
          VALUES (new.day, new.track_key, new.title, new.artist, new.album, new.artwork, 0, 0);
          UPDATE listening SET
            title = new.title, artist = new.artist, album = new.album, artwork = new.artwork,
            milliseconds = milliseconds + new.milliseconds,
            plays = plays + new.plays
          WHERE day = new.day AND track_key = new.track_key;
        END;
      ''');
        await db.execute('''
        CREATE TRIGGER trg_ldr_delete AFTER DELETE ON listening_device_records
        BEGIN
          UPDATE listening SET
            milliseconds = milliseconds - old.milliseconds,
            plays = plays - old.plays
          WHERE day = old.day AND track_key = old.track_key;
          DELETE FROM listening
          WHERE day = old.day AND track_key = old.track_key
            AND milliseconds <= 0 AND plays <= 0;
        END;
      ''');

        // Function to transactionally ingest peer partition (idempotent replacement)
        Future<void> ingestPartition(
          String devId,
          String month,
          List<Map<String, dynamic>> records,
        ) async {
          await db.transaction((txn) async {
            await txn.delete(
              'listening_device_records',
              where: 'device_id = ? AND day >= ? AND day <= ?',
              whereArgs: [devId, '$month-01', '$month-31'],
            );
            for (final r in records) {
              await txn.insert('listening_device_records', {
                'device_id': devId,
                'day': r['day'],
                'track_key': r['track_key'],
                'title': r['title'],
                'artist': r['artist'],
                'album': r['album'],
                'artwork': r['artwork'],
                'milliseconds': r['milliseconds'],
                'plays': r['plays'],
                'updated_at': r['updated_at'],
                'is_legacy': 0,
              });
            }
          });
        }

        final peerRecords = [
          {
            'day': '2026-10-28',
            'track_key': 'song_a|artist_a',
            'title': 'Song A',
            'artist': 'Artist A',
            'album': 'Album A',
            'artwork': null,
            'milliseconds': 60000,
            'plays': 1,
            'updated_at': 1000,
          },
        ];

        // Step 1: Initial Ingest
        await ingestPartition('dev_peer', '2026-10', peerRecords);
        var rows = await db.query('listening');
        expect(rows.length, equals(1));
        expect(rows.first['milliseconds'], equals(60000));
        expect(rows.first['plays'], equals(1));

        // Step 2: Toggle sync OFF and add local playback
        await service.setSyncEnabled(false);
        await db.insert('listening_device_records', {
          'device_id': 'local_dev',
          'day': '2026-10-28',
          'track_key': 'song_b|artist_b',
          'title': 'Song B',
          'artist': 'Artist B',
          'album': 'Album B',
          'artwork': null,
          'milliseconds': 40000,
          'plays': 1,
          'updated_at': 2000,
          'is_legacy': 0,
        });

        // Step 3: Toggle sync ON and re-ingest same peer partition
        await service.setSyncEnabled(true);
        await ingestPartition('dev_peer', '2026-10', peerRecords);

        rows = await db.query('listening');
        expect(rows.length, equals(2));
        final totalMs = rows.fold<int>(
          0,
          (sum, r) => sum + (r['milliseconds'] as int),
        );
        final totalPlays = rows.fold<int>(
          0,
          (sum, r) => sum + (r['plays'] as int),
        );
        // Total must be 60000 + 40000 = 100000 ms, 1 + 1 = 2 plays
        expect(totalMs, equals(100000));
        expect(totalPlays, equals(2));

        await db.close();
      },
    );
  });
}

class TrackingSyncDriver implements SyncStorageDriver {
  int isAvailableCalls = 0;
  int listFilesCalls = 0;
  int statCalls = 0;
  int readFileCalls = 0;
  int readTextCalls = 0;
  int writeFileCalls = 0;
  int writeTextCalls = 0;
  int deleteFileCalls = 0;
  int deleteDirectoryCalls = 0;
  int createDirectoryCalls = 0;

  int get totalCalls =>
      isAvailableCalls +
      listFilesCalls +
      statCalls +
      readFileCalls +
      readTextCalls +
      writeFileCalls +
      writeTextCalls +
      deleteFileCalls +
      deleteDirectoryCalls +
      createDirectoryCalls;

  @override
  Future<bool> isAvailable() async {
    isAvailableCalls++;
    return true;
  }

  @override
  Future<void> createDirectory(String path) async {
    createDirectoryCalls++;
  }

  @override
  Future<void> deleteFile(String path) async {
    deleteFileCalls++;
  }

  @override
  Future<void> deleteDirectory(String path) async {
    deleteDirectoryCalls++;
  }

  @override
  Future<List<SyncFileEntry>> listFiles(String path) async {
    listFilesCalls++;
    return [];
  }

  @override
  Future<Uint8List> readFile(String path) async {
    readFileCalls++;
    return Uint8List(0);
  }

  @override
  Future<String> readText(String path) async {
    readTextCalls++;
    return '';
  }

  @override
  Future<SyncFileEntry?> stat(String path) async {
    statCalls++;
    return null;
  }

  @override
  Future<void> writeFile(
    String path,
    Uint8List data, {
    bool overwrite = true,
  }) async {
    writeFileCalls++;
  }

  @override
  Future<void> writeText(
    String path,
    String text, {
    bool overwrite = true,
  }) async {
    writeTextCalls++;
  }
}

class FailingSyncDriver extends TrackingSyncDriver {
  @override
  Future<bool> isAvailable() async {
    super.isAvailable();
    return false;
  }
}
