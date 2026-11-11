import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/music_playback_deck.dart';

String usbOutputStatusLabel(
  AppLocalizations l10n,
  UsbAudioStatus status,
) => switch (status.reason) {
  'active' when status.sampleRate != null && status.bitDepth != null =>
    '${status.device ?? 'USB'} · ${status.lossy ? '${l10n.usbOutputLossySource(status.codec ?? '?')} · ' : ''}${status.transport == 'pcm'
        ? '${status.bitDepth}-bit PCM'
        : status.transport == 'dop'
        ? 'DSD (DoP)'
        : 'DSD (Native)'} · ${(status.sampleRate! / 1000).toStringAsFixed(1)} kHz',
  'ready' => l10n.usbOutputReady,
  'preparing' => l10n.usbOutputPreparing,
  'cancelled' => l10n.usbOutputCancelled,
  'dsd_unsupported' => l10n.usbDsdUnsupported,
  'volume_unavailable' => l10n.usbVolumeUnavailable,
  'exclusive_unavailable' => l10n.dapExclusiveUnavailable,
  'permission_denied' => l10n.usbPermissionDenied,
  'permission_declined' => l10n.usbPermissionDeclined,
  'no_usb' => l10n.usbBitPerfectNoDevice,
  'route_changed' => l10n.usbBitPerfectRouteChanged,
  'idle' => l10n.usbBitPerfectPending,
  'format_unsupported' => switch (_sourceFormat(status)) {
    final format? => l10n.usbFormatUnsupported(format),
    null => l10n.usbFormatUnsupportedGeneric,
  },
  'decoder_unavailable' when status.codec != null => l10n.usbDecoderUnavailable(
    status.codec!,
  ),
  'decoder_unavailable' => l10n.usbFormatUnsupportedGeneric,
  'channels_unsupported' when (status.channels ?? 0) > 2 =>
    l10n.usbChannelsUnsupported(status.channels!),
  'dac_format_rejected' => switch (_dacFormat(l10n, status)) {
    final format? => l10n.usbDacFormatRejected(format),
    null => l10n.usbDacFormatRejectedGeneric,
  },
  'dac_unsupported' => l10n.usbDacUnsupported,
  'dac_open_failed' => l10n.usbDacOpenFailed,
  'timeout' => l10n.usbPrepareTimeout,
  'decode_failed' => l10n.usbDecodeFailed,
  'android_version' => l10n.usbAndroidVersion,
  _ => l10n.usbBitPerfectFallback,
};

/// The codec with its bit depth, such as "ALAC 24-bit" or "Vorbis".
String? _sourceFormat(UsbAudioStatus status) {
  final codec = status.codec;
  if (codec == null || codec.isEmpty) return null;
  final bits = status.sourceBitDepth;
  return bits != null && bits > 0 && !status.lossy ? '$codec $bits-bit' : codec;
}

/// The stream the DAC was asked for, such as "32-bit 384 kHz".
String? _dacFormat(AppLocalizations l10n, UsbAudioStatus status) {
  final bits = status.bitDepth ?? status.sourceBitDepth;
  final rate = status.sampleRate;
  final parts = [
    if (bits != null && bits > 0) '$bits-bit',
    if (rate != null && rate > 0) _khz(rate),
  ];
  if (parts.isEmpty) return null;
  final format = parts.join(' ');
  return status.channels == 1 ? l10n.usbFormatMono(format) : format;
}

String _khz(int rate) => rate % 1000 == 0
    ? '${rate ~/ 1000} kHz'
    : '${(rate / 1000).toStringAsFixed(1)} kHz';
