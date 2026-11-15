import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/utils/loud_volume_guard.dart';

void main() {
  const level = 0.8;

  test('off never holds or asks', () {
    final guard = LoudVolumeGuard();
    expect(guard.request(from: 0.2, to: 1, level: null), (
      value: 1.0,
      ask: false,
    ));
    expect(guard.asking, isFalse);
  });

  test('moves at or below the level pass', () {
    final guard = LoudVolumeGuard();
    expect(guard.request(from: 0.2, to: 0.5, level: level).ask, isFalse);
    expect(guard.request(from: 0.5, to: 0.8, level: level), (
      value: 0.8,
      ask: false,
    ));
    // A float that comes back from the platform a hair above still counts.
    expect(guard.request(from: 0.8, to: 0.80001, level: level).ask, isFalse);
  });

  test('crossing the level holds there and asks once', () {
    final guard = LoudVolumeGuard()..startGesture();
    expect(guard.request(from: 0.5, to: 0.95, level: level), (
      value: 0.8,
      ask: true,
    ));
    expect(guard.asking, isTrue);
    // The finger keeps moving while the dialog is open: held, no second ask.
    expect(guard.request(from: 0.8, to: 1, level: level), (
      value: 0.8,
      ask: false,
    ));
    expect(guard.request(from: 0.8, to: 0.9, level: level), (
      value: 0.8,
      ask: false,
    ));
    // Confirming applies where the finger was last.
    expect(guard.answer(confirmed: true), 0.9);
    expect(guard.asking, isFalse);
    // Above the level now, so the bar moves freely.
    expect(guard.request(from: 0.9, to: 1, level: level), (
      value: 1.0,
      ask: false,
    ));
  });

  test('moving below the level while asking follows the finger', () {
    final guard = LoudVolumeGuard()..startGesture();
    expect(guard.request(from: 0.5, to: 0.9, level: level).ask, isTrue);
    expect(guard.request(from: 0.8, to: 0.6, level: level), (
      value: 0.6,
      ask: false,
    ));
    expect(guard.answer(confirmed: true), 0.6);
  });

  test('cancel holds at the level for the rest of the touch', () {
    final guard = LoudVolumeGuard()..startGesture();
    expect(guard.request(from: 0.5, to: 0.95, level: level).ask, isTrue);
    expect(guard.answer(confirmed: false), isNull);
    expect(guard.request(from: 0.8, to: 1, level: level), (
      value: 0.8,
      ask: false,
    ));
    // The next touch asks again.
    guard.startGesture();
    expect(guard.request(from: 0.8, to: 1, level: level), (
      value: 0.8,
      ask: true,
    ));
  });

  test('a new touch while asking does not forget the open dialog', () {
    final guard = LoudVolumeGuard()..startGesture();
    expect(guard.request(from: 0.5, to: 0.95, level: level).ask, isTrue);
    guard.startGesture();
    expect(guard.request(from: 0.8, to: 1, level: level).ask, isFalse);
    expect(guard.asking, isTrue);
  });

  test('a volume already above the level moves freely, then re-arms', () {
    final guard = LoudVolumeGuard()..startGesture();
    // Volume buttons or a restored session left it at 95%.
    expect(guard.request(from: 0.95, to: 0.9, level: level), (
      value: 0.9,
      ask: false,
    ));
    expect(guard.request(from: 0.9, to: 1, level: level).ask, isFalse);
    // Back to the level or below, then up again: asks.
    expect(guard.request(from: 1, to: 0.7, level: level).ask, isFalse);
    expect(guard.request(from: 0.7, to: 0.85, level: level), (
      value: 0.8,
      ask: true,
    ));
  });

  test('saved levels outside the choices read as the default', () {
    expect(loudVolumeLevelFromJson(70), 70);
    expect(loudVolumeLevelFromJson(75), 80);
    expect(loudVolumeLevelFromJson(90.0), 80);
    expect(loudVolumeLevelFromJson('90'), 80);
    expect(loudVolumeLevelFromJson(null), 80);
    expect(const AppSettings().confirmLoudVolume, isTrue);
    expect(const AppSettings().loudVolumeLevel, 80);
    expect(AppSettings.fromJson(const {}).confirmLoudVolume, isTrue);
    final restored = AppSettings.fromJson(
      const AppSettings(confirmLoudVolume: false, loudVolumeLevel: 60).toJson(),
    );
    expect(restored.confirmLoudVolume, isFalse);
    expect(restored.loudVolumeLevel, 60);
  });
}
