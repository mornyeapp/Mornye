import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/sync/link_sound_sync_handlers.dart';
import 'package:mornye/services/link/sync/link_sound_sync_protocol.dart';
import 'package:mornye/services/link/sync/link_sound_sync_runner.dart';
import 'package:mornye/services/link/sync/link_sound_sync_store.dart';

import 'support/link_sync_support.dart';

Map<String, dynamic> _curve(double first) =>
    EqualizerSettings(gains: [first, 0, 0, 0, 0, 0, 0, 0, 0, 0]).toJson();

LinkSoundId _preset(String name) => (LinkSoundKinds.eqPreset, name);
LinkSoundId _setting(String key) => (LinkSoundKinds.setting, key);
LinkSoundId _song(String key) => (LinkSoundKinds.songLyricOffset, key);

final _songA = songLyricsOffsetKey('Example Song', 'Example Artist');
final _songB = songLyricsOffsetKey('Other Song', 'Example Artist');

/// One device's presets and settings in memory.
class _FakeAccess implements LinkSoundSettingsAccess {
  final presets = <String, Map<String, dynamic>>{};
  final settings = Map<String, Object>.of(
    linkSoundSettingValues(const AppSettings()),
  );

  /// Song lyric offsets by song key, and when each was set or removed.
  final songs = <String, int>{};
  final edited = <String, int>{};
  bool unreadable = false;
  int applied = 0;

  /// Sets a song's offset at [at]; 0 puts it back in sync.
  void setSong(String key, int offsetMs, int at) {
    if (offsetMs == 0) {
      songs.remove(key);
    } else {
      songs[key] = offsetMs;
    }
    edited[key] = at;
  }

  @override
  Future<LinkSoundValues?> read() async => unreadable
      ? null
      : {
          for (final MapEntry(:key, :value) in presets.entries)
            _preset(key): {'settings': value},
          for (final MapEntry(:key, :value) in settings.entries)
            _setting(key): {'value': value},
          for (final MapEntry(:key, :value) in songs.entries)
            _song(key): {'offsetMs': value},
        };

  @override
  int? editedMs(LinkSoundId id) =>
      id.$1 == LinkSoundKinds.songLyricOffset ? edited[id.$2] : null;

  @override
  LinkSoundValues get defaults => {
    for (final MapEntry(:key, :value) in linkSoundSettingValues(
      const AppSettings(),
    ).entries)
      _setting(key): {'value': value},
  };

  @override
  Future<void> apply(List<LinkSoundItem> winners) async {
    for (final item in winners) {
      applied++;
      if (item.kind == LinkSoundKinds.songLyricOffset) {
        setSong(
          item.key,
          item.deleted ? 0 : item.data!['offsetMs'] as int,
          item.updatedMs,
        );
      } else if (item.kind == LinkSoundKinds.eqPreset) {
        if (item.deleted) {
          presets.remove(item.key);
        } else {
          presets[item.key] = Map<String, dynamic>.from(
            item.data!['settings'] as Map,
          );
        }
      } else {
        settings[item.key] = item.data!['value'] as Object;
      }
    }
  }
}

/// A clock both devices share, one millisecond per reading.
class _Clock {
  int now = 1000;
  int call() => now++;
}

typedef _Device = ({_FakeAccess access, LinkSoundSync sync});

_Device _device(_Clock clock) {
  final access = _FakeAccess();
  return (
    access: access,
    sync: LinkSoundSync(
      access: access,
      storage: LinkSoundMemoryStorage(),
      clock: clock.call,
    ),
  );
}

/// One phone-style round: the phone sends everything, the desktop merges
/// and answers, the phone merges the answer. Over a JSON wire.
Future<void> _exchange(LinkSoundSync phone, LinkSoundSync desk) async {
  final mine = await phone.exchange(const []);
  final sent = LinkSoundItem.listFromJson(
    linkJsonRoundTrip([for (final item in mine.items) item.toJson()]),
  );
  final reply = await desk.exchange(sent);
  await phone.exchange(
    LinkSoundItem.listFromJson(
      linkJsonRoundTrip([for (final item in reply.items) item.toJson()]),
    ),
  );
}

/// Routes the phone's requests to the desktop handlers over a JSON wire.
class _FakeClient implements LinkClientApi {
  _FakeClient(this._router);

  final LinkHostRouter _router;
  final states = StreamController<LinkConnectionState>.broadcast();
  final pushed = StreamController<Map<String, dynamic>>.broadcast();
  final posts = <Map<String, dynamic>>[];
  LinkConnectionState state = LinkConnectionState.connected;
  var _requests = 0;

  @override
  LinkServerRecord get server => const LinkServerRecord(
    serverId: 'desk-1',
    name: 'Desk',
    connectionId: 'connection-1',
    address: 'https://desk.local:47710',
    fingerprint: 'ab',
  );

  @override
  LinkConnectionState get connectionState => state;

  @override
  Stream<LinkConnectionState> get connectionStates => states.stream;

  @override
  Stream<Map<String, dynamic>> get messages => pushed.stream;

  @override
  void send(Map<String, dynamic> message) {}

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) =>
      throw UnimplementedError();

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) async {
    final wire = linkJsonRoundTrip(body)! as Map<String, dynamic>;
    posts.add(wire);
    return linkJsonRoundTrip(
      await _router.dispatch(
        LinkRequest(
          requestId: 'r${_requests++}',
          op: op,
          deviceId: 'phone-device',
          args: {...wire, '_method': 'POST'},
        ),
      ),
    );
  }

  @override
  Future<void> upload(
    String name,
    File file, {
    void Function(int sent)? onProgress,
  }) => throw UnimplementedError();

  Future<void> close() async {
    await states.close();
    await pushed.close();
  }
}

const _timing = LinkSoundSyncSettings(
  localDebounce: Duration(milliseconds: 20),
  messageDebounce: Duration(milliseconds: 10),
);

Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for sound sync');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('items', () {
    test('keep only what this app can use, normalized', () {
      final items = LinkSoundItem.listFromJson([
        {
          'kind': 'eqPreset',
          'key': ' Night ',
          'updatedMs': 5,
          'origin': 'a',
          'data': {
            'settings': {
              'gains': [3, 0, 0, 0, 0],
            },
          },
        },
        // Seven bands is no band count this app has.
        {
          'kind': 'eqPreset',
          'key': 'Odd',
          'updatedMs': 5,
          'origin': 'a',
          'data': {
            'settings': {'gains': List.filled(7, 0)},
          },
        },
        {
          'kind': 'setting',
          'key': 'playbackNormalizationPreamp',
          'updatedMs': 5,
          'data': {'value': 40},
        },
        {
          'kind': 'setting',
          'key': 'playbackSpeed',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'value': 1.5},
        },
        {
          'kind': 'setting',
          'key': 'autoMixEffect',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'value': 'unknown'},
        },
        {'kind': 'eqPreset', 'key': 'Gone', 'updatedMs': 6, 'deleted': true},
        {'kind': 'outputDevice', 'key': 'x', 'updatedMs': 1, 'origin': 'a'},
      ], fallbackOrigin: 'peer');
      expect(items.map((item) => item.key), [
        'Night',
        'playbackNormalizationPreamp',
        'Gone',
      ]);
      expect((items[0].data!['settings'] as Map)['gains'], [3, 0, 0, 0, 0]);
      expect(items[0].data!['settings'], containsPair('limiter', true));
      expect(items[1].origin, 'peer');
      expect(items[1].data, {'value': 6.0});
      expect(items[2].deleted, isTrue);
      expect(items[2].data, isNull);
    });

    test('song offsets keep a song key and a usable offset', () {
      final items = LinkSoundItem.listFromJson([
        {
          'kind': 'songLyricOffset',
          'key': ' Example Song|Example Artist ',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'offsetMs': 9000},
        },
        {
          'kind': 'songLyricOffset',
          'key': 'other song|',
          'updatedMs': 6,
          'origin': 'a',
          'deleted': true,
        },
        // In sync is only ever a deletion.
        {
          'kind': 'songLyricOffset',
          'key': 'third song|artist',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'offsetMs': 0},
        },
        // No title, no separator, no number.
        {
          'kind': 'songLyricOffset',
          'key': '|artist',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'offsetMs': 500},
        },
        {
          'kind': 'songLyricOffset',
          'key': 'no separator',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'offsetMs': 500},
        },
        {
          'kind': 'songLyricOffset',
          'key': 'song|artist',
          'updatedMs': 5,
          'origin': 'a',
          'data': {'offsetMs': 'late'},
        },
      ]);
      expect(items.map((item) => item.key), [
        'example song|example artist',
        'other song|',
      ]);
      expect(items[0].data, {'offsetMs': 2000});
      expect(items[1].deleted, isTrue);
      expect(items[1].data, isNull);
    });

    test('compare numbers by value, not by how they are written', () {
      expect(
        linkSoundCanonical({
          'b': [6, 1],
          'a': 1,
        }),
        linkSoundCanonical({
          'a': 1.0,
          'b': [6.0, 1.0],
        }),
      );
    });
  });

  group('merge', () {
    test('presets edited on different devices both survive', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      phone.access.presets['Phone'] = _curve(3);
      desk.access.presets['Desk'] = _curve(-3);
      await _exchange(phone.sync, desk.sync);
      expect(phone.access.presets.keys, unorderedEquals(['Phone', 'Desk']));
      expect(desk.access.presets.keys, unorderedEquals(['Phone', 'Desk']));

      // Each side then edits a different preset; both edits arrive.
      phone.access.presets['Phone'] = _curve(5);
      desk.access.presets['Desk'] = _curve(-5);
      await _exchange(phone.sync, desk.sync);
      expect(desk.access.presets['Phone'], _curve(5));
      expect(phone.access.presets['Desk'], _curve(-5));
    });

    test('the later edit of one preset wins on both devices', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      phone.access.presets['Rock'] = _curve(1);
      await _exchange(phone.sync, desk.sync);
      desk.access.presets['Rock'] = _curve(2);
      await desk.sync.captureLocal();
      phone.access.presets['Rock'] = _curve(4);
      await phone.sync.captureLocal();
      await _exchange(phone.sync, desk.sync);
      expect(desk.access.presets['Rock'], _curve(4));
      expect(phone.access.presets['Rock'], _curve(4));
    });

    test('a deleted preset does not come back from an older copy', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      final other = _device(clock);
      phone.access.presets['Old'] = _curve(2);
      await _exchange(phone.sync, desk.sync);
      await _exchange(other.sync, desk.sync);
      expect(other.access.presets.keys, ['Old']);

      phone.access.presets.remove('Old');
      await _exchange(phone.sync, desk.sync);
      expect(desk.access.presets, isEmpty);

      // The other phone still holds the old copy and offers it.
      await _exchange(other.sync, desk.sync);
      expect(desk.access.presets, isEmpty);
      expect(other.access.presets, isEmpty);
      await _exchange(phone.sync, desk.sync);
      expect(phone.access.presets, isEmpty);
    });

    test(
      'a value left at its default does not override a chosen one',
      () async {
        final clock = _Clock();
        final phone = _device(clock);
        final desk = _device(clock);
        desk.access.settings[LinkSoundSettingKeys.normalizationPreamp] = -6.0;
        desk.access.settings[LinkSoundSettingKeys.autoMixEffect] =
            AutoMixEffect.echo.name;
        await desk.sync.captureLocal();
        // The phone is seen later, but its values were never changed.
        await _exchange(phone.sync, desk.sync);
        expect(
          phone.access.settings[LinkSoundSettingKeys.normalizationPreamp],
          -6.0,
        );
        expect(
          phone.access.settings[LinkSoundSettingKeys.autoMixEffect],
          'echo',
        );
        expect(
          desk.access.settings[LinkSoundSettingKeys.normalizationPreamp],
          -6.0,
        );
      },
    );

    test('an unreadable preset list deletes nothing', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      phone.access.presets['Keep'] = _curve(1);
      await _exchange(phone.sync, desk.sync);
      phone.access
        ..presets.clear()
        ..unreadable = true;
      await _exchange(phone.sync, desk.sync);
      expect(desk.access.presets.keys, ['Keep']);
    });

    test('a quiet second exchange applies nothing', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      phone.access.presets['A'] = _curve(1);
      await _exchange(phone.sync, desk.sync);
      final applied = phone.access.applied + desk.access.applied;
      final again = await desk.sync.exchange(
        (await phone.sync.exchange(const [])).items,
      );
      expect(again.applied, 0);
      expect(again.captured, 0);
      expect(phone.access.applied + desk.access.applied, applied);
    });

    test('state survives a restart', () async {
      final clock = _Clock();
      final access = _FakeAccess()..presets['A'] = _curve(1);
      final storage = LinkSoundMemoryStorage();
      final first = LinkSoundSync(
        access: access,
        storage: storage,
        clock: clock.call,
      );
      final device = await first.deviceId();
      await first.captureLocal();
      final second = LinkSoundSync(
        access: access,
        storage: storage,
        clock: clock.call,
      );
      expect(await second.deviceId(), device);
      // Nothing changed meanwhile, so nothing is stamped again.
      expect(await second.captureLocal(), 0);
      access.presets.remove('A');
      expect(await second.captureLocal(), 1);
      final items = (await second.exchange(const [])).items;
      expect(items.singleWhere((item) => item.key == 'A').deleted, isTrue);
    });
  });

  group('song lyric offsets', () {
    test('the newest edit of a song wins, dated by when it was set', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      phone.access.setSong(_songA, 500, clock.now);
      await _exchange(phone.sync, desk.sync);
      expect(desk.access.songs, {_songA: 500});

      // The phone changes it while apart, then the computer changes it
      // later. The phone only meets the computer after both edits.
      clock.now += 1000;
      phone.access.setSong(_songA, 800, clock.now);
      clock.now += 1000;
      desk.access.setSong(_songA, -300, clock.now);
      await desk.sync.captureLocal();
      clock.now += 5000;
      await _exchange(phone.sync, desk.sync);
      expect(phone.access.songs, {_songA: -300});
      expect(desk.access.songs, {_songA: -300});
    });

    test('a song put back in sync stays in sync everywhere', () async {
      final clock = _Clock();
      final phone = _device(clock);
      final desk = _device(clock);
      final other = _device(clock);
      phone.access.setSong(_songA, 500, clock.now);
      await _exchange(phone.sync, desk.sync);
      await _exchange(other.sync, desk.sync);
      expect(other.access.songs, {_songA: 500});

      phone.access.setSong(_songA, 0, clock.now);
      await _exchange(phone.sync, desk.sync);
      expect(desk.access.songs, isEmpty);
      final tombstone = (await desk.sync.exchange(
        const [],
      )).items.singleWhere((item) => item.id == _song(_songA));
      expect(tombstone.deleted, isTrue);

      // The other phone still holds the old offset and offers it.
      await _exchange(other.sync, desk.sync);
      expect(desk.access.songs, isEmpty);
      expect(other.access.songs, isEmpty);
      await _exchange(phone.sync, desk.sync);
      expect(phone.access.songs, isEmpty);
    });

    test(
      'songs set on different devices both survive every exchange',
      () async {
        final clock = _Clock();
        final phone = _device(clock);
        final desk = _device(clock);
        phone.access.setSong(_songA, 500, clock.now);
        desk.access.setSong(_songB, -500, clock.now);
        for (var round = 0; round < 3; round++) {
          await _exchange(phone.sync, desk.sync);
          expect(phone.access.songs, {_songA: 500, _songB: -500});
          expect(desk.access.songs, {_songA: 500, _songB: -500});
          final sent = (await phone.sync.exchange(const [])).items;
          expect(
            sent.where((item) => item.kind == LinkSoundKinds.songLyricOffset),
            hasLength(2),
          );
        }
      },
    );
  });

  group('phone and desktop', () {
    final deskRouter = Provider<LinkHostRouter>((ref) {
      final router = LinkHostRouter();
      registerLinkSoundSyncHandlers(
        router,
        ref,
        notifyPhones: () => ref.read(_notified.notifier).bump(),
      );
      return router;
    });

    ({ProviderContainer container, _FakeAccess access}) side(
      _Clock clock, {
      bool enabled = false,
    }) {
      final access = _FakeAccess();
      final container = ProviderContainer(
        overrides: [
          linkSoundSyncProvider.overrideWithValue(
            LinkSoundSync(
              access: access,
              storage: LinkSoundMemoryStorage(),
              clock: clock.call,
            ),
          ),
          linkSoundSyncSettingsProvider.overrideWithValue(_timing),
          linkSoundSyncOptionProvider.overrideWith(
            () => LinkSoundSyncOptionNotifier(
              initial: LinkSoundSyncOption(loaded: true, enabled: enabled),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      // Runs first: a settings read still under way when the container goes
      // away only adds noise.
      addTearDown(
        () => container.read(settingsProvider.notifier).ensureLoaded(),
      );
      return (container: container, access: access);
    }

    test('nothing travels while the switch is off', () async {
      final clock = _Clock();
      final desk = side(clock);
      final phone = side(clock);
      phone.access.presets['Phone'] = _curve(2);
      final client = _FakeClient(desk.container.read(deskRouter));
      addTearDown(client.close);
      phone.container.read(linkSoundSyncRunnerProvider);
      phone.container.read(linkActiveClientProvider.notifier).set(client);
      await phone.container
          .read(linkSoundSyncRunnerProvider.notifier)
          .syncNow();
      client.pushed.add({'type': LinkSoundSyncMessages.preferencesChanged});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.posts, isEmpty);
      expect(desk.access.presets, isEmpty);
    });

    test(
      'turning it on syncs, then edits and notices travel both ways',
      () async {
        final clock = _Clock();
        final desk = side(clock);
        final phone = side(clock);
        phone.access.presets['Phone'] = _curve(2);
        desk.access.presets['Desk'] = _curve(-2);
        final client = _FakeClient(desk.container.read(deskRouter));
        addTearDown(client.close);
        phone.container.read(linkSoundSyncRunnerProvider);
        phone.container.read(linkActiveClientProvider.notifier).set(client);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.posts, isEmpty);

        phone.container
            .read(linkSoundSyncOptionProvider.notifier)
            .setEnabled(true);
        await _eventually(() => phone.access.presets.containsKey('Desk'));
        expect(desk.access.presets.keys, unorderedEquals(['Phone', 'Desk']));
        // One preset and the nine settings.
        expect(client.posts.single['items'], hasLength(10));
        expect(desk.container.read(_notified), greaterThan(0));

        // A desktop edit arrives after its notice.
        desk.access.presets['Desk'] = _curve(-6);
        await desk.container.read(linkSoundSyncProvider).captureLocal();
        client.pushed.add({'type': LinkSoundSyncMessages.preferencesChanged});
        await _eventually(
          () => (phone.access.presets['Desk']!['gains'] as List).first == -6,
        );

        // A phone edit is sent after the quiet time.
        phone.access.settings[LinkSoundSettingKeys.autoMixEcho] = true;
        await phone.container.read(settingsProvider.notifier).ensureLoaded();
        phone.container.read(settingsProvider.notifier).setAutoMixEcho(true);
        await _eventually(
          () => desk.access.settings[LinkSoundSettingKeys.autoMixEcho] == true,
        );

        // Turning it off stops syncing and keeps everything.
        phone.container
            .read(linkSoundSyncOptionProvider.notifier)
            .setEnabled(false);
        final posts = client.posts.length;
        client.pushed.add({'type': LinkSoundSyncMessages.preferencesChanged});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(client.posts, hasLength(posts));
        expect(phone.access.presets.keys, unorderedEquals(['Phone', 'Desk']));
      },
    );

    test('a song offset set on the phone reaches the computer', () async {
      final clock = _Clock();
      final desk = side(clock);
      final phone = side(clock, enabled: true);
      final client = _FakeClient(desk.container.read(deskRouter));
      addTearDown(client.close);
      phone.container.read(linkSoundSyncRunnerProvider);
      phone.container.read(linkActiveClientProvider.notifier).set(client);
      await _eventually(() => client.posts.isNotEmpty);

      // The player sets the offset; the runner notices the edit.
      phone.access.setSong(_songA, 700, clock.now);
      await phone.container
          .read(songLyricsOffsetsProvider.notifier)
          .setOffsetMs(_songA, 700);
      await _eventually(() => desk.access.songs[_songA] == 700);
    });

    test('an older computer without the operation is left alone', () async {
      final clock = _Clock();
      final phone = side(clock, enabled: true);
      final client = _FakeClient(LinkHostRouter());
      addTearDown(client.close);
      phone.container.read(linkSoundSyncRunnerProvider);
      phone.container.read(linkActiveClientProvider.notifier).set(client);
      await _eventually(() => client.posts.isNotEmpty);
      final notifier = phone.container.read(
        linkSoundSyncRunnerProvider.notifier,
      );
      await notifier.syncNow();
      expect(client.posts, hasLength(1));
      // A new connection tries once more.
      client.states.add(LinkConnectionState.connected);
      await _eventually(() => client.posts.length == 2);
    });

    test('the desktop rejects a request that is not a list', () async {
      final desk = side(_Clock());
      final router = desk.container.read(deskRouter);
      await expectLater(
        router.dispatch(
          const LinkRequest(
            requestId: 'r',
            op: LinkSoundSyncOps.preferences,
            deviceId: 'phone-device',
            args: {'_method': 'POST', 'items': 'none'},
          ),
        ),
        throwsA(isA<LinkException>().having((e) => e.code, 'code', 'invalid')),
      );
    });
  });

  group('app providers', () {
    test('read and apply presets and settings', () async {
      SharedPreferences.setMockInitialValues({
        EqualizerController.storageKey: jsonEncode({
          'settings': const EqualizerSettings().toJson(),
          'presets': [
            EqualizerPreset(
              'First',
              EqualizerSettings(gains: List.filled(10, 1)),
            ).toJson(),
            EqualizerPreset(
              'Second',
              EqualizerSettings(gains: List.filled(15, 2)),
            ).toJson(),
          ],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(equalizerProvider, (_, _) {});
      final access = container.read(linkSoundSettingsAccessProvider);
      final values = (await access.read())!;
      expect(values.keys.where((id) => id.$1 == LinkSoundKinds.eqPreset), [
        _preset('First'),
        _preset('Second'),
      ]);
      expect(
        values[_setting(LinkSoundSettingKeys.autoMixEffect)],
        access.defaults[_setting(LinkSoundSettingKeys.autoMixEffect)],
      );

      LinkSoundItem preset(String name, {Map<String, dynamic>? curve}) =>
          LinkSoundItem(
            kind: LinkSoundKinds.eqPreset,
            key: name,
            updatedMs: 10,
            origin: 'peer',
            deleted: curve == null,
            data: curve == null ? null : {'settings': curve},
          );
      LinkSoundItem setting(String key, Object value) => LinkSoundItem(
        kind: LinkSoundKinds.setting,
        key: key,
        updatedMs: 10,
        origin: 'peer',
        data: {'value': value},
      );
      await access.apply([
        preset('First'),
        preset('Second', curve: _curve(4)),
        preset('Third', curve: _curve(-4)),
        setting(LinkSoundSettingKeys.normalizationPreamp, -3.0),
        setting(LinkSoundSettingKeys.normalizationMode, 'album'),
        setting(LinkSoundSettingKeys.autoMixEffect, 'pitch'),
        setting(LinkSoundSettingKeys.autoMixPitch, -1.0),
        setting(LinkSoundSettingKeys.autoMixDuration, 12),
        setting(LinkSoundSettingKeys.autoMixLowPass, true),
        setting(LinkSoundSettingKeys.autoMixMatching, 'more'),
      ]);
      final presets = container.read(equalizerProvider).presets;
      expect(presets.map((preset) => preset.name), ['Second', 'Third']);
      expect(presets.first.settings.gains.first, 4);
      final settings = container.read(settingsProvider);
      expect(settings.playbackNormalizationPreamp, -3);
      expect(settings.playbackNormalizationMode, 'album');
      expect(settings.autoMixEffect, AutoMixEffect.pitch);
      // The synced pitch stands, not the one choosing the effect suggests.
      expect(settings.autoMixPitch, -1);
      expect(settings.autoMixDuration, 12);
      expect(settings.autoMixLowPass, isTrue);
      expect(settings.autoMixMatching, AutoMixMatching.more);
      // The curve playing now is not touched.
      expect(container.read(equalizerProvider).settings.gains, everyElement(0));

      // Choosing the pitch effect alone keeps this device's pitch.
      container
          .read(settingsProvider.notifier)
          .setAutoMixEffect(AutoMixEffect.auto);
      container.read(settingsProvider.notifier).setAutoMixPitch(0);
      await access.apply([
        setting(LinkSoundSettingKeys.autoMixEffect, 'pitch'),
      ]);
      expect(container.read(settingsProvider).autoMixPitch, 0);
    });

    test('read, date and apply song lyric offsets', () async {
      SharedPreferences.setMockInitialValues({
        kSongLyricsOffsetsKey: jsonEncode({
          _songA: [400, 50],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(songLyricsOffsetsProvider, (_, _) {});
      final access = container.read(linkSoundSettingsAccessProvider);
      final values = (await access.read())!;
      expect(values[_song(_songA)], {'offsetMs': 400});
      expect(access.editedMs(_song(_songA)), 50);
      expect(access.editedMs(_setting(LinkSoundSettingKeys.autoMixEcho)), null);

      // A song put back in sync here is dated by when that happened.
      final songs = container.read(songLyricsOffsetsProvider.notifier);
      await songs.setOffsetMs(_songA, 0);
      expect((await access.read())!.containsKey(_song(_songA)), isFalse);
      expect(access.editedMs(_song(_songA)), isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kSongLyricsOffsetsKey), isNull);

      // A song this device has never played keeps the synced value.
      LinkSoundItem song(String key, int? offsetMs, int at) => LinkSoundItem(
        kind: LinkSoundKinds.songLyricOffset,
        key: key,
        updatedMs: at,
        origin: 'peer',
        deleted: offsetMs == null,
        data: offsetMs == null ? null : {'offsetMs': offsetMs},
      );
      await access.apply([song(_songA, -600, 70), song(_songB, 900, 80)]);
      expect(container.read(songLyricsOffsetMsProvider(_songA)), -600);
      expect(container.read(songLyricsOffsetMsProvider(_songB)), 900);
      expect(access.editedMs(_song(_songB)), 80);
      expect(decodeSongLyricsOffsets(prefs.getString(kSongLyricsOffsetsKey)), {
        _songA: const SongLyricsOffset(-600, 70),
        _songB: const SongLyricsOffset(900, 80),
      });

      await access.apply([song(_songB, null, 90)]);
      expect(container.read(songLyricsOffsetsProvider).keys, [_songA]);
      expect(access.editedMs(_song(_songB)), 90);
    });
  });
}

class _Counter extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final _notified = NotifierProvider<_Counter, int>(_Counter.new);
