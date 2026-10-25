import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/desktop/link_arriving_files.dart';
import 'package:mornye/services/link/desktop/link_catalog_exporter.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_desktop_backend.dart';
import 'package:mornye/services/link/desktop/link_desktop_ops.dart';
import 'package:mornye/services/link/desktop/link_desktop_transfers.dart';
import 'package:mornye/services/link/desktop/link_downloads.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/desktop/link_phone_library.dart';
import 'package:mornye/services/link/desktop/link_phone_sources.dart';
import 'package:mornye/services/link/desktop/link_player.dart';
import 'package:mornye/services/link/desktop/link_transfer_songs.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/services/link/sync/link_sync_handlers.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('MornyeLink');

/// Whether the owner turned the server on (default off).
const linkDesktopEnabledKey = 'link_desktop_enabled';

/// The name phones see; defaults to the computer's host name.
const linkDesktopNameKey = 'link_desktop_name';

/// The computer's host name without a `.local` or domain suffix.
String linkDefaultDeviceName() {
  try {
    final host = Platform.localHostname.trim();
    final dot = host.indexOf('.');
    final name = dot > 0 ? host.substring(0, dot) : host;
    if (name.isNotEmpty) return name;
  } on Object {
    // Some sandboxes hide the host name.
  }
  return 'Mornye';
}

String? _cleanName(String? name) {
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// What the catalog export depends on: finished downloads, scans and
/// whether scanned sources show in the Library. The host re-exports when it
/// changes. Tests override it.
final linkLibraryRevisionProvider =
    Provider<({int downloads, int library, bool includeLocal})>(
      (ref) => (
        downloads: ref.watch(
          downloadHistoryProvider.select((state) => state.loadedIndexVersion),
        ),
        library: ref.watch(
          localLibraryProvider.select((state) => state.loadedIndexVersion),
        ),
        includeLocal: ref.watch(
          settingsProvider.select((settings) => settings.localLibraryEnabled),
        ),
      ),
    );

enum LinkHostPhase { stopped, starting, running, failed }

const Object _keep = Object();

@immutable
class LinkDesktopHostState {
  const LinkDesktopHostState({
    this.loaded = false,
    this.enabled = false,
    this.name = '',
    this.phase = LinkHostPhase.stopped,
    this.server,
    this.error,
    this.clients = const [],
    this.devices = const [],
    this.phoneStates = const {},
    this.catalogSongs,
  });

  /// Whether the saved settings were read.
  final bool loaded;
  final bool enabled;
  final String name;
  final LinkHostPhase phase;

  /// The running server, or null.
  final LinkHostServer? server;

  /// Why the server failed to start.
  final String? error;

  /// Phones with an open WebSocket.
  final List<LinkClientInfo> clients;

  /// Paired phones and Subsonic apps.
  final List<LinkPairedDevice> devices;

  /// The latest `player.state` of each connected phone.
  final Map<String, LinkPlayerState> phoneStates;

  /// Songs in the last catalog the server loaded.
  final int? catalogSongs;

  bool get running => phase == LinkHostPhase.running && server != null;

  LinkDesktopHostState copyWith({
    bool? loaded,
    bool? enabled,
    String? name,
    LinkHostPhase? phase,
    Object? server = _keep,
    Object? error = _keep,
    List<LinkClientInfo>? clients,
    List<LinkPairedDevice>? devices,
    Map<String, LinkPlayerState>? phoneStates,
    Object? catalogSongs = _keep,
  }) => LinkDesktopHostState(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    name: name ?? this.name,
    phase: phase ?? this.phase,
    server: identical(server, _keep) ? this.server : server as LinkHostServer?,
    error: identical(error, _keep) ? this.error : error as String?,
    clients: clients ?? this.clients,
    devices: devices ?? this.devices,
    phoneStates: phoneStates ?? this.phoneStates,
    catalogSongs: identical(catalogSongs, _keep)
        ? this.catalogSongs
        : catalogSongs as int?,
  );
}

/// Runs the Mornye Link server on desktop: keeps its settings, starts and
/// stops it, exports the catalog, answers forwarded requests through
/// [linkHostRouterProvider] and pushes the desktop player to phones.
class LinkDesktopHost extends Notifier<LinkDesktopHostState> {
  static const exportDelay = Duration(seconds: 10);
  static const stateDelay = Duration(milliseconds: 250);
  static const stateInterval = Duration(seconds: 15);
  static const downloadsDelay = Duration(seconds: 1);

  late LinkDesktopBackend _backend;
  final _pairingEvents = StreamController<LinkPairingEvent>.broadcast();
  final _backendSubscriptions = <StreamSubscription<Object?>>[];
  final _appSubscriptions = <ProviderSubscription<Object?>>[];
  StreamSubscription<void>? _playerSubscription;
  LinkPlayerPort? _player;
  LinkDesktopOps? _ops;
  LinkArrivingFiles? _arriving;
  LinkPhoneCatalogs? _phoneCatalogs;
  LinkPhoneSources? _phoneSources;
  LinkDesktopTransfers? _transfers;
  DesktopLinkCatalogIndex? _index;

  /// Phone sources to scan again after the next export, which knows the
  /// songs transfers saved from them.
  final _rescanAfterExport = <String>{};
  LinkPlayerState? _lastSentState;
  Timer? _exportTimer;
  Timer? _stateTimer;
  Timer? _heartbeat;
  Timer? _downloadsTimer;
  Future<void> _transition = Future.value();
  bool _exporting = false;
  bool _exportAgain = false;
  bool _serverStarted = false;
  String _lastReceivedDir = '';

  @override
  LinkDesktopHostState build() {
    _backend = ref.watch(linkDesktopBackendProvider);
    ref.onDispose(_dispose);
    if (isDesktopPlatform) {
      _installPhoneSongs();
      Future.microtask(_restore);
    }
    return const LinkDesktopHostState();
  }

  /// Keeps paired phones' songs and shows them in Library; they play while
  /// the phone is connected or once received.
  void _installPhoneSongs() {
    final catalogs = _phoneCatalogs = LinkPhoneCatalogs(
      root: ref.read(linkPhoneFolderProvider),
      paired: _isPairedPhone,
      onCommit: (deviceId) => unawaited(_onPhoneCommit(deviceId)),
    );
    final phoneSources = _phoneSources = LinkPhoneSources(
      catalogs: catalogs,
      index: () => _index,
      receivedDir: () => ref.mounted ? _receivedDir() : '',
      connectedDevice: _connectedPhone,
      connectedDevices: () => [
        if (ref.mounted)
          for (final client in state.clients) client.deviceId,
      ],
      send: (message, deviceId) => _send(message, deviceId: deviceId),
      arriving: () => ref.mounted ? _arrivingFiles() : null,
    );
    NetworkStorageService.instance.virtualSources = phoneSources;
    _transfers = LinkDesktopTransfers(
      store: () => ref.read(linkTransfersProvider.notifier),
      send: (message, deviceId) => _send(message, deviceId: deviceId),
      fetch: phoneSources.receive,
      index: () => _index,
      downloads: () => ref.read(linkTransferDownloadsProvider),
      connected: (deviceId) =>
          ref.mounted &&
          state.clients.any((client) => client.deviceId == deviceId),
      deviceName: _deviceName,
      isPhone: _isPairedPhone,
      covers: (deviceId) => catalogs.coverPaths(linkPhoneSourceId(deviceId)),
      onSaved: _onTransferSaved,
      onOffer: (transfer) {
        if (ref.mounted) {
          ref.read(linkTransferOfferNoticeProvider.notifier).show(transfer);
        }
      },
    );
  }

  /// The connected phone whose songs are the Library source [sourceId].
  String? _connectedPhone(String sourceId) {
    if (!ref.mounted) return null;
    for (final client in state.clients) {
      if (linkPhoneSourceId(client.deviceId) == sourceId) {
        return client.deviceId;
      }
    }
    return null;
  }

  /// A transfer saved songs of the phone [deviceId]: once the catalog
  /// knows them, its Library source leaves them out.
  void _onTransferSaved(String deviceId) {
    if (!ref.mounted) return;
    _rescanAfterExport.add(linkPhoneSourceId(deviceId));
    _scheduleExport();
  }

  /// The received folder of the running server, or of the last one.
  String _receivedDir() {
    final dir = state.server?.receivedDir ?? '';
    if (dir.isNotEmpty) _lastReceivedDir = dir;
    return _lastReceivedDir;
  }

  LinkArrivingFiles _arrivingFiles() => _arriving ??= LinkArrivingFiles(
    register: ref.read(musicPlayerRuntimeProvider).streamWhileArriving,
  );

  /// `linkPaired` and `linkPairingEnded`, for the pairing dialog.
  Stream<LinkPairingEvent> get pairingEvents => _pairingEvents.stream;

  Future<void> _restore() async {
    String? name;
    var enabled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(linkDesktopEnabledKey) ?? false;
      name = _cleanName(prefs.getString(linkDesktopNameKey));
    } on Object catch (error) {
      _log.w('Could not read the Mornye Link settings: $error');
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      loaded: true,
      enabled: enabled,
      name: name ?? linkDefaultDeviceName(),
    );
    if (enabled) {
      await _queue(_start);
    } else {
      // The paired devices are listed while the server is off as well.
      await refreshDevices();
    }
  }

  Future<void> _persist(Future<void> Function(SharedPreferences) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } on Object catch (error) {
      _log.w('Could not save the Mornye Link settings: $error');
    }
  }

  /// Runs start and stop one after another; a failed step does not block
  /// the next.
  Future<void> _queue(Future<void> Function() action) =>
      _transition = _transition.then((_) => action()).catchError((
        Object error,
        StackTrace stack,
      ) {
        _log.e('Mornye Link step failed', error, stack);
      });

  /// Turns the server on or off and remembers the choice.
  Future<void> setEnabled(bool enabled) async {
    if (state.name.isEmpty) {
      state = state.copyWith(name: linkDefaultDeviceName());
    }
    state = state.copyWith(enabled: enabled, loaded: true);
    await _persist((prefs) => prefs.setBool(linkDesktopEnabledKey, enabled));
    await _queue(enabled ? _start : _stop);
  }

  /// Renames the server; a running server restarts under the new name.
  Future<void> setName(String name) async {
    final cleaned = _cleanName(name) ?? linkDefaultDeviceName();
    if (cleaned == state.name) return;
    state = state.copyWith(name: cleaned);
    await _persist((prefs) => prefs.setString(linkDesktopNameKey, cleaned));
    if (!state.enabled) return;
    await _queue(() async {
      await _stop();
      await _start();
    });
  }

  /// Starts the server again after a failure.
  Future<void> retry() => _queue(_start);

  String _describe(Object error) => error is PlatformException
      ? (error.message?.isNotEmpty == true ? error.message! : error.code)
      : error.toString();

  Future<void> _start() async {
    if (!ref.mounted || !state.enabled || state.running) return;
    state = state.copyWith(phase: LinkHostPhase.starting, error: null);
    _listenBackend();
    _registerFeatures(ref.read(linkHostRouterProvider));
    try {
      var server = await _runningServer();
      if (server != null && server.name != state.name) {
        await _backend.stop();
        server = null;
      }
      server ??= await _backend.start(name: state.name);
      _serverStarted = true;
      if (!ref.mounted) return;
      state = state.copyWith(phase: LinkHostPhase.running, server: server);
    } on Object catch (error, stack) {
      _log.e('Could not start Mornye Link', error, stack);
      _cancelBackend();
      if (ref.mounted) {
        state = state.copyWith(
          phase: LinkHostPhase.failed,
          server: null,
          error: _describe(error),
        );
      }
      return;
    }
    _listenApp();
    unawaited(refreshDevices());
    unawaited(exportCatalog());
  }

  /// A server still running from before (a hot restart keeps the backend),
  /// with its connected phones.
  Future<LinkHostServer?> _runningServer() async {
    try {
      final status = await _backend.status();
      if (status.server != null && ref.mounted) {
        state = state.copyWith(clients: status.clients);
      }
      return status.server;
    } on Object catch (error) {
      _log.d('No running Mornye Link server: $error');
      return null;
    }
  }

  Future<void> _stop() async {
    _cancelApp();
    _cancelBackend();
    _exportAgain = false;
    if (_serverStarted) {
      _serverStarted = false;
      try {
        await _backend.stop();
      } on Object catch (error) {
        _log.w('Could not stop Mornye Link: $error');
      }
    }
    _index = null;
    _lastSentState = null;
    if (!ref.mounted) return;
    ref.read(linkCatalogIndexProvider.notifier).set(null);
    _phoneSources?.keepConnected(const {});
    _transfers?.keepConnected(const {});
    state = state.copyWith(
      phase: LinkHostPhase.stopped,
      server: null,
      error: null,
      clients: const [],
      phoneStates: const {},
      catalogSongs: null,
    );
    // Nothing is connected any more.
    unawaited(refreshDevices());
  }

  LinkDesktopOps _createOps() {
    final player = ref.read(linkDesktopPlayerProvider);
    _player = player;
    return LinkDesktopOps(
      player: player,
      downloads: ref.read(linkDesktopDownloadsProvider),
      downloadItems: () => ref.read(linkDownloadItemsProvider),
      openUrl: ref.read(linkOpenUrlProvider),
      index: () => _index,
      desktopName: () => state.name,
      deviceName: _deviceName,
      receivedDir: () => state.server?.receivedDir ?? '',
      arriving: _arrivingFiles(),
      autoplay: () => ref.read(settingsProvider).autoplay,
      autoMix: () => ref.read(settingsProvider).autoMix,
      setAutoplay: (enabled) =>
          ref.read(settingsProvider.notifier).setAutoplay(enabled),
      setAutoMix: (enabled) =>
          ref.read(settingsProvider.notifier).setAutoMix(enabled),
    );
  }

  /// Registers every feature's forwarded ops on [router]. Each start
  /// registers again, which replaces the earlier handlers.
  ///
  /// Integration point for the other Mornye Link units: add their
  /// registrars here, for example L4's
  /// `registerLinkSyncHandlers(router, ref);` for `collections`, `history`
  /// and the Subsonic playlist, star and scrobble ops.
  void _registerFeatures(LinkHostRouter router) {
    (_ops ??= _createOps()).register(router);
    _phoneCatalogs?.register(router);
    _transfers?.register(router);
    registerLinkSyncHandlers(router, ref);
    ref.read(linkCollectionsChangedHookProvider.notifier).set(() {
      if (!ref.mounted || !state.running || state.clients.isEmpty) return;
      unawaited(_send({'type': LinkMessageTypes.collectionsChanged}));
    });
  }

  String _deviceName(String deviceId) {
    for (final client in state.clients) {
      if (client.deviceId == deviceId && client.name.isNotEmpty) {
        return client.name;
      }
    }
    for (final device in state.devices) {
      if (device.deviceId == deviceId && device.name.isNotEmpty) {
        return device.name;
      }
    }
    return deviceId;
  }

  /// Whether [deviceId] is a paired phone (not a Subsonic app key); the
  /// paired devices are reloaded once for a phone that just paired.
  Future<bool> _isPairedPhone(String deviceId) async {
    bool known() =>
        state.clients.any((client) => client.deviceId == deviceId) ||
        state.devices.any(
          (device) =>
              device.deviceId == deviceId && device.platform != 'subsonic',
        );
    if (!ref.mounted) return false;
    if (known()) return true;
    await refreshDevices();
    return ref.mounted && known();
  }

  /// Shows a phone's committed songs: adds its Library source the first
  /// time, then rescans it.
  Future<void> _onPhoneCommit(String deviceId) async {
    final catalogs = _phoneCatalogs;
    if (catalogs == null || !ref.mounted) return;
    final sourceId = linkPhoneSourceId(deviceId);
    final library = ref.read(linkPhoneLibraryProvider);
    try {
      if (!await catalogs.hasLibrarySource(sourceId)) {
        await library.add(sourceId, _deviceName(deviceId));
        await catalogs.markLibrarySource(sourceId);
      }
      if (!ref.mounted) return;
      await library.rescan(sourceId);
    } on Object catch (error) {
      _log.w('Could not show the phone songs in Library: $error');
    }
  }

  /// Removes the songs and Library source of phones no longer in
  /// [devices].
  Future<void> _prunePhones(List<LinkPairedDevice> devices) async {
    final catalogs = _phoneCatalogs;
    if (catalogs == null) return;
    final paired = {
      for (final device in devices) linkPhoneSourceId(device.deviceId),
    };
    for (final sourceId in await catalogs.sourceIds()) {
      if (paired.contains(sourceId) || !ref.mounted) continue;
      try {
        await ref.read(linkPhoneLibraryProvider).remove(sourceId);
        await catalogs.remove(sourceId);
      } on Object catch (error) {
        _log.w('Could not remove an unpaired phone\'s songs: $error');
      }
    }
  }

  void _listenBackend() {
    if (_backendSubscriptions.isNotEmpty) return;
    _backendSubscriptions.addAll([
      _backend.requests.listen((request) => unawaited(_onRequest(request))),
      _backend.messages.listen(_onMessage),
      _backend.clients.listen(_onClients),
      _backend.pairing.listen(_onPairing),
    ]);
  }

  void _cancelBackend() {
    for (final subscription in _backendSubscriptions) {
      unawaited(subscription.cancel());
    }
    _backendSubscriptions.clear();
  }

  void _listenApp() {
    _appSubscriptions.addAll([
      ref.listen(linkLibraryRevisionProvider, (_, _) => _scheduleExport()),
      ref.listen(linkDownloadItemsProvider, (_, _) => _scheduleDownloads()),
      ref.listen(
        settingsProvider.select((s) => (s.autoplay, s.autoMix)),
        (_, _) => _onPlayerChanged(),
      ),
    ]);
    _playerSubscription = _player?.changes.listen((_) => _onPlayerChanged());
    _onPlayerChanged();
    _updateHeartbeat();
  }

  void _cancelApp() {
    for (final subscription in _appSubscriptions) {
      subscription.close();
    }
    _appSubscriptions.clear();
    unawaited(_playerSubscription?.cancel());
    _playerSubscription = null;
    for (final timer in [_exportTimer, _stateTimer, _heartbeat]) {
      timer?.cancel();
    }
    _downloadsTimer?.cancel();
    _exportTimer = _stateTimer = _heartbeat = _downloadsTimer = null;
  }

  /// Answers one forwarded request with its handler's result or error.
  Future<void> _onRequest(LinkRequestEvent event) async {
    if (!ref.mounted) return;
    final router = ref.read(linkHostRouterProvider);
    Object? result;
    LinkException? error;
    try {
      result = await router.dispatch(
        LinkRequest(
          requestId: event.requestId,
          op: event.op,
          deviceId: event.deviceId,
          args: event.args,
        ),
      );
    } on LinkException catch (failure) {
      error = failure;
    } on Object catch (failure) {
      error = LinkException('unavailable', failure.toString());
    }
    try {
      await _backend.reply(event.requestId, result: result, error: error);
    } on Object catch (failure) {
      _log.w('Could not answer ${event.op}: $failure');
    }
  }

  void _onMessage(LinkMessageEvent event) {
    if (_phoneSources?.onMessage(event.deviceId, event.message) ?? false) {
      return;
    }
    if (_transfers?.onMessage(event.deviceId, event.message) ?? false) {
      return;
    }
    if (event.type != LinkMessageTypes.playerState) return;
    final phoneState = LinkPlayerState.fromJson(event.message['state']);
    if (phoneState == null || event.deviceId.isEmpty) return;
    state = state.copyWith(
      phoneStates: {...state.phoneStates, event.deviceId: phoneState},
    );
  }

  void _onClients(List<LinkClientInfo> clients) {
    final ids = {for (final client in clients) client.deviceId};
    final known = {for (final client in state.clients) client.deviceId};
    state = state.copyWith(
      clients: List.unmodifiable(clients),
      phoneStates: {
        for (final entry in state.phoneStates.entries)
          if (ids.contains(entry.key)) entry.key: entry.value,
      },
    );
    _phoneSources?.keepConnected(ids);
    _transfers?.keepConnected(ids);
    _updateHeartbeat();
    // A phone that just connected gets the desktop's state right away.
    if (!known.containsAll(ids)) {
      _lastSentState = null;
      _onPlayerChanged();
    }
    unawaited(refreshDevices());
  }

  void _onPairing(LinkPairingEvent event) {
    if (event is LinkPairedEvent) unawaited(refreshDevices());
    if (!_pairingEvents.isClosed) _pairingEvents.add(event);
  }

  void _onPlayerChanged() {
    final player = _player;
    final ops = _ops;
    if (player == null || ops == null || !state.running) return;
    final snapshot = player.snapshot();
    ops.observe(snapshot);
    if (state.clients.isEmpty) return;
    final next = ops.state();
    final last = _lastSentState;
    if (last != null && !linkPlayerStateChanged(last, next)) return;
    _stateTimer?.cancel();
    _stateTimer = Timer(stateDelay, () => unawaited(_pushState()));
  }

  void _updateHeartbeat() {
    final wanted = state.running && state.clients.isNotEmpty;
    if (!wanted) {
      _heartbeat?.cancel();
      _heartbeat = null;
    } else {
      _heartbeat ??= Timer.periodic(
        stateInterval,
        (_) => unawaited(_pushState()),
      );
    }
  }

  Future<void> _pushState() async {
    _stateTimer?.cancel();
    _stateTimer = null;
    final ops = _ops;
    if (ops == null || !state.running || state.clients.isEmpty) return;
    final next = ops.state();
    _lastSentState = next;
    await _send({'type': LinkMessageTypes.playerState, 'state': next.toJson()});
  }

  void _scheduleDownloads() {
    if (!state.running || state.clients.isEmpty || _downloadsTimer != null) {
      return;
    }
    // Progress ticks arrive many times a second; one message per window.
    _downloadsTimer = Timer(downloadsDelay, () {
      _downloadsTimer = null;
      if (!ref.mounted || !state.running || state.clients.isEmpty) return;
      unawaited(
        _send({
          'type': LinkMessageTypes.downloadsChanged,
          ...linkDownloadsPayload(ref.read(linkDownloadItemsProvider)),
        }),
      );
    });
  }

  Future<int> _send(Map<String, dynamic> message, {String? deviceId}) async {
    try {
      return await _backend.send(message, deviceId: deviceId);
    } on Object catch (error) {
      _log.w('Could not send ${message['type']}: $error');
      return 0;
    }
  }

  void _scheduleExport() {
    if (!state.running) return;
    _exportTimer?.cancel();
    _exportTimer = Timer(exportDelay, () => unawaited(exportCatalog()));
  }

  /// Writes the catalog and hands it to the server; runs on start and after
  /// Library changes. A request during an export runs once it finishes.
  Future<void> exportCatalog() async {
    if (_exporting) {
      _exportAgain = true;
      return;
    }
    final server = state.server;
    if (!ref.mounted || !state.running || server == null) return;
    _exporting = true;
    // Taken before the export reads the Library, which holds their songs.
    final rescan = {..._rescanAfterExport};
    _rescanAfterExport.clear();
    try {
      final export = await ref
          .read(linkCatalogExporterProvider)
          .export(
            includeLocal: ref.read(linkLibraryRevisionProvider).includeLocal,
            serverId: server.serverId,
          );
      if (!ref.mounted || !state.running) return;
      final songs = await _backend.setCatalog(export.path);
      if (!ref.mounted || !state.running) return;
      _index = export.index;
      ref.read(linkCatalogIndexProvider.notifier).set(export.index);
      state = state.copyWith(catalogSongs: songs);
      // Phone songs scanned before the index, or saved here by a transfer,
      // leave out the desktop's own.
      final library = ref.read(linkPhoneLibraryProvider);
      for (final sourceId in {...?_phoneSources?.takeUnindexed(), ...rescan}) {
        unawaited(
          library.rescan(sourceId).catchError((Object error) {
            _log.w('Could not rescan phone songs: $error');
          }),
        );
      }
      // Song ids in the player state may have changed.
      _lastSentState = null;
      _onPlayerChanged();
    } on Object catch (error, stack) {
      _log.e('Could not export the Mornye Link catalog', error, stack);
      _rescanAfterExport.addAll(rescan);
    } finally {
      _exporting = false;
      if (_exportAgain && ref.mounted) {
        _exportAgain = false;
        unawaited(exportCatalog());
      }
    }
  }

  /// Reloads the paired devices; this works while the server is stopped.
  Future<void> refreshDevices() async {
    try {
      final devices = await _backend.devices();
      if (!ref.mounted) return;
      state = state.copyWith(devices: devices);
      unawaited(_prunePhones(devices));
    } on Object catch (error) {
      _log.w('Could not list paired devices: $error');
    }
  }

  /// Opens a pairing window.
  Future<LinkPairingWindow> beginPairing() => _backend.beginPairing();

  Future<void> endPairing() async {
    try {
      await _backend.endPairing();
    } on Object catch (error) {
      _log.w('Could not end pairing: $error');
    }
  }

  /// Removes a device's key; it has to pair again.
  Future<void> revoke(String deviceId) async {
    await _backend.revoke(deviceId);
    if (!ref.mounted) return;
    state = state.copyWith(
      devices: [
        for (final device in state.devices)
          if (device.deviceId != deviceId) device,
      ],
    );
    unawaited(refreshDevices());
  }

  /// Mints a key for a third-party Subsonic app called [name].
  Future<LinkAppKey> createAppKey(String name) async {
    final key = await _backend.createKey(name.trim());
    unawaited(refreshDevices());
    return key;
  }

  /// Sends a player [command] to the phone [deviceId]; returns whether it
  /// was delivered.
  Future<bool> sendCommand(String deviceId, LinkCommand command) async =>
      await _send({
        'type': LinkMessageTypes.command,
        ...command.toJson(),
      }, deviceId: deviceId) >
      0;

  /// Asks the phone [deviceId] to open [url].
  Future<bool> openOnPhone(String deviceId, String url) async =>
      await _send({
        'type': LinkMessageTypes.open,
        'url': url.trim(),
      }, deviceId: deviceId) >
      0;

  /// Whether the desktop has a current song to continue on a phone.
  bool get hasCurrentTrack => _player?.snapshot().current != null;

  /// Whether the desktop's own player is playing.
  bool get isPlaying => _player?.snapshot().playing ?? false;

  /// Hands the desktop queue around the current song, at its position, to
  /// the phone [deviceId] and pauses the desktop once the phone has it.
  Future<bool> continueOnPhone(String deviceId) async {
    final ops = _ops;
    final player = _player;
    if (ops == null || player == null) return false;
    final current = ops.state();
    if (current.track == null || current.index < 0) return false;
    final position = current.positionAt(DateTime.now().millisecondsSinceEpoch);
    final delivered = await sendCommand(
      deviceId,
      LinkCommand(LinkActions.playQueue, {
        ...linkHandoffArgs(current, playing: true),
        'positionMs': position,
      }),
    );
    if (delivered) await player.pause();
    return delivered;
  }

  /// "Send to (phone)": offers the desktop's own songs of [items] to the
  /// connected phone [deviceId]; returns the transfers started, none when
  /// no song can be sent.
  Future<List<LinkTransfer>> sendToPhone(
    String deviceId,
    List<UnifiedLibraryItem> items,
  ) async {
    final transfers = _transfers;
    final index = _index;
    if (transfers == null ||
        index == null ||
        !state.clients.any((client) => client.deviceId == deviceId)) {
      return const [];
    }
    final songs = await linkOutgoingSongs(items, index);
    if (songs.isEmpty || !ref.mounted) return const [];
    return transfers.send(deviceId, songs);
  }

  /// "Save to this computer": copies the songs of [items] that a connected
  /// phone has into the download folder; returns the transfers started.
  Future<List<LinkTransfer>> saveToComputer(
    List<UnifiedLibraryItem> items,
  ) async {
    final transfers = _transfers;
    final catalogs = _phoneCatalogs;
    if (transfers == null || catalogs == null) return const [];
    final started = <LinkTransfer>[];
    for (final MapEntry(key: sourceId, value: chosen) in linkPhoneSongsOf(
      items,
    ).entries) {
      final deviceId = _connectedPhone(sourceId);
      if (deviceId == null) continue;
      final songs = await linkIncomingSongs(catalogs, sourceId, chosen);
      if (!ref.mounted) break;
      started.addAll(transfers.receive(deviceId, songs));
    }
    return started;
  }

  void _dispose() {
    _cancelApp();
    _cancelBackend();
    _transfers?.close();
    final phoneSources = _phoneSources;
    if (phoneSources != null) {
      phoneSources.close();
      final storage = NetworkStorageService.instance;
      if (identical(storage.virtualSources, phoneSources)) {
        storage.virtualSources = null;
      }
    }
    unawaited(_pairingEvents.close());
    unawaited(_arriving?.close());
    if (_serverStarted) {
      _serverStarted = false;
      unawaited(
        _backend.stop().catchError((Object error) {
          _log.w('Could not stop Mornye Link: $error');
        }),
      );
    }
  }
}

/// The desktop Mornye Link host. It lives for the app's lifetime; the app
/// root reads it on desktop so the server starts when the owner turned it
/// on.
final linkDesktopHostProvider =
    NotifierProvider<LinkDesktopHost, LinkDesktopHostState>(
      LinkDesktopHost.new,
    );

/// Whether the player bar shows the Devices control: the server runs and a
/// phone is connected.
final linkDevicesAvailableProvider = Provider<bool>(
  (ref) => ref.watch(
    linkDesktopHostProvider.select(
      (state) => state.running && state.clients.isNotEmpty,
    ),
  ),
);
