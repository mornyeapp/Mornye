import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/music_playback_deck.dart';

String usbOutputStatusLabel(
  AppLocalizations l10n,
  UsbAudioStatus status,
) => switch (status.reason) {
  'active' when status.sampleRate != null && status.bitDepth != null =>
    '${status.device ?? 'USB'} · ${status.transport == 'pcm'
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
  'no_usb' => l10n.usbBitPerfectNoDevice,
  'route_changed' => l10n.usbBitPerfectRouteChanged,
  'idle' => l10n.usbBitPerfectPending,
  _ => l10n.usbBitPerfectFallback,
};
