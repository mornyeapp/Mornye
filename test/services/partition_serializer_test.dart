import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/sync/partition_serializer.dart';

void main() {
  group('PartitionSerializer', () {
    test('MonthlyPartition serializes and deserializes cleanly', () {
      const partition = MonthlyPartition(
        version: 1,
        syncEpoch: 1,
        deviceId: 'dev_win_123',
        devicePlatform: 'windows',
        month: '2026-10',
        generatedAt: '2026-10-26T12:00:00Z',
        records: [
          SyncTrackRecord(
            day: '2026-10-25',
            canonicalKey: 'easy on me|adele',
            title: 'Easy On Me',
            artist: 'Adele',
            album: '30',
            milliseconds: 184000,
            plays: 1,
            updatedAt: 1729866600000,
          ),
        ],
      );

      final jsonString = partition.serialize();
      final parsed = MonthlyPartition.deserialize(jsonString);

      expect(parsed, isNotNull);
      expect(parsed!.version, 1);
      expect(parsed.deviceId, 'dev_win_123');
      expect(parsed.month, '2026-10');
      expect(parsed.records.length, 1);
      expect(parsed.records.first.canonicalKey, 'easy on me|adele');
      expect(parsed.records.first.milliseconds, 184000);
      expect(parsed.records.first.plays, 1);
    });

    test(
      'MonthlyPartition enforces invariants: filters zero-metrics and month mismatches',
      () {
        final rawJson = '''
      {
        "version": 1,
        "syncEpoch": 1,
        "deviceId": "dev_mob_456",
        "devicePlatform": "android",
        "month": "2026-10",
        "generatedAt": "2026-10-26T12:00:00Z",
        "records": [
          {
            "day": "2026-10-25",
            "canonicalKey": "valid track|artist",
            "title": "Valid",
            "artist": "Artist",
            "album": "Album",
            "milliseconds": 1000,
            "plays": 1,
            "updatedAt": 100
          },
          {
            "day": "2026-10-25",
            "canonicalKey": "zero metric|artist",
            "title": "Zero",
            "artist": "Artist",
            "album": "Album",
            "milliseconds": 0,
            "plays": 0,
            "updatedAt": 100
          },
          {
            "day": "2026-09-15",
            "canonicalKey": "wrong month|artist",
            "title": "Wrong Month",
            "artist": "Artist",
            "album": "Album",
            "milliseconds": 5000,
            "plays": 1,
            "updatedAt": 100
          },
          {
            "day": "",
            "canonicalKey": "empty day|artist",
            "title": "Empty",
            "artist": "Artist",
            "album": "Album",
            "milliseconds": 5000,
            "plays": 1,
            "updatedAt": 100
          }
        ]
      }
      ''';

        final partition = MonthlyPartition.deserialize(rawJson);
        expect(partition, isNotNull);
        // Only the first valid record must survive!
        expect(partition!.records.length, 1);
        expect(partition.records.first.canonicalKey, 'valid track|artist');
      },
    );

    test('SyncManifest and SyncTombstone serialize correctly', () {
      const manifest = SyncManifest(
        protocolVersion: 1,
        syncEpoch: 2,
        epochId: 'epoch_20261026_001',
        updatedAt: 1729900000000,
        devices: [
          SyncDeviceRegistration(
            id: 'dev_win_123',
            platform: 'windows',
            deviceName: "Workstation PC",
            lastActive: '2026-10-26T12:00:00Z',
          ),
        ],
      );

      final manifestJson = manifest.serialize();
      final parsedManifest = SyncManifest.deserialize(manifestJson);
      expect(parsedManifest, isNotNull);
      expect(parsedManifest!.syncEpoch, 2);
      expect(parsedManifest.devices.length, 1);
      expect(parsedManifest.devices.first.id, 'dev_win_123');

      const tombstone = SyncTombstone(
        targetEpoch: 1,
        newEpoch: 2,
        issuedBy: 'dev_win_123',
        issuedAt: 1729900000000,
      );
      final tombstoneJson = tombstone.serialize();
      final parsedTombstone = SyncTombstone.deserialize(tombstoneJson);
      expect(parsedTombstone, isNotNull);
      expect(parsedTombstone!.targetEpoch, 1);
      expect(parsedTombstone.newEpoch, 2);
      expect(parsedTombstone.issuedBy, 'dev_win_123');
    });

    test(
      'SyncManifest.mergeWith deduplicates and resolves latest device activity',
      () {
        const base = SyncManifest(
          epochId: 'ep1',
          updatedAt: 1000,
          devices: [
            SyncDeviceRegistration(
              id: 'dev_win',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T10:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_phone',
              platform: 'android',
              deviceName: 'Phone Old',
              lastActive: '2026-10-27T09:00:00Z',
            ),
          ],
        );

        const remote = SyncManifest(
          epochId: 'ep1',
          updatedAt: 2000,
          devices: [
            SyncDeviceRegistration(
              id: 'dev_phone',
              platform: 'android',
              deviceName: 'Phone New',
              lastActive: '2026-10-27T11:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_laptop',
              platform: 'windows',
              deviceName: 'Laptop',
              lastActive: '2026-10-27T08:00:00Z',
            ),
          ],
        );

        final merged = base.mergeWith(
          remote,
          localDevice: const SyncDeviceRegistration(
            id: 'dev_win',
            platform: 'windows',
            deviceName: 'Windows PC',
            lastActive: '2026-10-27T12:00:00Z',
          ),
        );

        expect(merged.devices.length, 3);
        final byId = {for (final d in merged.devices) d.id: d};
        expect(byId['dev_win']!.lastActive, '2026-10-27T12:00:00Z');
        expect(byId['dev_phone']!.deviceName, 'Phone New');
        expect(byId['dev_phone']!.lastActive, '2026-10-27T11:00:00Z');
        expect(byId['dev_laptop']!.lastActive, '2026-10-27T08:00:00Z');
        expect(merged.updatedAt > 2000, isTrue);
      },
    );

    test(
      'SyncManifest.mergeWith safely integrates recovered devices with honest timestamps',
      () {
        const base = SyncManifest(
          epochId: 'ep1',
          updatedAt: 1000,
          devices: [
            SyncDeviceRegistration(
              id: 'dev_win',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T10:00:00Z',
            ),
          ],
        );

        const recovered = [
          SyncDeviceRegistration(
            id: 'dev_android_safe',
            platform: 'android',
            deviceName: 'Android Device',
            lastActive: '2026-10-25T14:30:00Z', // Honest historical timestamp
          ),
        ];

        final merged = base.mergeWith(null, recoveredDevices: recovered);
        expect(merged.devices.length, 2);
        final androidDev = merged.devices.firstWhere(
          (d) => d.id == 'dev_android_safe',
        );
        expect(androidDev.lastActive, '2026-10-25T14:30:00Z');
      },
    );

    test('SyncManifest.mergeWith adopts higher sync epoch and its epochId', () {
      const olderEpoch = SyncManifest(
        syncEpoch: 1,
        epochId: 'epoch_1',
        updatedAt: 1000,
      );

      const newerEpoch = SyncManifest(
        syncEpoch: 2,
        epochId: 'epoch_2',
        updatedAt: 1500,
      );

      final merged = olderEpoch.mergeWith(newerEpoch);
      expect(merged.syncEpoch, 2);
      expect(merged.epochId, 'epoch_2');
    });

    test(
      'SyncManifest.mergeWith prunes obsolete predecessor registrations of the local client',
      () {
        const manifest = SyncManifest(
          epochId: 'test_epoch',
          updatedAt: 1000,
          devices: [
            SyncDeviceRegistration(
              id: 'dev_windows_old1',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T09:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_windows_old2',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T10:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_android_phone',
              platform: 'android',
              deviceName: 'Mobile Phone',
              lastActive: '2026-10-27T11:00:00Z',
            ),
          ],
        );

        const currentLocal = SyncDeviceRegistration(
          id: 'dev_windows_current',
          platform: 'windows',
          deviceName: 'Windows PC',
          lastActive: '2026-10-27T12:00:00Z',
        );

        final merged = manifest.mergeWith(null, localDevice: currentLocal);
        expect(merged.devices.length, 2);
        expect(merged.devices.map((d) => d.id).toList(), [
          'dev_android_phone',
          'dev_windows_current',
        ]);
      },
    );

    test(
      'SyncManifest.mergeWith deduplicates multiple registrations with identical platform and deviceName',
      () {
        const manifest = SyncManifest(
          epochId: 'test_epoch',
          updatedAt: 1000,
          devices: [
            SyncDeviceRegistration(
              id: 'dev_windows_old',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T09:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_windows_newest',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T14:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_android_phone',
              platform: 'android',
              deviceName: 'Mobile Phone',
              lastActive: '2026-10-27T12:00:00Z',
            ),
          ],
        );

        // Merge on Android (localDevice is android)
        const androidLocal = SyncDeviceRegistration(
          id: 'dev_android_phone',
          platform: 'android',
          deviceName: 'Mobile Phone',
          lastActive: '2026-10-27T14:05:00Z',
        );

        final merged = manifest.mergeWith(null, localDevice: androidLocal);
        expect(merged.devices.length, 2);
        expect(merged.devices.any((d) => d.id == 'dev_windows_newest'), isTrue);
        expect(merged.devices.any((d) => d.id == 'dev_windows_old'), isFalse);
      },
    );

    test(
      'SyncManifest.mergeWith prunes ghost peer registrations that have no valid partitions',
      () {
        const manifest = SyncManifest(
          epochId: 'test_epoch',
          updatedAt: 1000,
          devices: [
            SyncDeviceRegistration(
              id: 'dev_android_ghost',
              platform: 'android',
              deviceName: 'Mobile Phone',
              lastActive: '2026-10-27T10:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_android_active',
              platform: 'android',
              deviceName: 'Mobile Phone',
              lastActive: '2026-10-27T12:00:00Z',
            ),
            SyncDeviceRegistration(
              id: 'dev_windows_pc',
              platform: 'windows',
              deviceName: 'Windows PC',
              lastActive: '2026-10-27T12:05:00Z',
            ),
          ],
        );

        // dev_android_ghost has no partitions; dev_android_active has partitions
        final merged = manifest.mergeWith(
          null,
          validPartitionDeviceIds: {'dev_android_active', 'dev_windows_pc'},
        );

        expect(merged.devices.length, 2);
        expect(merged.devices.any((d) => d.id == 'dev_android_ghost'), isFalse);
        expect(merged.devices.any((d) => d.id == 'dev_android_active'), isTrue);
      },
    );

    test('SyncManifest.countActiveDevices honors the activity window', () {
      final now = DateTime.utc(2026, 10, 27, 12, 0, 0);
      final manifest = SyncManifest(
        epochId: 'test_epoch',
        updatedAt: 1000,
        devices: [
          const SyncDeviceRegistration(
            id: 'dev_recent',
            platform: 'windows',
            deviceName: 'Windows PC',
            lastActive: '2026-10-27T10:00:00Z', // 2 hours ago -> active
          ),
          const SyncDeviceRegistration(
            id: 'dev_month_ago',
            platform: 'android',
            deviceName: 'Old Phone',
            lastActive: '2026-08-01T00:00:00Z', // >30 days ago -> inactive
          ),
          const SyncDeviceRegistration(
            id: 'dev_empty',
            platform: 'android',
            deviceName: 'Ghost',
            lastActive: '', // empty -> inactive
          ),
        ],
      );

      expect(manifest.countActiveDevices(now: now), 1);
    });
  });
}
