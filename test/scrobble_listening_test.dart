import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';

void main() {
  late Duration elapsed;
  late ScrobbleListening listening;
  late List<ScrobbleTrack> announcements;
  late List<(ScrobbleTrack, DateTime)> scrobbles;
  final start = DateTime.utc(2026, 11, 1, 12);
  MediaItem track({
    int instance = 1,
    int? seconds = 240,
    String artist = 'Artist',
  }) => MediaItem(
    id: 'file:///private/song.flac',
    title: 'Song',
    artist: artist,
    album: 'Album',
    duration: seconds == null ? null : Duration(seconds: seconds),
    extras: {'playbackInstance': instance},
  );
  PlaybackState state({
    bool playing = true,
    bool buffering = false,
    int position = 0,
  }) => PlaybackState(
    playing: playing,
    processingState: buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready,
    updatePosition: Duration(seconds: position),
  );

  setUp(() {
    elapsed = Duration.zero;
    announcements = [];
    scrobbles = [];
    listening = ScrobbleListening(
      elapsed: () => elapsed,
      now: () => start.add(elapsed),
      onNowPlaying: announcements.add,
      onScrobble: (track, timestamp) => scrobbles.add((track, timestamp)),
    );
  });

  test('scrobbles at half duration once, with original UTC start time', () {
    listening.update(track(), state(), enabled: true);
    expect(announcements, hasLength(1));
    elapsed = const Duration(seconds: 119);
    listening.tick();
    expect(scrobbles, isEmpty);
    elapsed = const Duration(seconds: 120);
    listening.tick();
    expect(scrobbles.single.$2, start);
    expect(scrobbles.single.$1.toJson(), {
      'track': 'Song',
      'artist': 'Artist',
      'album': 'Album',
      'duration': '240',
    });
    elapsed = const Duration(minutes: 10);
    listening.tick();
    expect(scrobbles, hasLength(1));
  });

  test('half the song counts at any playback speed', () {
    PlaybackState at(double speed) => state().copyWith(speed: speed);
    listening.update(track(), at(2), enabled: true);
    // 60 s at 2x plays 120 s of the 240 s song.
    elapsed = const Duration(seconds: 59);
    listening.tick();
    expect(scrobbles, isEmpty);
    elapsed = const Duration(seconds: 60);
    listening.tick();
    expect(scrobbles, hasLength(1));

    listening.update(track(instance: 2), at(0.5), enabled: true);
    elapsed += const Duration(seconds: 200);
    // A change of speed counts the time before it at the old speed.
    listening.update(track(instance: 2), at(1), enabled: true);
    elapsed += const Duration(seconds: 19);
    listening.tick();
    expect(scrobbles, hasLength(1));
    elapsed += const Duration(seconds: 1);
    listening.tick();
    expect(scrobbles, hasLength(2));
  });

  test('seeking does not add listening time or begin another play', () {
    listening.update(track(), state(), enabled: true);
    elapsed = const Duration(seconds: 10);
    listening.update(track(), state(position: 230), enabled: true);
    expect(scrobbles, isEmpty);
    elapsed = const Duration(seconds: 20);
    listening.update(track(), state(position: 0), enabled: true);
    expect(announcements, hasLength(1));
    elapsed = const Duration(seconds: 120);
    listening.tick();
    expect(scrobbles, hasLength(1));
  });

  test(
    'pause and buffering stop accrual; resume keeps the listening total',
    () {
      listening.update(track(), state(), enabled: true);
      elapsed = const Duration(seconds: 40);
      listening.update(track(), state(playing: false), enabled: true);
      elapsed = const Duration(minutes: 10);
      listening.update(track(), state(buffering: true), enabled: true);
      elapsed += const Duration(seconds: 30);
      listening.update(track(), state(), enabled: true);
      elapsed += const Duration(seconds: 79);
      listening.tick();
      expect(scrobbles, isEmpty);
      elapsed += const Duration(seconds: 1);
      listening.tick();
      expect(scrobbles, hasLength(1));
      expect(scrobbles.single.$2, start);
      expect(announcements, hasLength(2));
    },
  );

  test('short songs are excluded; long songs qualify after four minutes', () {
    listening.update(track(seconds: 30), state(), enabled: true);
    elapsed = const Duration(minutes: 10);
    listening.tick();
    expect(scrobbles, isEmpty);
    listening.update(track(instance: 2, seconds: 900), state(), enabled: true);
    elapsed += const Duration(seconds: 239);
    listening.tick();
    expect(scrobbles, isEmpty);
    elapsed += const Duration(seconds: 1);
    listening.tick();
    expect(scrobbles, hasLength(1));
  });

  test('metadata updates preserve a play and late duration can qualify it', () {
    listening.update(track(seconds: null), state(), enabled: true);
    elapsed = const Duration(seconds: 120);
    listening.update(track(), state(), enabled: true);
    expect(scrobbles, hasLength(1));
    listening.update(
      track().copyWith(title: 'Edited title'),
      state(),
      enabled: true,
    );
    elapsed += const Duration(seconds: 120);
    listening.tick();
    expect(scrobbles, hasLength(1));
    expect(announcements, hasLength(1));
  });

  test('repeat-one is a separate listen even with the same media ID', () {
    listening.update(track(), state(), enabled: true);
    elapsed = const Duration(seconds: 120);
    listening.tick();
    listening.update(track(instance: 2), state(), enabled: true);
    elapsed += const Duration(seconds: 120);
    listening.tick();
    expect(scrobbles, hasLength(2));
    expect(scrobbles.last.$2, start.add(const Duration(seconds: 120)));
    expect(announcements, hasLength(2));
  });

  test('restored paused position and disabled time are not scrobbled', () {
    listening.update(
      track(),
      state(playing: false, position: 200),
      enabled: true,
    );
    elapsed = const Duration(minutes: 20);
    listening.update(track(), state(position: 200), enabled: false);
    elapsed += const Duration(minutes: 10);
    listening.update(track(), state(position: 200), enabled: true);
    expect(scrobbles, isEmpty);
    elapsed += const Duration(seconds: 120);
    listening.tick();
    expect(scrobbles.single.$2, start.add(const Duration(minutes: 30)));
    listening.update(track(), state(), enabled: false);
    listening.update(track(), state(), enabled: true);
    elapsed += const Duration(seconds: 120);
    listening.tick();
    expect(scrobbles, hasLength(1));
  });

  test('missing and localized unknown metadata never leaves the player', () {
    listening.update(track(artist: ''), state(), enabled: true);
    elapsed = const Duration(minutes: 5);
    listening.tick();
    listening.update(
      track(artist: 'Artis tidak dikenal'),
      state(),
      enabled: true,
      unknownArtist: 'Artis tidak dikenal',
    );
    elapsed += const Duration(minutes: 5);
    listening.tick();
    expect(announcements, isEmpty);
    expect(scrobbles, isEmpty);
  });

  test('tagged identifiers travel with the song, invalid ones do not', () {
    MediaItem tagged(Map<String, Object> tags, int instance) => track(
      instance: instance,
    ).copyWith(extras: {'playbackInstance': instance, 'displayMetadata': tags});
    listening.update(
      tagged({'isrc': 'xx-000-00-00001', 'track_number': '3/12'}, 1),
      state(),
      enabled: true,
    );
    listening.update(
      tagged({'isrc': 'not an isrc', 'track': 0}, 2),
      state(),
      enabled: true,
    );
    expect(announcements.first.isrc, 'XX0000000001');
    expect(announcements.first.trackNumber, 3);
    expect(announcements.first.toJson()['isrc'], 'XX0000000001');
    // Last.fm-compatible services keep receiving the fields they always did.
    expect(announcements.first.lastfmParameters.keys, [
      'track',
      'artist',
      'album',
      'duration',
    ]);
    expect(announcements.last.isrc, isNull);
    expect(announcements.last.trackNumber, isNull);
  });
}
