import 'package:flutter/services.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AudioRoute');

/// Output route and platform stream facts for the audio information sheet.
/// Every field is optional: platforms and releases expose different subsets.
class AudioRouteInfo {
  const AudioRouteInfo({
    this.platform,
    this.mixerSampleRate,
    this.framesPerBuffer,
    this.ioBufferMs,
    this.outputLatencyMs,
    this.outputChannels,
    this.lowLatency,
    this.proAudio,
    this.volume,
    this.maxVolume,
    this.fixedVolume,
    this.device,
    this.spatialAvailable,
    this.spatialEnabled,
    this.headTracking,
    this.stream,
  });

  factory AudioRouteInfo.fromMap(Map<dynamic, dynamic> map) {
    final device = map['device'];
    final spatial = map['spatializer'];
    final stream = map['stream'];
    return AudioRouteInfo(
      platform: map['platform'] as String?,
      mixerSampleRate: _int(map['mixerSampleRate']),
      framesPerBuffer: _int(map['framesPerBuffer']),
      ioBufferMs: _double(map['ioBufferMs']),
      outputLatencyMs: _double(map['outputLatencyMs']),
      outputChannels: _int(map['outputChannels']),
      lowLatency: map['lowLatency'] as bool?,
      proAudio: map['proAudio'] as bool?,
      volume: (map['volume'] as num?)?.toDouble(),
      maxVolume: _int(map['maxVolume']),
      fixedVolume: map['fixedVolume'] as bool?,
      device: device is Map ? AudioRouteDevice.fromMap(device) : null,
      spatialAvailable: spatial is Map ? spatial['available'] as bool? : null,
      spatialEnabled: spatial is Map
          ? spatial['enabled'] as bool?
          : device is Map
          ? device['spatial'] as bool?
          : null,
      headTracking: spatial is Map ? spatial['headTracking'] as bool? : null,
      stream: stream is Map ? AudioRouteStream.fromMap(stream) : null,
    );
  }

  final String? platform;

  /// Platform output rate. Android reports the default low-latency PCM rate,
  /// which does not measure the negotiated Bluetooth codec format.
  final int? mixerSampleRate;
  final int? framesPerBuffer;
  final double? ioBufferMs;
  final double? outputLatencyMs;
  final int? outputChannels;
  final bool? lowLatency;
  final bool? proAudio;

  /// Android: stream steps out of [maxVolume]. iOS: a 0–1 fraction.
  final double? volume;
  final int? maxVolume;
  final bool? fixedVolume;
  final AudioRouteDevice? device;
  final bool? spatialAvailable;
  final bool? spatialEnabled;
  final bool? headTracking;
  final AudioRouteStream? stream;

  /// Android's PCM properties and device capabilities do not describe the
  /// negotiated A2DP or LE Audio transport format.
  bool get bluetoothFormatUnreported =>
      platform == 'android' && device?.isBluetooth == true;

  /// Mixer buffer duration in milliseconds, from frames on Android.
  double? get bufferMs {
    if (ioBufferMs != null) return ioBufferMs;
    final frames = framesPerBuffer, rate = mixerSampleRate;
    if (frames == null || rate == null || rate <= 0) return null;
    return frames * 1000 / rate;
  }
}

class AudioRouteDevice {
  const AudioRouteDevice({
    required this.type,
    this.name = '',
    this.sampleRates = const [],
    this.bitDepths = const [],
    this.floatOutput = false,
    this.mixerSampleRate,
    this.mixerBitDepth,
    this.mixerBitPerfect,
  });

  factory AudioRouteDevice.fromMap(Map<dynamic, dynamic> map) {
    final mixer = map['mixer'];
    return AudioRouteDevice(
      type: map['type'] as String? ?? 'other',
      name: (map['name'] as String? ?? '').trim(),
      sampleRates: _ints(map['sampleRates']),
      bitDepths: _ints(map['bitDepths']),
      floatOutput: map['float'] == true,
      mixerSampleRate: mixer is Map ? _int(mixer['sampleRate']) : null,
      mixerBitDepth: mixer is Map ? _int(mixer['bitDepth']) : null,
      mixerBitPerfect: mixer is Map ? mixer['bitPerfect'] as bool? : null,
    );
  }

  /// speaker, wired_headphones, bluetooth, usb, airplay, … (see natives).
  final String type;
  final String name;

  bool get isBluetooth =>
      const {'bluetooth', 'bluetooth_le', 'hearing_aid'}.contains(type);

  /// Empty when the device accepts any rate the mixer offers.
  final List<int> sampleRates;
  final List<int> bitDepths;
  final bool floatOutput;
  final int? mixerSampleRate;
  final int? mixerBitDepth;
  final bool? mixerBitPerfect;
}

class AudioRouteStream {
  const AudioRouteStream({
    this.mime,
    this.sampleRate,
    this.channels,
    this.bitrate,
    this.pcmBits,
    this.decoder,
    this.hardwareDecoder,
  });

  factory AudioRouteStream.fromMap(Map<dynamic, dynamic> map) =>
      AudioRouteStream(
        mime: map['mime'] as String?,
        sampleRate: _int(map['sampleRate']),
        channels: _int(map['channels']),
        bitrate: _int(map['bitrate']),
        pcmBits: _int(map['pcmBits']),
        decoder: map['decoder'] as String?,
        hardwareDecoder: map['hardwareDecoder'] as bool?,
      );

  /// MIME type on Android (audio/flac), a format code on iOS (flac, alac).
  final String? mime;
  final int? sampleRate;
  final int? channels;

  /// Bits per second.
  final int? bitrate;
  final int? pcmBits;
  final String? decoder;
  final bool? hardwareDecoder;
}

int? _int(Object? value) => value is num && value > 0 ? value.toInt() : null;

double? _double(Object? value) =>
    value is num && value > 0 ? value.toDouble() : null;

List<int> _ints(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is num && item > 0) item.toInt(),
      ]
    : const [];

const _channel = MethodChannel('com.zarz.mornye/audio_route');

/// Reads the current route; [path] adds what the platform decoder sees for a
/// local file. Returns null where the platform has no implementation.
Future<AudioRouteInfo?> readAudioRouteInfo({String? path}) async {
  try {
    final map = await _channel.invokeMapMethod<String, dynamic>('read', {
      'path': ?path,
    });
    return map == null ? null : AudioRouteInfo.fromMap(map);
  } on MissingPluginException {
    return null;
  } catch (error) {
    _log.w('Failed to read audio route: $error');
    return null;
  }
}
