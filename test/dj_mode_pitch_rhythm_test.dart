import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/automix_effect_renderer.dart';

void main() {
  group('DJ Mode Pitch & Rhythm Blending', () {
    test('extended BPM rhythm matching accepts differences up to 15%', () {
      // 120 BPM vs 132 BPM is a 10% tempo difference (previously rejected at > 8%)
      const outgoing = AutoMixBeatGrid(
        bpm: 120.0,
        confidence: 0.9,
        phase: 0.2,
        firstSound: 0.1,
        lastSound: 29.5,
      );
      const incoming = AutoMixBeatGrid(
        bpm: 132.0, // 120 / 132 = ~0.909, difference is ~9.1%
        confidence: 0.9,
        phase: 0.1,
        firstSound: 0.1,
        lastSound: 29.5,
      );

      final plan = AutoMixPlan.create(
        outgoingDuration: const Duration(seconds: 180),
        incomingDuration: const Duration(seconds: 180),
        outro: outgoing,
        intro: incoming,
      );

      expect(plan, isNotNull);
      expect(plan!.beatMatched, isTrue);
      expect(plan.rate, closeTo(120.0 / 132.0, 0.01));
    });

    test(
      'harmonic key pitch shift calculates correct semitone transposition',
      () {
        // Outgoing track in C major (key = 0), incoming in D major (key = 2)
        // Difference is -2 semitones
        const outgoing = AutoMixBeatGrid(
          bpm: 120.0,
          confidence: 0.9,
          phase: 0.0,
          firstSound: 0.1,
          lastSound: 29.5,
        );
        const incoming = AutoMixBeatGrid(
          bpm: 120.0,
          confidence: 0.9,
          phase: 0.0,
          firstSound: 0.1,
          lastSound: 29.5,
        );

        final plan = AutoMixPlan.create(
          outgoingDuration: const Duration(seconds: 180),
          incomingDuration: const Duration(seconds: 180),
          outro: outgoing,
          intro: incoming,
          outgoingKey: 0,
          incomingKey: 2,
        );

        expect(plan, isNotNull);
        expect(plan!.harmonicPitchShift, -2.0);

        // Verify envelope smoothly recovers pitch
        final env = autoMixEnvelope(const Duration(seconds: 2), plan);
        expect(env.pitch, closeTo(0.8908, 0.05)); // 2^(-2/12) is ~0.8908
      },
    );

    test(
      'vinylBrake effect options and renderer filters generate turntable slow-down',
      () {
        const options = AutoMixOptions(effect: AutoMixEffect.vinylBrake);
        expect(options.hasEffects, isTrue);
        expect(options.effect, AutoMixEffect.vinylBrake);

        final filters = autoMixEffectFilters(
          options,
          const Duration(seconds: 8),
        );
        expect(filters, contains('asetrate=48000*max(0.05,1-pow('));
        expect(filters, contains('aresample=48000'));
      },
    );
  });
}
