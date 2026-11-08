import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SpatialAudio');

/// Where the Spatial audio setting exists. Windows and Linux leave spatial
/// audio to the system, so they have none.
enum SpatialAudioPlatform { android, ios, macos, none }

/// Overrides [spatialAudioPlatform] in tests.
@visibleForTesting
SpatialAudioPlatform? debugSpatialAudioPlatformOverride;

SpatialAudioPlatform get spatialAudioPlatform {
  final override = debugSpatialAudioPlatformOverride;
  if (override != null) return override;
  if (isDesktopPlatform) {
    return defaultTargetPlatform == TargetPlatform.macOS
        ? SpatialAudioPlatform.macos
        : SpatialAudioPlatform.none;
  }
  if (Platform.isAndroid) return SpatialAudioPlatform.android;
  if (Platform.isIOS) return SpatialAudioPlatform.ios;
  return SpatialAudioPlatform.none;
}

/// What the platform reports about spatial audio for the current output.
/// Every field is optional: releases expose different subsets.
class SpatialAudioState {
  const SpatialAudioState({
    this.platform,
    this.available,
    this.enabled,
    this.headTracking,
    this.stereo,
    this.multichannel,
  });

  /// Android sends its `Spatializer` facts (API 32 and later, otherwise
  /// none), iOS whether the output port has spatial audio enabled.
  factory SpatialAudioState.fromMap(Map<dynamic, dynamic> map) {
    final platform = map['platform'] as String?;
    final spatializer = map['spatializer'];
    if (platform == 'android') {
      if (spatializer is! Map) {
        return const SpatialAudioState(platform: 'android', available: false);
      }
      return SpatialAudioState(
        platform: platform,
        available: spatializer['available'] as bool?,
        enabled: spatializer['enabled'] as bool?,
        headTracking: spatializer['headTracking'] as bool?,
        stereo: spatializer['stereo'] as bool?,
        multichannel: spatializer['multichannel'] as bool?,
      );
    }
    return SpatialAudioState(
      platform: platform,
      enabled: map['enabled'] as bool?,
    );
  }

  final String? platform;

  /// Android: the spatializer exists and the output can use it.
  final bool? available;

  /// Android: the system setting. iOS: spatial audio on the output port.
  final bool? enabled;
  final bool? headTracking;

  /// Android: ordinary stereo music can be spatialized on this output.
  final bool? stereo;

  /// Android: 5.1 audio can be spatialized on this output.
  final bool? multichannel;
}

/// What the system does with songs while the Spatial audio setting is on.
enum SpatialAudioStatus {
  /// Android: the direct USB path bypasses the platform mixer.
  directUsb,

  /// Android: AAudio exclusive bypasses the platform mixer.
  directAAudio,

  /// macOS: hog mode plays through libmpv, never AVPlayer.
  exclusiveOutput,
  systemOff,
  unavailable,
  stereo,
  stereoHeadTracking,
  multichannelOnly,

  /// iOS: the output port has spatial audio enabled.
  outputOn,

  /// iOS: it does not (unsupported, or off in Control Center).
  outputOff,
}

/// Null while the setting is off or nothing is known.
SpatialAudioStatus? spatialAudioStatus({
  required bool enabled,
  required SpatialAudioPlatform platform,
  SpatialAudioState? state,
  UsbAudioStatus? usb,
  bool exclusiveOutput = false,
}) {
  if (!enabled) return null;
  switch (platform) {
    case SpatialAudioPlatform.none:
      return null;
    case SpatialAudioPlatform.macos:
      return exclusiveOutput ? SpatialAudioStatus.exclusiveOutput : null;
    case SpatialAudioPlatform.ios:
      final on = state?.enabled;
      if (on == null) return null;
      return on ? SpatialAudioStatus.outputOn : SpatialAudioStatus.outputOff;
    case SpatialAudioPlatform.android:
      if (usb?.reason == 'active') {
        return usb?.driver == 'aaudio_exclusive'
            ? SpatialAudioStatus.directAAudio
            : SpatialAudioStatus.directUsb;
      }
      if (state == null) return null;
      if (state.available != true) return SpatialAudioStatus.unavailable;
      if (state.enabled == false) return SpatialAudioStatus.systemOff;
      if (state.stereo == true) {
        return state.headTracking == true
            ? SpatialAudioStatus.stereoHeadTracking
            : SpatialAudioStatus.stereo;
      }
      if (state.multichannel == true) {
        return SpatialAudioStatus.multichannelOnly;
      }
      return SpatialAudioStatus.unavailable;
  }
}

String spatialAudioStatusLabel(
  AppLocalizations l10n,
  SpatialAudioStatus status,
) => switch (status) {
  SpatialAudioStatus.directUsb => l10n.spatialAudioDirectUsb,
  SpatialAudioStatus.directAAudio => l10n.spatialAudioDirectAAudio,
  SpatialAudioStatus.exclusiveOutput => l10n.spatialAudioExclusive,
  SpatialAudioStatus.systemOff => l10n.spatialAudioSystemOff,
  SpatialAudioStatus.unavailable => l10n.spatialAudioUnavailable,
  SpatialAudioStatus.stereo => l10n.spatialAudioStereo,
  SpatialAudioStatus.stereoHeadTracking => l10n.spatialAudioStereoHeadTracking,
  SpatialAudioStatus.multichannelOnly => l10n.spatialAudioMultichannelOnly,
  SpatialAudioStatus.outputOn => l10n.spatialAudioOutputOn,
  SpatialAudioStatus.outputOff => l10n.spatialAudioOutputOff,
};

const _events = EventChannel('com.zarz.mornye/spatial_audio');

/// The current state on listen, then each change the platform reports
/// (spatializer state, head tracker, output devices on Android; route and
/// spatial capability changes on iOS). Empty where nothing reports it.
Stream<SpatialAudioState> spatialAudioStates(SpatialAudioPlatform platform) {
  if (platform != SpatialAudioPlatform.android &&
      platform != SpatialAudioPlatform.ios) {
    return const Stream.empty();
  }
  return _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => SpatialAudioState.fromMap(event as Map))
      .handleError((Object error) {
        if (error is! MissingPluginException) {
          _log.w('Spatial audio state unavailable: $error');
        }
      });
}
