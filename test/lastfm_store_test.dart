import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_store.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_service.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/lastfm_fakes.dart';
import 'support/scrobble_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

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
}
