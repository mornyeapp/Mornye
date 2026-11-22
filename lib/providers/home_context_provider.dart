import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/connectivity_monitor.dart';
import 'package:mornye/services/link/client/link_client_controller.dart'
    show linkClientSupportedProvider;
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// The Library's own Hi-Res quality filter: 24-bit and up.
const homeHiResQuality = 'hires';

/// Albums the Hi-Res shelf shows at most.
const homeHiResShelfLimit = 12;

/// The Library albums that pass the Library's Hi-Res filter, [limit] of
/// them from [offset] in title order.
QueueLibraryDbQuery homeHiResAlbumQuery({
  required bool includeLocal,
  required int limit,
  int offset = 0,
}) => QueueLibraryDbQuery(
  includeLocal: includeLocal,
  quality: homeHiResQuality,
  sortMode: 'a-z',
  limit: limit,
  offset: offset,
);

/// Counts the albums [homeHiResAlbumQuery] lists.
LibraryCountsRequest homeHiResCountsRequest({required bool includeLocal}) =>
    LibraryCountsRequest(
      searchQuery: '',
      filterSource: null,
      filterQuality: homeHiResQuality,
      filterFormat: null,
      filterMetadata: null,
      localLibraryEnabled: includeLocal,
    );

/// Direct USB reasons that mean the DAC is no longer the output. Others
/// (preparing, a song the DAC refused) leave it as it was.
const _usbOutputLost = {
  'route_changed',
  'no_usb',
  'unsupported',
  'permission_denied',
  'permission_declined',
  'dac_unsupported',
  'dac_open_failed',
  'android_version',
  'exclusive_unavailable',
};

/// Whether the Android direct output (a USB DAC, or a player's own DAC in
/// exclusive mode) is still the output after [status], given [previous].
/// A song change passes through idle and preparing without ending it.
@visibleForTesting
bool homeUsbHiResOutput(
  bool previous,
  UsbAudioStatus status, {
  required bool enabled,
}) {
  if (!enabled) return false;
  if (status.reason == 'active') return true;
  if (_usbOutputLost.contains(status.reason)) return false;
  return previous;
}

/// Whether the desktop exclusive output is still held after [status], given
/// [previous]. Each new song reports pending before it opens the device.
@visibleForTesting
bool homeExclusiveHiResOutput(
  bool previous,
  ExclusiveOutputStatus status, {
  required bool enabled,
}) => switch (status) {
  _ when !enabled => false,
  ExclusiveOutputStatus.active => true,
  ExclusiveOutputStatus.unavailable => false,
  ExclusiveOutputStatus.pending => previous,
};

/// Whether a DAC or an exclusive hi-res output is the player's output: the
/// Android direct USB output, or desktop exclusive mode, since it last
/// opened. Nothing is known before the first song plays through it.
final homeHiResOutputProvider = NotifierProvider<HomeHiResOutput, bool>(
  HomeHiResOutput.new,
);

class HomeHiResOutput extends Notifier<bool> {
  @override
  bool build() {
    final usbEnabled = ref.watch(
      settingsProvider.select((s) => s.usbBitPerfect),
    );
    final exclusiveEnabled =
        isDesktopPlatform &&
        ref.watch(settingsProvider.select((s) => s.exclusiveOutput));
    var usb = false;
    var exclusive = false;
    bool read() {
      usb = homeUsbHiResOutput(usb, usbAudioStatus.value, enabled: usbEnabled);
      exclusive = homeExclusiveHiResOutput(
        exclusive,
        playbackExclusiveStatus.value,
        enabled: exclusiveEnabled,
      );
      return usb || exclusive;
    }

    void changed() => state = read();
    usbAudioStatus.addListener(changed);
    playbackExclusiveStatus.addListener(changed);
    ref.onDispose(() {
      usbAudioStatus.removeListener(changed);
      playbackExclusiveStatus.removeListener(changed);
    });
    return read();
  }
}

/// A Link device attached to this one: the computer or phone this phone is
/// connected to, or the phones connected to this host.
typedef HomeLinkDevice = ({String name, int count, bool phone, bool hosting});

/// The attached Link device from what Link reports, or null. A session this
/// phone opened comes before phones connected to it.
@visibleForTesting
HomeLinkDevice? homeLinkDevice({
  LinkClientApi? client,
  LinkConnectionState? connection,
  bool hostRunning = false,
  List<LinkClientInfo> hostClients = const [],
}) {
  if (client != null && connection == LinkConnectionState.connected) {
    return (
      name: linkDesktopName(client),
      count: 1,
      phone: client.server.isPhone,
      hosting: false,
    );
  }
  if (!hostRunning || hostClients.isEmpty) return null;
  final name = hostClients.first.name.trim();
  return (
    name: name.isEmpty ? 'Mornye' : name,
    count: hostClients.length,
    phone: true,
    hosting: true,
  );
}

final homeLinkDeviceProvider = Provider.autoDispose<HomeLinkDevice?>((ref) {
  final client = ref.watch(linkPhoneClientProvider);
  final connection = client == null
      ? null
      : ref.watch(linkConnectionStateProvider).value;
  // The host only runs where the app root already keeps it.
  final host = isDesktopPlatform || ref.watch(linkClientSupportedProvider)
      ? ref.watch(
          linkDesktopHostProvider.select(
            (state) => (running: state.running, clients: state.clients),
          ),
        )
      : null;
  return homeLinkDevice(
    client: client,
    connection: connection,
    hostRunning: host?.running ?? false,
    hostClients: host?.clients ?? const [],
  );
});

/// Whether [results] say the device has no network at all.
@visibleForTesting
bool homeIsOffline(List<ConnectivityResult> results) =>
    results.isNotEmpty &&
    results.every((result) => result == ConnectivityResult.none);

/// Whether the device has no network. Unknown counts as online, so Home
/// keeps its shelves when connectivity cannot be read.
final homeOfflineProvider = StreamProvider.autoDispose<bool>((ref) async* {
  final monitor = ConnectivityMonitor.instance;
  try {
    yield homeIsOffline(await monitor.check());
  } on Object {
    // No connectivity reading here: never offline.
    yield false;
    return;
  }
  yield* monitor.changes.map(homeIsOffline).handleError((Object _) {});
});
