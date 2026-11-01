import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/desktop/link_phone_playback.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/link_desktop_fakes.dart';

const _phone = LinkClientInfo(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);
const _paired = LinkPairedDevice(
  deviceId: 'p1',
  name: 'Pixel',
  platform: 'android',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeLinkBackend backend;
  late FakeLinkPhoneLibrary library;
  late Directory folder;
  ProviderContainer? container;
  final sourceId = linkPhoneSourceId('p1');
  final fileId = '${'0' * 31}1';

  setUp(() async {
    debugDesktopPlatformOverride = true;
    backend = FakeLinkBackend()..deviceList = [_paired];
    library = FakeLinkPhoneLibrary();
    folder = await Directory.systemTemp.createTemp('link-phones-host-');
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    debugDesktopPlatformOverride = null;
    await folder.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 500; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting');
  }

  LinkDesktopHost host() => container!.read(linkDesktopHostProvider.notifier);
  LinkDesktopHostState hostState() => container!.read(linkDesktopHostProvider);

  Future<void> boot({bool enabled = true}) async {
    SharedPreferences.setMockInitialValues({
      linkDesktopEnabledKey: enabled,
      linkDesktopNameKey: 'Studio',
    });
    container = ProviderContainer(
      overrides: linkHostOverrides(
        backend: backend,
        player: FakeLinkPlayer(),
        phoneLibrary: library,
        phoneFolder: folder,
      ),
    );
    container!.read(linkDesktopHostProvider);
    await until(
      () =>
          hostState().loaded &&
          (!enabled || (hostState().running && hostState().devices.isNotEmpty)),
    );
  }

  /// Sends a forwarded request and waits for its reply.
  Future<({Object? result, LinkException? error})> request(
    String op,
    Map<String, dynamic> args, {
    String deviceId = 'p1',
  }) async {
    final requestId = 'r${backend.replies.length + 1}';
    backend.request(op, requestId: requestId, deviceId: deviceId, args: args);
    await until(
      () => backend.replies.any((reply) => reply.requestId == requestId),
    );
    final reply = backend.replies.lastWhere(
      (reply) => reply.requestId == requestId,
    );
    return (result: reply.result, error: reply.error);
  }

  Future<void> commit(String version, {String? coverId}) async {
    final reply = await request(LinkOps.phoneCatalog, {
      '_method': 'POST',
      'version': version,
      'offset': 0,
      'total': 1,
      'songs': [
        LinkPhoneSong(
          fileId: fileId,
          suffix: 'flac',
          title: 'Song',
          artist: 'Artist',
          coverId: coverId,
        ).toJson(),
      ],
    });
    expect(reply.error, isNull);
    expect(reply.result, {'ok': true});
  }

  test('a committed list becomes a Library source once', () async {
    await boot();
    expect(
      NetworkStorageService.instance.virtualFor(sourceId),
      isNotNull,
      reason: 'the host installs the phone sources',
    );
    final version = await request(LinkOps.phoneCatalog, {'_method': 'GET'});
    expect(version.result, {'version': null});

    await commit('v1');
    await until(() => library.calls.contains('rescan:$sourceId'));
    expect(library.calls, ['add:$sourceId:Pixel', 'rescan:$sourceId']);
    expect((await request(LinkOps.phoneCatalog, {'_method': 'GET'})).result, {
      'version': 'v1',
    });

    // Later commits only rescan; an owner who removed the source keeps it
    // removed.
    library.calls.clear();
    await commit('v2');
    await until(() => library.calls.isNotEmpty);
    expect(library.calls, ['rescan:$sourceId']);

    container!.dispose();
    container = null;
    expect(NetworkStorageService.instance.virtualSources, isNull);
  });

  test(
    'reconnecting rescans a persisted phone catalog without a new upload',
    () async {
      await boot();
      await commit('v1');
      await until(() => library.calls.contains('rescan:$sourceId'));
      container!.dispose();
      container = null;
      library.calls.clear();

      await boot();
      expect(library.calls, isEmpty);
      backend.connect([_phone]);
      await until(() => library.calls.contains('rescan:$sourceId'));
      expect(library.calls, ['rescan:$sourceId']);
      expect((await request(LinkOps.phoneCatalog, {'_method': 'GET'})).result, {
        'version': 'v1',
      });

      // Repeated client snapshots do not start another scan.
      backend.connect([_phone]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(library.calls, ['rescan:$sourceId']);

      // Another connection retries reconciliation if an earlier scan failed.
      backend.connect([]);
      await until(() => hostState().clients.isEmpty);
      backend.connect([_phone]);
      await until(() => library.calls.length == 2);
      expect(library.calls, ['rescan:$sourceId', 'rescan:$sourceId']);
    },
  );

  test('a cover Library still shows outlives the commit dropping it', () async {
    await boot();
    final coverId = 'c' * 32;
    await request(LinkOps.phoneCovers, {
      '_method': 'POST',
      'covers': [
        {
          'id': coverId,
          'ext': 'jpg',
          'data': base64Encode([0xff, 0xd8, 0xff]),
        },
      ],
    });
    await commit('v1', coverId: coverId);
    final cover = File('${folder.path}/$sourceId/covers/$coverId.jpg');
    library.covers[sourceId] = {cover.path};
    // The covers list answers once the queued removals are done.
    Future<Object?> held() async =>
        (await request(LinkOps.phoneCovers, {'_method': 'GET'})).result;

    await commit('v2');
    expect(await held(), {
      'ids': [coverId],
    }, reason: 'rows still name it');
    expect(cover.existsSync(), isTrue);

    // Older than the v2 list, as coarse file times can give both the same
    // time.
    library.covers.remove(sourceId);
    cover.setLastModifiedSync(DateTime(2000));
    await request(LinkOps.phoneCatalog, {'_method': 'GET'});
    expect(await held(), {'ids': <String>[]});
    expect(cover.existsSync(), isFalse);
  });

  test(
    'a followed phone receives covers after its first player state',
    () async {
      await boot();
      backend.connect([_phone]);
      container!.listen(linkFollowedPhonePlaybackProvider, (_, _) {});
      const track = TrackRef(
        title: 'Song',
        artist: 'Artist',
        durationMs: 200000,
      );
      backend.message('p1', {
        'type': LinkMessageTypes.playerState,
        'state': LinkPlayerState(
          track: track,
          queue: const [track],
          index: 0,
          playing: true,
          positionMs: 0,
          updatedMs: 0,
        ).toJson(),
      });
      await until(() => hostState().followedPhone == 'p1');
      final playback = container!.read(linkFollowedPhonePlaybackProvider)!;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await playback.mediaItems.first)!.artUri, isNull);

      final coverId = 'c' * 32;
      final cover = await request(LinkOps.phoneCovers, {
        '_method': 'POST',
        'covers': [
          {
            'id': coverId,
            'ext': 'jpg',
            'data': base64Encode([0xff, 0xd8, 0xff]),
          },
        ],
      });
      expect(cover.error, isNull);
      await commit('with-cover', coverId: coverId);
      final item = await playback.mediaItems
          .firstWhere((item) => item?.artUri != null)
          .timeout(const Duration(seconds: 2));
      expect(item!.title, 'Song');
      expect(
        item.artUri!.toFilePath(),
        endsWith('/$sourceId/covers/$coverId.jpg'),
      );
      expect((await playback.queues.first).single.artUri, item.artUri);
      expect(hostState().phoneCatalogRevisions['p1'], 1);
      expect(
        identical(playback, container!.read(linkFollowedPhonePlaybackProvider)),
        isTrue,
      );
    },
  );

  test('a device that is not a paired phone cannot send songs', () async {
    backend.deviceList = [
      _paired,
      const LinkPairedDevice(
        deviceId: 'app',
        name: 'Player app',
        platform: 'subsonic',
      ),
    ];
    await boot();
    for (final deviceId in ['stranger', 'app']) {
      final reply = await request(LinkOps.phoneCovers, {
        '_method': 'POST',
        'covers': <Object>[],
      }, deviceId: deviceId);
      expect(reply.error?.code, 'invalid', reason: deviceId);
    }
    expect(library.calls, isEmpty);
    expect(folder.listSync(), isEmpty);
  });

  test('unpairing removes the source and the songs', () async {
    await boot();
    await commit('v1');
    await until(() => library.calls.contains('rescan:$sourceId'));
    expect(Directory('${folder.path}/$sourceId').existsSync(), isTrue);

    await host().revoke('p1');
    await until(() => library.calls.contains('remove:$sourceId'));
    await until(() => !Directory('${folder.path}/$sourceId').existsSync());
  });

  test('a phone song plays by asking the connected phone', () async {
    await boot();
    final source = NetworkStorageService.source(sourceId, '$fileId.flac');
    await expectLater(
      NetworkStorageService.instance.resolve(source),
      throwsA(
        isA<LinkException>().having(
          (error) => error.message,
          'message',
          contains('not connected'),
        ),
      ),
    );

    backend.connect([_phone]);
    await until(() => hostState().clients.isNotEmpty);
    final resolved = NetworkStorageService.instance.resolve(source);
    await until(
      () => backend.sentOfType(LinkMessageTypes.filesRequest).isNotEmpty,
    );
    final sent = backend.sent.lastWhere(
      (entry) => entry.message['type'] == LinkMessageTypes.filesRequest,
    );
    expect(sent.deviceId, 'p1');
    expect(sent.message['name'], '$fileId.flac');

    backend.message('p1', {
      'type': LinkMessageTypes.filesFailed,
      'name': '$fileId.flac',
      'reason': 'gone',
    });
    await expectLater(resolved, throwsA(isA<LinkException>()));
    // The answer is not taken for a phone player state.
    expect(hostState().phoneStates, isEmpty);
  });

  test('songs scanned before the first export are scanned again', () async {
    await boot(enabled: false);
    final sources = NetworkStorageService.instance.virtualFor(sourceId)!;
    expect(await sources.songs(sourceId).toList(), isEmpty);
    expect(library.calls, isEmpty);

    await host().setEnabled(true);
    await until(() => library.calls.contains('rescan:$sourceId'));
  });
}
