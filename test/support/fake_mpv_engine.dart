import 'dart:async';

import 'package:mornye/services/media_kit_playback_deck.dart';

/// An in-memory libmpv for `MediaKitPlaybackDeck` tests on any host.
class FakeMpvEngine implements MpvEngine {
  final calls = <List<String>>[];
  final properties = <String, String>{};
  final completedEvents = StreamController<bool>.broadcast();
  final durationEvents = StreamController<Duration>.broadcast();
  final sampleRateEvents = StreamController<int>.broadcast();
  final errorEvents = StreamController<MpvLogError>.broadcast();
  @override
  Duration position = Duration.zero;
  double volume = 100;

  /// Duration reported when a source opens, or an error line instead.
  Duration? openDuration = const Duration(seconds: 90);
  MpvLogError? openError;
  Completer<void>? openBarrier;
  bool rejectFilters = false;

  /// The device refuses exclusive access: a source opened while
  /// `audio-exclusive` is on reports its duration, then loses its audio.
  bool refuseExclusive = false;
  bool disposed = false;

  @override
  Stream<bool> get completed => completedEvents.stream;
  @override
  Stream<Duration> get duration => durationEvents.stream;
  @override
  Stream<int> get sampleRate => sampleRateEvents.stream;
  @override
  Stream<MpvLogError> get errors => errorEvents.stream;

  @override
  Future<void> open(String source) async {
    calls.add(['open', source]);
    if (openBarrier case final barrier?) await barrier.future;
    scheduleMicrotask(() {
      if (openError case final error?) {
        errorEvents.add(error);
      } else if (openDuration case final value?) {
        durationEvents.add(value);
      }
      if (refuseExclusive &&
          (properties['audio-exclusive'] == 'yes' ||
              (properties['audio-device'] ?? '').startsWith('alsa/'))) {
        errorEvents
          ..add((
            prefix: 'ao',
            text: "Failed to initialize audio driver 'wasapi'",
          ))
          ..add((
            prefix: 'cplayer',
            text: 'Could not open/initialize audio device -> no sound.',
          ));
      }
    });
  }

  @override
  Future<void> play() async => calls.add(['play']);
  @override
  Future<void> pause() async => calls.add(['pause']);
  @override
  Future<void> seek(Duration position) async {
    calls.add(['seek', '${position.inMilliseconds}']);
    this.position = position;
  }

  @override
  Future<void> stop() async => calls.add(['stop']);
  @override
  Future<void> setVolume(double volume) async => this.volume = volume;
  @override
  Future<void> setSpeed(double speed) async => calls.add(['speed', '$speed']);

  /// libavfilter filters this libmpv lacks; mpv rejects `lavfi-NAME`.
  Set<String> missingFilters = {};

  @override
  Future<int> setProperty(String name, String value) async {
    calls.add(['set', name, value]);
    if (name == 'af') {
      if (missingFilters.any((filter) => value.contains('lavfi-$filter'))) {
        return -9;
      }
      if (rejectFilters && value.startsWith('@mornye_format')) return -7;
    }
    properties[name] = value;
    return 0;
  }

  @override
  Future<String> getProperty(String name) async => properties[name] ?? '';

  @override
  Future<void> command(List<String> args) async =>
      calls.add(['command', ...args]);

  @override
  Future<void> dispose() async {
    disposed = true;
    await completedEvents.close();
    await durationEvents.close();
    await sampleRateEvents.close();
    await errorEvents.close();
  }

  Iterable<List<String>> get filterWrites =>
      calls.where((call) => call[0] == 'set' && call[1] == 'af');
}
