import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/automix_analysis.dart';

Uint8List drumPattern(double bpm, {double phase = 0.17, bool fade = false}) {
  const sampleRate = 11025;
  final bytes = ByteData(sampleRate * 24 * 2);
  final random = math.Random(7);
  for (var i = 0; i < sampleRate * 24; i++) {
    final time = i / sampleRate;
    final sinceBeat = (time - phase) % (60 / bpm);
    final transient = time < phase ? 0.0 : math.exp(-sinceBeat * 50);
    final gain = fade ? 0.03 + 0.97 * math.pow(time / 24, 3) : 1.0;
    final value =
        0.75 * gain * transient * math.sin(time * 2 * math.pi * 100) +
        (random.nextDouble() - 0.5) * 0.003;
    bytes.setInt16(i * 2, (value * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  for (final bpm in [90.0, 120.0, 124.0, 160.0]) {
    test('detects $bpm BPM and beat phase from audio', () {
      final grid = analyzeAutoMixPcm(drumPattern(bpm));
      expect(grid.reliable, isTrue, reason: '${grid.bpm}, ${grid.confidence}');
      expect(grid.bpm, closeTo(bpm, 0.75));
      expect(grid.beatAtOrAfter(0), closeTo(0.17, 0.04));
    });
  }

  test('silence and unstructured noise do not invent a reliable beat', () {
    expect(analyzeAutoMixPcm(Uint8List(11025 * 24 * 2)).reliable, isFalse);
    final random = math.Random(11);
    final noise = ByteData(11025 * 24 * 2);
    for (var i = 0; i < noise.lengthInBytes; i += 2) {
      noise.setInt16(i, random.nextInt(32000) - 16000, Endian.little);
    }
    expect(analyzeAutoMixPcm(noise.buffer.asUint8List()).reliable, isFalse);
  });

  test('changing dynamics retain a reliable pulse and the quiet intro', () {
    for (final bpm in [90.0, 120.0, 124.0, 160.0]) {
      final grid = analyzeAutoMixPcm(drumPattern(bpm, fade: true));
      expect(grid.reliable, isTrue, reason: '$bpm: ${grid.confidence}');
      expect(grid.bpm, closeTo(bpm, 0.4));
      expect(grid.firstSound, lessThan(0.3));
    }
  });

  AutoMixBeatGrid grid(double bpm, {double confidence = 0.9}) =>
      AutoMixBeatGrid(
        bpm: bpm,
        phase: 0.17,
        confidence: confidence,
        firstSound: 0.1,
      );

  AutoMixPlan plan(double from, double to, {double confidence = 0.9}) =>
      AutoMixPlan.create(
        outgoingDuration: const Duration(seconds: 180),
        incomingDuration: const Duration(seconds: 200),
        outro: grid(from, confidence: confidence),
        intro: grid(to),
        outroOffset: 156,
      )!;

  test('compatible tempi align outgoing and incoming beats', () {
    final transition = plan(120, 124);
    expect(transition.beatMatched, isTrue);
    expect(transition.fallbackReason, isNull);
    expect(transition.rate, closeTo(120 / 124, 0.00001));
    final beat = (transition.start.inMicroseconds / 1e6 - 156.17) / 0.5;
    expect(beat, closeTo(beat.round(), 0.00001));
    expect(transition.incomingStart.inMilliseconds, 170);
    expect(
      transition.start + transition.duration,
      lessThanOrEqualTo(const Duration(seconds: 180)),
    );
  });

  test('crossfade diagnostics distinguish each fallback condition', () {
    expect(
      plan(120, 160).fallbackReason,
      AutoMixFallbackReason.incompatibleTempo,
    );
    expect(
      plan(120, 124, confidence: 0.2).fallbackReason,
      AutoMixFallbackReason.unreliableBeats,
    );
    AutoMixPlan? transition({
      AutoMixBeatGrid? intro,
      AutoMixOptions options = const AutoMixOptions(),
    }) => AutoMixPlan.create(
      outgoingDuration: const Duration(minutes: 3),
      incomingDuration: const Duration(minutes: 3),
      outro: grid(120),
      intro: intro,
      options: options,
    );
    expect(
      transition()!.fallbackReason,
      AutoMixFallbackReason.analysisUnavailable,
    );
    expect(
      transition(
        options: const AutoMixOptions(effect: AutoMixEffect.crossfade),
      )!.fallbackReason,
      AutoMixFallbackReason.crossfadePreset,
    );
    final late = transition(
      intro: const AutoMixBeatGrid(
        bpm: 120,
        phase: 0.17,
        confidence: 0.9,
        firstSound: 14,
      ),
    )!;
    expect(late.fallbackReason, AutoMixFallbackReason.longIntro);
    expect(late.beatMatched, isFalse);
    expect(late.incomingStart, Duration.zero);
  });

  test('a looser matching level takes confirmed beats and a wider tempo', () {
    AutoMixPlan at(
      AutoMixMatching matching, {
      double confidence = 0.9,
      bool confirmed = false,
      double to = 124,
    }) => AutoMixPlan.create(
      outgoingDuration: const Duration(seconds: 180),
      incomingDuration: const Duration(seconds: 200),
      outro: grid(120),
      intro: AutoMixBeatGrid(
        bpm: to,
        phase: 0.17,
        confidence: confidence,
        firstSound: 0.1,
        confirmed: confirmed,
      ),
      outroOffset: 156,
      options: AutoMixOptions(matching: matching),
    )!;
    // A beat one window is sure of mixes at every level.
    for (final matching in AutoMixMatching.values) {
      expect(at(matching).beatMatched, isTrue);
    }
    // A less certain one needs a second window, and a level that takes it.
    for (final (confidence, levels) in [
      (0.45, [AutoMixMatching.more, AutoMixMatching.most]),
      (0.32, [AutoMixMatching.most]),
      (0.28, <AutoMixMatching>[]),
    ]) {
      for (final matching in AutoMixMatching.values) {
        expect(
          at(matching, confidence: confidence, confirmed: true).beatMatched,
          levels.contains(matching),
          reason: '$confidence at ${matching.name}',
        );
        expect(
          at(matching, confidence: confidence).fallbackReason,
          AutoMixFallbackReason.unreliableBeats,
        );
      }
    }
    // Slowing 131, 135 and 138 BPM to 120 changes them 8.4%, 11.1% and 13%.
    for (final (to, levels) in [
      (131.0, [AutoMixMatching.more, AutoMixMatching.most]),
      (135.0, [AutoMixMatching.most]),
      (138.0, <AutoMixMatching>[]),
    ]) {
      for (final matching in AutoMixMatching.values) {
        expect(
          at(matching, to: to).fallbackReason,
          levels.contains(matching)
              ? isNull
              : AutoMixFallbackReason.incompatibleTempo,
          reason: '$to at ${matching.name}',
        );
      }
    }
  });

  test('incompatible or uncertain beats use unstretched crossfade', () {
    for (final transition in [
      plan(120, 160),
      plan(120, 124, confidence: 0.2),
    ]) {
      expect(transition.beatMatched, isFalse);
      expect(transition.rate, 1);
      expect(transition.incomingStart, Duration.zero);
    }
    expect(
      AutoMixPlan.create(
        outgoingDuration: const Duration(seconds: 10),
        incomingDuration: const Duration(minutes: 2),
      ),
      isNull,
    );
  });

  test(
    'measured fallback gets a bass handoff without inventing beat alignment',
    () {
      expect(plan(120, 160).assisted, isTrue);
      expect(plan(120, 124, confidence: 0.35).assisted, isTrue);
      expect(plan(120, 124, confidence: 0.1).assisted, isFalse);
      for (final effect in [AutoMixEffect.crossfade, AutoMixEffect.echo]) {
        final transition = AutoMixPlan.create(
          outgoingDuration: const Duration(minutes: 3),
          incomingDuration: const Duration(minutes: 3),
          outro: grid(120, confidence: 0.35),
          intro: grid(124),
          options: AutoMixOptions(effect: effect),
        )!;
        expect(transition.assisted, isFalse);
        expect(transition.beatMatched, isFalse);
        expect(transition.rate, 1);
      }
      final failed = plan(120, 124).withoutBeatMatching();
      expect(failed.rate, 1);
      expect(failed.beatMatched, isFalse);
      expect(failed.fallbackReason, AutoMixFallbackReason.alignmentUnverified);
    },
  );

  test('a custom outgoing tempo cannot claim the original beat grid', () {
    final transition = AutoMixPlan.create(
      outgoingDuration: const Duration(minutes: 3),
      incomingDuration: const Duration(minutes: 3),
      outro: grid(120),
      intro: grid(124),
      options: const AutoMixOptions(effect: AutoMixEffect.custom, speed: 1.1),
    )!;
    expect(transition.beatMatched, isFalse);
    expect(transition.fallbackReason, AutoMixFallbackReason.effectTempo);
  });

  test('a silent lead-in does not prevent reliable beat matching', () {
    final transition = AutoMixPlan.create(
      outgoingDuration: const Duration(minutes: 3),
      incomingDuration: const Duration(minutes: 3),
      outro: grid(120),
      intro: const AutoMixBeatGrid(
        bpm: 124,
        phase: 0.17,
        confidence: 0.9,
        firstSound: 5,
      ),
    )!;
    expect(transition.beatMatched, isTrue);
    expect(
      transition.incomingStart.inMilliseconds,
      inInclusiveRange(5000, 5500),
    );
    expect(transition.rate, closeTo(120 / 124, 0.00001));
  });

  test('equal-power overlap restores normal tempo smoothly', () {
    final transition = plan(120, 124);
    final start = autoMixEnvelope(Duration.zero, transition);
    expect(start.outgoing, 1);
    expect(start.incoming, 0);
    final middle = autoMixEnvelope(transition.duration ~/ 2, transition);
    expect(
      middle.outgoing * middle.outgoing + middle.incoming * middle.incoming,
      closeTo(1, 0.00001),
    );
    expect(middle.rate, transition.rate);
    final recovery = autoMixEnvelope(
      transition.duration + const Duration(seconds: 4),
      transition,
    );
    expect(recovery.rate, closeTo((transition.rate + 1) / 2, 0.00001));
    final end = autoMixEnvelope(
      transition.duration + const Duration(seconds: 8),
      transition,
    );
    expect(end.complete, isTrue);
    expect(end.rate, 1);
    expect(end.incoming, 1);
    expect(end.outgoing, closeTo(0, 0.00001));
  });

  test('AutoMix is off for new and existing settings, and persists opt-in', () {
    expect(const AppSettings().autoMix, isFalse);
    expect(AppSettings.fromJson({}).autoMix, isFalse);
    final enabled = const AppSettings().copyWith(autoMix: true);
    expect(AppSettings.fromJson(enabled.toJson()).autoMix, isTrue);
    expect(enabled.copyWith(autoMix: false).autoMix, isFalse);
  });
}
