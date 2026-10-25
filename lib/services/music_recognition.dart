import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:mornye/models/recognized_song.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = AppLogger('MusicRecognition');

/// The capture format the fingerprint reads: 16 kHz mono 16-bit PCM.
const recognitionSampleRate = 16000;
const recognitionBytesPerSecond = recognitionSampleRate * 2;

/// Why an attempt ended without a song, while listening may go on.
enum RecognitionMiss {
  /// The service heard nothing it knows.
  noMatch,

  /// Too little level or too few tones to be worth sending.
  quiet,

  /// Under the three seconds a fingerprint needs.
  tooShort,
}

/// Failures the screen explains; raw error text is never shown.
enum RecognitionFailure {
  network,
  rateLimited,
  unavailable,
  notEnoughAudio,
  microphone,
}

sealed class RecognitionResponse {
  const RecognitionResponse();
}

final class RecognitionMatched extends RecognitionResponse {
  const RecognitionMatched(this.song);
  final RecognizedSong song;
}

final class RecognitionMissed extends RecognitionResponse {
  const RecognitionMissed(this.miss);
  final RecognitionMiss miss;
}

final class RecognitionFailed extends RecognitionResponse {
  const RecognitionFailed(this.failure);
  final RecognitionFailure failure;
}

/// The attempt was cancelled; nothing should change on screen.
final class RecognitionCancelled extends RecognitionResponse {
  const RecognitionCancelled();
}

/// Maps the `recognize_song` job's answer. Anything unexpected counts as the
/// service being unavailable.
RecognitionResponse parseRecognitionResponse(
  Map<String, dynamic> result, {
  DateTime? now,
}) {
  switch (result['status']) {
    case 'match':
      final song = RecognizedSong.fromNative(
        result['song'],
        now ?? DateTime.now(),
      );
      return song == null
          ? const RecognitionFailed(RecognitionFailure.unavailable)
          : RecognitionMatched(song);
    case 'no_match':
      return const RecognitionMissed(RecognitionMiss.noMatch);
    case 'quiet':
      return const RecognitionMissed(RecognitionMiss.quiet);
    case 'too_short':
      return const RecognitionMissed(RecognitionMiss.tooShort);
    case 'rate_limited':
      return const RecognitionFailed(RecognitionFailure.rateLimited);
    case 'network':
      return const RecognitionFailed(RecognitionFailure.network);
    default:
      return const RecognitionFailed(RecognitionFailure.unavailable);
  }
}

/// Sends captured audio for recognition.
abstract interface class MusicRecognizer {
  /// Never throws: failures come back as a [RecognitionResponse].
  Future<RecognitionResponse> recognize(
    Uint8List pcm, {
    required String requestId,
  });

  Future<void> cancel(String requestId);
}

/// Fingerprints and asks the service in the Rust backend, off the UI
/// isolate, with the device's locale and time zone.
class NativeMusicRecognizer implements MusicRecognizer {
  const NativeMusicRecognizer();

  @override
  Future<RecognitionResponse> recognize(
    Uint8List pcm, {
    required String requestId,
  }) async {
    final locale = PlatformDispatcher.instance.locale;
    try {
      final result = await PlatformBridge.runNativeDataJob(
        {
          'operation': 'recognize_song',
          'language': locale.languageCode,
          'country': locale.countryCode ?? '',
          'timezone': deviceTimeZoneName(),
        },
        bytes: pcm,
        requestId: requestId,
      );
      return parseRecognitionResponse(result);
    } on PlatformException catch (error) {
      if (error.code == 'CANCELLED' ||
          (error.message ?? '').toLowerCase().contains('cancel')) {
        return const RecognitionCancelled();
      }
      _log.w('Recognition job failed (${error.code})');
      return const RecognitionFailed(RecognitionFailure.unavailable);
    } on Object catch (error) {
      _log.w('Recognition job failed (${error.runtimeType})');
      return const RecognitionFailed(RecognitionFailure.unavailable);
    }
  }

  @override
  Future<void> cancel(String requestId) =>
      PlatformBridge.cancelNativeDataJob(requestId);
}

/// An IANA zone name for the request: `TZ`, then the `/etc/localtime` link,
/// then a whole-hour `Etc/GMT` zone from the current offset, else `UTC`.
/// Android has neither source, so it sends the offset zone.
String deviceTimeZoneName({
  Map<String, String>? environment,
  String? Function()? localtimeTarget,
  Duration? offset,
}) {
  final zone = (environment ?? Platform.environment)['TZ']?.trim() ?? '';
  final named = zone.startsWith(':') ? zone.substring(1) : zone;
  if (_zoneName.hasMatch(named)) return named;
  final target = (localtimeTarget ?? _readLocaltime)();
  final marker = target?.indexOf('zoneinfo/') ?? -1;
  if (target != null && marker >= 0) {
    final linked = target.substring(marker + 'zoneinfo/'.length);
    if (_zoneName.hasMatch(linked)) return linked;
  }
  final minutes = (offset ?? DateTime.now().timeZoneOffset).inMinutes;
  if (minutes == 0 || minutes % 60 != 0 || minutes.abs() > 14 * 60) {
    return 'UTC';
  }
  // Etc zones count the other way: UTC+7 is Etc/GMT-7.
  final hours = minutes ~/ 60;
  return 'Etc/GMT${hours > 0 ? '-' : '+'}${hours.abs()}';
}

final _zoneName = RegExp(r'^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+)+$');

String? _readLocaltime() {
  try {
    return Link('/etc/localtime').targetSync();
  } on Object {
    return null;
  }
}

/// The level of 16-bit little endian PCM, from 0 at -60 dBFS or less to 1
/// at full scale, for the listening animation.
double pcmLevel(Uint8List pcm) {
  final samples = pcm.length ~/ 2;
  if (samples == 0) return 0;
  final data = ByteData.sublistView(pcm);
  var power = 0.0;
  for (var i = 0; i < samples; i++) {
    final sample = data.getInt16(i * 2, Endian.little);
    power += sample * sample;
  }
  final rms = math.sqrt(power / samples) / 32768;
  if (rms <= 0) return 0;
  final db = 20 * math.log(rms) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

enum MicrophoneAccess {
  granted,

  /// Asking again may still show the system prompt.
  denied,

  /// Only the system settings can turn it back on.
  blocked,
}

/// The microphone as the recognition screen uses it.
abstract interface class RecognitionMicrophone {
  /// Asks for access when the person starts listening, never earlier.
  Future<MicrophoneAccess> requestAccess();

  /// 16 kHz mono 16-bit little endian PCM until [stop].
  Future<Stream<Uint8List>> start();

  Future<void> stop();

  /// Whether [openSettings] can show the system microphone settings.
  bool get canOpenSettings;

  Future<void> openSettings();

  Future<void> dispose();
}

/// Captures with the `record` plugin on every platform: AudioRecord on
/// Android, AVFoundation on iOS and macOS, Media Foundation on Windows and
/// `parecord` on Linux.
class RecordMicrophone implements RecognitionMicrophone {
  RecordMicrophone();

  AudioRecorder? _recorder;

  AudioRecorder get _active => _recorder ??= AudioRecorder();

  @override
  Future<MicrophoneAccess> requestAccess() async {
    try {
      if (Platform.isAndroid) {
        final status = await Permission.microphone.request();
        if (status.isGranted || status.isLimited) {
          return MicrophoneAccess.granted;
        }
        return status.isPermanentlyDenied || status.isRestricted
            ? MicrophoneAccess.blocked
            : MicrophoneAccess.denied;
      }
      if (await _active.hasPermission()) return MicrophoneAccess.granted;
      // Apple platforms prompt once; afterwards only Settings can allow it.
      return Platform.isIOS || Platform.isMacOS
          ? MicrophoneAccess.blocked
          : MicrophoneAccess.denied;
    } on Object catch (error) {
      _log.w('Microphone permission check failed (${error.runtimeType})');
      return MicrophoneAccess.denied;
    }
  }

  @override
  Future<Stream<Uint8List>> start() => _active.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: recognitionSampleRate,
      numChannels: 1,
      // Voice processing would filter out the music being identified.
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      // Bluetooth headset routing needs a permission the app does not ask.
      androidConfig: AndroidRecordConfig(manageBluetooth: false),
    ),
  );

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    if (recorder == null) return;
    try {
      await recorder.stop();
    } on Object catch (error) {
      _log.w('Microphone stop failed (${error.runtimeType})');
    }
  }

  @override
  bool get canOpenSettings =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  @override
  Future<void> openSettings() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await openAppSettings();
      } else if (Platform.isMacOS) {
        await launchUrl(
          Uri.parse(
            'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
          ),
        );
      } else if (Platform.isWindows) {
        await launchUrl(Uri.parse('ms-settings:privacy-microphone'));
      }
    } on Object catch (error) {
      _log.w('Could not open microphone settings (${error.runtimeType})');
    }
  }

  @override
  Future<void> dispose() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    try {
      await recorder.dispose();
    } on Object catch (error) {
      _log.w('Microphone release failed (${error.runtimeType})');
    }
  }
}
