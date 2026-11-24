import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_store.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_service.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/lastfm_fakes.dart';
import 'support/scrobble_fakes.dart';

class _CountingPreferences extends InMemorySharedPreferencesStore {
  _CountingPreferences(super.data) : super.withData();

  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes++;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  File queueFile([String key = 'lastfm_scrobbles_v1']) =>
      File('${root.path}/scrobble_queues/$key.json');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('scrobble-store-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => root.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'account session stays in secure storage, outside preferences and queue',
    () async {
      final store = LocalLastfmStore();
      await store.writeSession(lastfmTestSession);
      await store.write(
        enabled: true,
        nowPlaying: false,
        queue: [lastfmQueued(1)],
      );
      final restored = LocalLastfmStore();
      expect((await restored.readSession())?.key, lastfmTestSession.key);
      final state = await restored.read();
      expect(state.enabled, isTrue);
      expect(state.nowPlaying, isFalse);
      expect(state.queue.single.parameters, lastfmQueued(1).parameters);
      final preferences = await SharedPreferences.getInstance();
      for (final key in preferences.getKeys()) {
        expect(
          '${preferences.get(key)}',
          isNot(contains(lastfmTestSession.key)),
        );
      }
      await restored.writeSession(null);
      expect(await store.readSession(), isNull);
    },
  );

  test('a request waiting for approval survives in secure storage', () async {
    final store = LocalLastfmStore();
    expect(await store.readAuthorization(), isNull);
    final created = DateTime.utc(2026, 11, 7, 10);
    await store.writeAuthorization((token: 'request-token', created: created));
    final restored = await LocalLastfmStore().readAuthorization();
    expect(restored?.token, 'request-token');
    expect(restored?.created, created);
    final preferences = await SharedPreferences.getInstance();
    for (final key in preferences.getKeys()) {
      expect('${preferences.get(key)}', isNot(contains('request-token')));
    }
    await store.writeAuthorization(null);
    expect(await store.readAuthorization(), isNull);
    FlutterSecureStorage.setMockInitialValues({
      'lastfm_authorization_v1': '{"token":"","created":1}',
    });
    expect(await LocalLastfmStore().readAuthorization(), isNull);
  });

  test('a Last.fm account saved before other services keeps working', () async {
    // The exact shape 5.3 wrote.
    FlutterSecureStorage.setMockInitialValues({
      'lastfm_session_v1': '{"name":"listener","key":"session-key"}',
    });
    SharedPreferences.setMockInitialValues({
      'lastfm_scrobbles_v1':
          '{"enabled":true,"nowPlaying":false,"queue":[{"id":"1",'
          '"username":"listener","track":{"track":"Song","artist":"Artist",'
          '"duration":"240"},"timestamp":1793534400}]}',
    });
    final store = LocalLastfmStore();
    expect((await store.readSession())?.key, 'session-key');
    final state = await store.read();
    expect(state.enabled, isTrue);
    expect(state.nowPlaying, isFalse);
    final listen = state.queue.single;
    expect(listen.track.isrc, isNull);
    expect(listen.parameters, {
      'track': 'Song',
      'artist': 'Artist',
      'duration': '240',
      'timestamp': '1793534400',
    });
  });

  test('each service keeps its own account and queue', () async {
    final lastfm = LocalLastfmStore();
    final librefm = LocalLastfmStore(prefix: 'librefm');
    final listenBrainz = localListenBrainzStore();
    await lastfm.writeSession(lastfmTestSession);
    await lastfm.write(
      enabled: true,
      nowPlaying: true,
      queue: [lastfmQueued(1)],
    );
    expect(await librefm.readSession(), isNull);
    expect((await librefm.read()).queue, isEmpty);
    await librefm.writeSession(
      const LastfmSession(username: 'other', key: 'other-key'),
    );
    await listenBrainz.writeSession(listenBrainzTestAccount);
    await listenBrainz.write(
      enabled: true,
      nowPlaying: true,
      queue: [
        QueuedScrobble(
          id: '2',
          username: 'listener',
          track: const ScrobbleTrack(
            title: 'Song',
            artist: 'Artist',
            isrc: 'XX0000000001',
            trackNumber: 3,
          ),
          started: DateTime.utc(2026, 11, 1),
        ),
      ],
    );
    expect((await lastfm.readSession())?.key, lastfmTestSession.key);
    expect((await librefm.readSession())?.key, 'other-key');
    expect((await lastfm.read()).queue.single.id, '1');
    final saved = (await listenBrainz.read()).queue.single.track;
    expect(saved.isrc, 'XX0000000001');
    expect(saved.trackNumber, 3);
    expect((await listenBrainz.readSession())?.token, 'test-token');
    final preferences = await SharedPreferences.getInstance();
    for (final key in preferences.getKeys()) {
      expect('${preferences.get(key)}', isNot(contains('test-token')));
      expect('${preferences.get(key)}', isNot(contains('other-key')));
    }
    await librefm.writeSession(null);
    expect((await lastfm.readSession())?.key, lastfmTestSession.key);
  });

  test(
    'new installations opt out and malformed state is not overwritten',
    () async {
      final store = LocalLastfmStore();
      expect((await store.read()).enabled, isFalse);
      expect(await store.readSession(), isNull);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('lastfm_scrobbles_v1', 'invalid');
      await expectLater(store.read(), throwsFormatException);
      expect(preferences.getString('lastfm_scrobbles_v1'), 'invalid');
    },
  );

  const stateKey = 'lastfm_scrobbles_v1';
  String preferenceState(List<QueuedScrobble> queue) => jsonEncode({
    'enabled': true,
    'nowPlaying': false,
    'queue': [for (final entry in queue) entry.toJson()],
  });
  Future<Object?> savedSwitches() async =>
      jsonDecode((await SharedPreferences.getInstance()).getString(stateKey)!);
  Iterable<String> ids(ScrobbleState state) =>
      state.queue.map((entry) => entry.id);

  test('a queue saved in preferences moves to its own file once', () async {
    SharedPreferences.setMockInitialValues({
      stateKey: preferenceState([lastfmQueued(1), lastfmQueued(2)]),
    });
    final state = await LocalLastfmStore().read();
    expect(state.enabled, isTrue);
    expect(state.nowPlaying, isFalse);
    expect(ids(state), ['1', '2']);
    expect(await savedSwitches(), {'enabled': true, 'nowPlaying': false});
    expect(await queueFile().exists(), isTrue);

    final preferences = await SharedPreferences.getInstance();
    final platform = _CountingPreferences({
      'flutter.$stateKey': preferences.getString(stateKey)!,
    });
    SharedPreferencesStorePlatform.instance = platform;
    final restored = await LocalLastfmStore().read();
    expect(restored.queue.map((entry) => entry.parameters), [
      lastfmQueued(1).parameters,
      lastfmQueued(2).parameters,
    ]);
    expect(platform.writes, 0);
  });

  test(
    'the old queue stays in preferences until its file is written',
    () async {
      final old = preferenceState([lastfmQueued(1)]);
      SharedPreferences.setMockInitialValues({stateKey: old});
      final folder = Directory('${root.path}/scrobble_queues')..createSync();
      await Process.run('chmod', ['555', folder.path]);
      addTearDown(() => Process.run('chmod', ['755', folder.path]));
      final store = LocalLastfmStore();
      expect(ids(await store.read()), ['1']);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(stateKey), old);
      final queue = [lastfmQueued(1), lastfmQueued(2)];
      await expectLater(
        store.write(enabled: true, nowPlaying: false, queue: queue),
        throwsA(isA<FileSystemException>()),
      );
      expect(preferences.getString(stateKey), old);

      await Process.run('chmod', ['755', folder.path]);
      await store.write(enabled: true, nowPlaying: false, queue: queue);
      expect(await savedSwitches(), {'enabled': true, 'nowPlaying': false});
      expect(ids(await LocalLastfmStore().read()), ['1', '2']);
    },
  );

  test('a listen writes its queue file and no preference', () async {
    final store = LocalLastfmStore();
    await store.read();
    await store.write(enabled: true, nowPlaying: true, queue: []);
    final preferences = await SharedPreferences.getInstance();
    final platform = _CountingPreferences({
      'flutter.$stateKey': preferences.getString(stateKey)!,
    });
    SharedPreferencesStorePlatform.instance = platform;
    // Saved when it counts, saved again once the service accepts it.
    for (var i = 0; i < 3; i++) {
      await store.write(
        enabled: true,
        nowPlaying: true,
        queue: [lastfmQueued(i)],
      );
      expect(ids(await LocalLastfmStore().read()), ['$i']);
      await store.write(enabled: true, nowPlaying: true, queue: []);
    }
    expect(platform.writes, 0);

    await queueFile().delete();
    await store.write(enabled: true, nowPlaying: false, queue: []);
    expect(platform.writes, 1);
    expect(await queueFile().exists(), isFalse);
  });

  test(
    'an older version keeps the switches and its listens join the file',
    () async {
      final store = LocalLastfmStore();
      await store.read();
      await store.write(
        enabled: true,
        nowPlaying: false,
        queue: [lastfmQueued(1)],
      );
      // An older version reads the switches and finds no queue of its own,
      // then queues a listen in the preference as it always did.
      expect(await savedSwitches(), {'enabled': true, 'nowPlaying': false});
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(stateKey, preferenceState([lastfmQueued(2)]));
      expect(ids(await LocalLastfmStore().read()), ['1', '2']);
      expect(await savedSwitches(), {'enabled': true, 'nowPlaying': false});
    },
  );

  test('a write cut short keeps the previous queue', () async {
    final store = LocalLastfmStore();
    await store.read();
    await store.write(
      enabled: true,
      nowPlaying: true,
      queue: [lastfmQueued(1)],
    );
    File('${queueFile().path}.tmp').writeAsStringSync('{"queue":[{"id":');
    final restored = LocalLastfmStore();
    expect(ids(await restored.read()), ['1']);
    await restored.write(
      enabled: true,
      nowPlaying: true,
      queue: [lastfmQueued(1), lastfmQueued(2)],
    );
    expect(ids(await LocalLastfmStore().read()), ['1', '2']);
  });
}
