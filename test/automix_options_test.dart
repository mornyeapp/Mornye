import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/automix_analysis.dart';

void main() {
  test(
    'existing settings retain automatic mixing and sanitize invalid controls',
    () {
      expect(AppSettings.fromJson({}).autoMixOptions, const AutoMixOptions());
      final restored = AppSettings.fromJson({
        'autoMixDuration': 999,
        'autoMixEffect': 'unknown',
        'autoMixSpeed': -9,
        'autoMixPitch': 88,
        'autoMixMatching': 'unknown',
      });
      expect(restored.autoMixMatching, AutoMixMatching.standard);
      expect(restored.autoMixDuration, 60);
      expect(restored.autoMixEffect, AutoMixEffect.auto);
      expect(restored.autoMixSpeed, 0.8);
      expect(restored.autoMixPitch, 6);
      expect(autoMixDurationFromJson(double.nan), 0);
      expect(autoMixPitchFromJson(double.infinity), 0);
      const selected = AppSettings(
        autoMixDuration: 30,
        autoMixEffect: AutoMixEffect.custom,
        autoMixSpeed: 1.1,
        autoMixPitch: 2,
        autoMixEcho: true,
        autoMixLowPass: true,
        autoMixMatching: AutoMixMatching.most,
      );
      expect(selected.autoMixOptions.matching, AutoMixMatching.most);
      expect(
        AppSettings.fromJson(selected.toJson()).autoMixOptions,
        selected.autoMixOptions,
      );
    },
  );

  test(
    'manual overlap supports 60 seconds and clamps to half of shorter song',
    () {
      AutoMixPlan plan(int outgoing, int incoming) => AutoMixPlan.create(
        outgoingDuration: Duration(seconds: outgoing),
        incomingDuration: Duration(seconds: incoming),
        options: const AutoMixOptions(durationSeconds: 60),
      )!;
      expect(plan(200, 240).duration, const Duration(seconds: 60));
      expect(plan(40, 30).duration, const Duration(seconds: 15));
      expect(plan(200, 240).start, const Duration(seconds: 140));
    },
  );

  test(
    'crossfade ignores reliable beats; manual beat match retains selected length',
    () {
      const grid = AutoMixBeatGrid(
        bpm: 120,
        phase: 0,
        confidence: 0.9,
        firstSound: 0,
      );
      for (final effect in [AutoMixEffect.auto, AutoMixEffect.crossfade]) {
        final plan = AutoMixPlan.create(
          outgoingDuration: const Duration(seconds: 180),
          incomingDuration: const Duration(seconds: 200),
          outro: grid,
          intro: grid,
          options: AutoMixOptions(durationSeconds: 30, effect: effect),
        )!;
        expect(plan.duration, const Duration(seconds: 30));
        expect(plan.beatMatched, effect != AutoMixEffect.crossfade);
      }
    },
  );
}
