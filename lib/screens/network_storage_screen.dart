import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/network_storage_error.dart';
import 'package:mornye/services/network_certificate.dart';
import 'package:mornye/services/sync/sync_orchestration_service.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/settings_group.dart';

class NetworkStorageScreen extends ConsumerStatefulWidget {
  const NetworkStorageScreen({
    super.key,
    this.connection,
    this.path = '',
    this.service,
    this.displayName,
  });
  final NetworkConnection? connection;
  final String path;
  final NetworkStorageService? service;
  final String? displayName;

  @override
  ConsumerState<NetworkStorageScreen> createState() =>
      _NetworkStorageScreenState();
}

class _NetworkStorageScreenState extends ConsumerState<NetworkStorageScreen> {
  NetworkStorageService get service =>
      widget.service ?? NetworkStorageService.instance;
  List<NetworkConnection> _connections = [];
  List<NetworkEntry> _entries = [];
  bool _loading = true;
  bool _failed = false;
  NetworkStorageError _failure = NetworkStorageError.unknown;
  bool _starting = false;
  bool _adding = false;
  bool _added = false;
  bool _selectingDestination = false;
  int _loadGeneration = 0;
  final _search = TextEditingController();
  bool get _subsonic => widget.connection?.protocol == NetworkProtocol.subsonic;

  bool _syncEnabled = false;
  String _syncDeviceName = '';
  String _syncDeviceId = '';
  String? _selectedSyncConnId;
  String _syncStorageType = 'local';
  String _syncLocalPath = '';
  SyncStatus _syncStatus = const SyncStatus();
  bool _syncingNow = false;
  StreamSubscription<SyncStatus>? _syncStatusSub;

  @override
  void dispose() {
    _search.dispose();
    _syncStatusSub?.cancel();
    super.dispose();
  }

  String _entryName(NetworkEntry entry) => switch (entry.path) {
    'subsonic/artists/' when _subsonic => context.l10n.searchArtists,
    'subsonic/albums/' when _subsonic => context.l10n.searchAlbums,
    _ when _subsonic && entry.path.startsWith('subsonic/albums/') =>
      context.l10n.subsonicMoreAlbums,
    _ => entry.song?.title ?? entry.name,
  };

  Future<void> _useForDownloads() async {
    final connection = widget.connection;
    if (connection == null || _selectingDestination) return;
    setState(() => _selectingDestination = true);
    try {
      final source = NetworkStorageService.source(connection.id, widget.path);
      await service.checkUploadAccess(source);
      if (!mounted) return;
      await ref
          .read(settingsProvider.notifier)
          .setNetworkDownloadFolder(
            source,
            '${connection.name}${widget.path.isEmpty ? '' : ' / ${widget.path}'}',
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${context.l10n.networkDownloadAccessFailed} ${_networkErrorMessage(context, classifyNetworkStorageError(error))}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selectingDestination = false);
    }
  }

  Future<void> _addToLibrary() async {
    final connection = widget.connection;
    if (connection == null || _adding) return;
    setState(() => _adding = true);
    try {
      final library = ref.read(localLibraryProvider.notifier);
      if (ref.read(localLibraryProvider).isScanning) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.libraryScanning)));
        return;
      }
      final folder = widget.path
          .split('/')
          .where((s) => s.isNotEmpty)
          .lastOrNull;
      final source = await library.addSource(
        path: NetworkStorageService.source(connection.id, widget.path),
        displayName: folder == null
            ? connection.name
            : '${connection.name} / $folder',
      );
      if (!mounted) return;
      ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
      setState(() => _added = true);
      await library.startSourceScan(source.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _networkErrorMessage(context, classifyNetworkStorageError(error)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _loadSyncSettings() async {
    final syncService = SyncOrchestrationService.instance;
    final config = await syncService.loadConfig();
    final devId = await syncService.getDeviceId();
    if (!mounted) return;
    setState(() {
      _syncEnabled = config.enabled;
      _syncDeviceName = config.deviceName;
      _syncDeviceId = devId;
      _selectedSyncConnId = config.selectedNetworkConnectionId;
      _syncStorageType = config.storageType;
      _syncLocalPath = config.localPath;
      _syncStatus = syncService.currentStatus;
      _syncingNow = syncService.currentStatus.state == SyncStatusState.syncing;
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.connection == null) {
      _syncStatusSub = SyncOrchestrationService.instance.statusStream.listen((
        status,
      ) {
        if (mounted) {
          setState(() {
            _syncStatus = status;
            _syncingNow = status.state == SyncStatusState.syncing;
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant NetworkStorageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection != widget.connection ||
        oldWidget.path != widget.path ||
        oldWidget.service != widget.service) {
      _added = false;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    bool isCurrent() => mounted && generation == _loadGeneration;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final connection = widget.connection;
      if (connection == null) {
        final connections = await service.connections();
        if (isCurrent()) {
          _connections = connections;
          await _loadSyncSettings();
        }
      } else {
        final entries = _subsonic && _search.text.trim().isNotEmpty
            ? await service.searchSubsonic(connection, _search.text)
            : await service.list(connection, widget.path);
        if (isCurrent()) _entries = entries;
      }
    } catch (error) {
      if (isCurrent()) {
        _failed = true;
        _failure = classifyNetworkStorageError(error);
      }
    } finally {
      if (isCurrent()) setState(() => _loading = false);
    }
  }

  Future<void> _edit([NetworkConnection? connection]) async {
    await Navigator.of(context).push(
      _networkRoute(
        context,
        builder: (_) =>
            _NetworkConnectionForm(service: service, connection: connection),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _open(
    NetworkConnection connection, [
    String path = '',
    String? displayName,
  ]) async {
    await Navigator.of(context).push(
      _networkRoute(
        context,
        builder: (_) => NetworkStorageScreen(
          connection: connection,
          path: path,
          service: service,
          displayName: displayName,
        ),
      ),
    );
  }

  Future<void> _play(NetworkEntry selected) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final connection = widget.connection!;
      final tracks = _entries.where((e) => e.audio).toList();
      final cover = _entries
          .where(
            (e) =>
                !e.directory &&
                const {
                  'cover.jpg',
                  'folder.jpg',
                  'front.jpg',
                  'cover.png',
                  'folder.png',
                }.contains(e.name.toLowerCase()),
          )
          .firstOrNull;
      final artwork = cover == null
          ? null
          : Uri.parse(
              await service.resolve(
                NetworkStorageService.source(connection.id, cover.path),
              ),
            );
      if (!mounted) return;
      await ref.read(musicPlayerControllerProvider).playAll([
        for (final entry in tracks)
          PlayableMedia(
            id: NetworkStorageService.source(connection.id, entry.path),
            source: NetworkStorageService.source(connection.id, entry.path),
            title:
                entry.song?.title ??
                entry.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
            artist: entry.song?.artist ?? connection.name,
            album:
                entry.song?.album ??
                widget.path.split('/').where((p) => p.isNotEmpty).lastOrNull ??
                '',
            artUri: artwork?.toString(),
            networkArtworkSource: entry.song?.coverPath != null
                ? NetworkStorageService.source(
                    connection.id,
                    entry.song!.coverPath!,
                  )
                : cover == null
                ? null
                : NetworkStorageService.source(connection.id, cover.path),
            format: entry.extension,
            duration: entry.song?.metadata['duration'] is int
                ? Duration(seconds: entry.song!.metadata['duration'] as int)
                : null,
            bitDepth: entry.song?.metadata['bit_depth'] as int?,
            sampleRate: entry.song?.metadata['sample_rate'] as int?,
            bitrate: entry.song?.metadata['bitrate'] as int?,
            explicit: entry.song?.metadata['explicit'] == true,
          ),
      ], initialIndex: tracks.indexOf(selected));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _networkErrorMessage(context, classifyNetworkStorageError(error)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _syncDeviceName);
    final updated = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: const Text('Edit Device Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Device Display Name',
            hintText: 'e.g. Living Room PC, My Phone',
          ),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated != null && updated.isNotEmpty && updated != _syncDeviceName) {
      await SyncOrchestrationService.instance.setDeviceName(updated);
      if (mounted) {
        setState(() => _syncDeviceName = updated);
      }
    }
  }

  Future<void> _copyDeviceId() async {
    if (_syncDeviceId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _syncDeviceId));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device ID copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _selectSyncConnection() async {
    final isWin = isDesktopPlatform && Platform.isWindows;
    final compatibleConns = _connections
        .where((c) => c.protocol == NetworkProtocol.webdav)
        .toList();

    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: const Text('Select Sync Connection'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWin)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(
                    _syncLocalPath.isNotEmpty
                        ? 'Local Folder ($_syncLocalPath)'
                        : 'Local Folder (Select directory...)',
                  ),
                  subtitle: const Text('Direct file system storage on Windows'),
                  selected: _syncStorageType == 'local',
                  trailing: _syncStorageType == 'local'
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () async {
                    String? targetPath = _syncLocalPath;
                    if (targetPath.isEmpty || _syncStorageType == 'local') {
                      final picked = await FilePicker.getDirectoryPath(
                        dialogTitle: 'Select Sync Folder',
                      );
                      if (picked != null && picked.isNotEmpty) {
                        targetPath = picked;
                      }
                    }
                    if (targetPath.isNotEmpty) {
                      await SyncOrchestrationService.instance
                          .setLocalStorageType(localPath: targetPath);
                      await _loadSyncSettings();
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    }
                  },
                ),
              for (final conn in compatibleConns)
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(conn.name),
                  subtitle: Text('WebDAV · ${conn.address}'),
                  selected:
                      _syncStorageType == 'webdav' &&
                      (_selectedSyncConnId == conn.id ||
                          (_selectedSyncConnId == null &&
                              SyncOrchestrationService.findIntendedWebDavConnection(
                                    _connections,
                                  )?.id ==
                                  conn.id)),
                  trailing:
                      (_syncStorageType == 'webdav' &&
                          (_selectedSyncConnId == conn.id ||
                              (_selectedSyncConnId == null &&
                                  SyncOrchestrationService.findIntendedWebDavConnection(
                                        _connections,
                                      )?.id ==
                                      conn.id)))
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () async {
                    await SyncOrchestrationService.instance
                        .setSelectedNetworkConnection(conn);
                    await _loadSyncSettings();
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.dialogCancel),
          ),
        ],
      ),
    );
  }

  String _syncStatusSubtitle() {
    if (_syncingNow) return 'Syncing in progress...';
    if (_syncStatus.state == SyncStatusState.error &&
        _syncStatus.errorMessage != null) {
      return 'Sync error: ${_syncStatus.errorMessage}';
    }
    if (_syncStatus.lastSyncTime != null) {
      final formattedTime = DateFormat.yMMMd().add_jm().format(
        _syncStatus.lastSyncTime!.toLocal(),
      );
      final deviceText = _syncStatus.activeDeviceCount > 0
          ? ' • ${_syncStatus.activeDeviceCount} active device${_syncStatus.activeDeviceCount == 1 ? '' : 's'} in sync'
          : '';
      return 'Last synced: $formattedTime$deviceText';
    }
    return 'Not synced yet';
  }

  Future<void> _triggerManualSync() async {
    if (_syncingNow) return;
    setState(() => _syncingNow = true);
    try {
      await listeningRecorder.flush();
      final status = await SyncOrchestrationService.instance.synchronize();
      ref.invalidate(listeningSummaryProvider);
      ref.invalidate(listeningRewindProvider);
      ref.invalidate(listeningRewindSpotlightProvider);
      if (!mounted) return;
      if (status.state == SyncStatusState.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sync failed: ${status.errorMessage ?? "Unknown error"}',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        final activeCount = status.activeDeviceCount;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Synchronized • $activeCount active device${activeCount == 1 ? '' : 's'} in sync',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync failed: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _syncingNow = false);
      }
    }
  }

  Widget _buildCrossDeviceSyncSection() {
    final isWin = isDesktopPlatform && Platform.isWindows;
    final compatibleConns = _connections
        .where((c) => c.protocol == NetworkProtocol.webdav)
        .toList();

    String connectionSubtitle;
    if (_syncStorageType == 'local' && isWin) {
      connectionSubtitle = _syncLocalPath.isNotEmpty
          ? 'Local Folder ($_syncLocalPath)'
          : 'Local Folder (no directory selected)';
    } else if (_selectedSyncConnId != null) {
      final conn = _connections
          .where((c) => c.id == _selectedSyncConnId)
          .firstOrNull;
      if (conn != null && conn.protocol == NetworkProtocol.webdav) {
        connectionSubtitle = '${conn.name} (${conn.address})';
      } else if (conn != null) {
        connectionSubtitle = 'Saved connection is not WebDAV (${conn.name})';
      } else {
        connectionSubtitle = 'Saved connection not found (selection required)';
      }
    } else {
      final auto = SyncOrchestrationService.findIntendedWebDavConnection(
        _connections,
      );
      if (auto != null) {
        connectionSubtitle = '${auto.name} (${auto.address})';
      } else if (compatibleConns.length > 1) {
        connectionSubtitle = 'Multiple WebDAV connections (selection required)';
      } else if (isWin && _syncLocalPath.isNotEmpty) {
        connectionSubtitle = 'Local Folder ($_syncLocalPath)';
      } else {
        connectionSubtitle = 'No compatible WebDAV connection found';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Cross-Device Sync'),
        SettingsGroup(
          children: [
            SettingsItem(
              icon: Icons.sync,
              showIconInMornye: true,
              title: 'Cross-Device Synchronization',
              subtitle:
                  'Synchronize listening statistics and Rewind metrics between your devices via network storage.',
              showDivider: _syncEnabled,
              trailing: AppSwitch(
                value: _syncEnabled,
                semanticLabel: 'Cross-Device Synchronization',
                onChanged: (val) async {
                  await SyncOrchestrationService.instance.setSyncEnabled(val);
                  setState(() => _syncEnabled = val);
                  if (val) {
                    await _loadSyncSettings();
                  }
                },
              ),
            ),
            if (_syncEnabled) ...[
              SettingsItem(
                icon: Icons.badge_outlined,
                showIconInMornye: true,
                title: 'Device Display Name',
                subtitle: _syncDeviceName.isNotEmpty
                    ? _syncDeviceName
                    : 'Not set',
                showDivider: true,
                trailing: const Icon(Icons.edit_outlined, size: 20),
                onTap: _editDeviceName,
              ),
              SettingsItem(
                icon: Icons.fingerprint,
                showIconInMornye: true,
                title: 'Device ID',
                subtitle: _syncDeviceId.isNotEmpty
                    ? _syncDeviceId
                    : 'Not assigned',
                showDivider: true,
                trailing: Tooltip(
                  message: 'Copy Device ID',
                  child: IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    onPressed: _syncDeviceId.isNotEmpty ? _copyDeviceId : null,
                  ),
                ),
                onTap: _syncDeviceId.isNotEmpty ? _copyDeviceId : null,
              ),
              SettingsItem(
                icon: Icons.folder_shared_outlined,
                showIconInMornye: true,
                title: 'Sync Connection',
                subtitle: connectionSubtitle,
                showDivider: true,
                trailing:
                    (compatibleConns.length > 1 ||
                        (compatibleConns.isNotEmpty && isWin))
                    ? const Icon(Icons.swap_horiz, size: 20)
                    : null,
                onTap:
                    (compatibleConns.length > 1 ||
                        (compatibleConns.isNotEmpty && isWin))
                    ? _selectSyncConnection
                    : null,
              ),
              SettingsItem(
                icon: Icons.cloud_sync_outlined,
                showIconInMornye: true,
                title: 'Sync Status',
                subtitle: _syncStatusSubtitle(),
                showDivider: false,
                trailing: _syncingNow
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : AppActionButton(
                        onPressed: _triggerManualSync,
                        label: const Text('Sync Now'),
                        icon: const Icon(Icons.sync, size: 18),
                        tonal: true,
                      ),
              ),
            ],
          ],
        ),
        if (_syncEnabled &&
            compatibleConns.isEmpty &&
            (!isWin || _syncStorageType != 'local'))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Note: Cross-Device Sync requires a compatible WebDAV network connection${isWin ? ' or a local storage folder' : ''}. '
              'SMB and Subsonic protocols do not support the sync format. Please add a WebDAV connection above.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final connection = widget.connection;
    final isDownloadDestination =
        connection != null &&
        ref.watch(settingsProvider.select((s) => s.networkDownloadFolder)) ==
            NetworkStorageService.source(connection.id, widget.path);
    final title = connection == null
        ? context.l10n.networkStorage
        : widget.path.isEmpty
        ? connection.name
        : widget.displayName ??
              widget.path.split('/').where((p) => p.isNotEmpty).last;
    final visible = _entries.where((e) => e.directory || e.audio).toList();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: title,
            actions: [
              if (connection == null)
                _NetworkIconAction(
                  tooltip: context.l10n.networkAddConnection,
                  onPressed: () => _edit(),
                  icon: Icons.add,
                  cupertinoIcon: CupertinoIcons.add,
                ),
              _NetworkIconAction(
                tooltip: context.l10n.networkRefresh,
                onPressed: _loading ? null : _load,
                icon: Icons.refresh,
                cupertinoIcon: CupertinoIcons.refresh,
              ),
            ],
          ),
          // Centered at the reading width on tablets, under the title.
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
            sliver: SliverMainAxisGroup(
              slivers: [
                if (_subsonic && widget.path.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(context.tokens.gapLg),
                      child: AppSearchField(
                        controller: _search,
                        hintText: context.l10n.subsonicSearch,
                        clearTooltip: context.l10n.dialogClear,
                        samplesBackdrop: false,
                        onClear: _load,
                        onSubmitted: (_) => _load(),
                      ),
                    ),
                  ),
                if (_loading || _starting)
                  SliverToBoxAdapter(child: _NetworkProgress()),
                if (!_loading &&
                    !_failed &&
                    connection != null &&
                    connection.protocol != NetworkProtocol.http &&
                    (!_subsonic || widget.path.isEmpty))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppActionButton(
                            onPressed: _adding || _added ? null : _addToLibrary,
                            icon: Icon(
                              _added ? Icons.check : Icons.library_add_outlined,
                            ),
                            label: Text(
                              _added
                                  ? (_subsonic
                                        ? context.l10n.subsonicLibraryAdded
                                        : context.l10n.networkLibraryAdded)
                                  : (_subsonic
                                        ? context.l10n.subsonicAddToLibrary
                                        : context.l10n.networkAddToLibrary),
                            ),
                            tonal: true,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _subsonic
                                ? context.l10n.subsonicLibraryDescription
                                : context.l10n.networkLibraryDescription,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (connection.writable) ...[
                            const SizedBox(height: 12),
                            AppActionButton(
                              onPressed:
                                  _selectingDestination || isDownloadDestination
                                  ? null
                                  : _useForDownloads,
                              icon: Icon(
                                isDownloadDestination
                                    ? Icons.check
                                    : Icons.download_outlined,
                              ),
                              label: Text(
                                isDownloadDestination
                                    ? context.l10n.networkDownloadSelected
                                    : context.l10n.networkUseForDownloads,
                              ),
                              tonal: true,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              context.l10n.networkDownloadDescription,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (_selectingDestination)
                              const AppProgressIndicator.linear(),
                          ],
                          if (_adding)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: AppProgressIndicator.linear(),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (_failed)
                  SliverToBoxAdapter(
                    child: _NetworkMessage(
                      icon: context.isMornye
                          ? CupertinoIcons.wifi_exclamationmark
                          : Icons.wifi_off_rounded,
                      message: _networkErrorMessage(context, _failure),
                      action: AppActionButton(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.dialogRetry),
                        tonal: true,
                      ),
                    ),
                  ),
                if (!_loading && !_failed && connection == null) ...[
                  SliverToBoxAdapter(
                    child: _NetworkMessage(
                      icon: context.isMornye
                          ? CupertinoIcons.cloud
                          : Icons.dns_outlined,
                      message: context.l10n.networkStorageDescription,
                      action: AppActionButton(
                        onPressed: () => _edit(),
                        icon: const Icon(Icons.add),
                        label: Text(context.l10n.networkAddConnection),
                      ),
                    ),
                  ),
                  if (_connections.isNotEmpty)
                    SliverToBoxAdapter(
                      child: SettingsSectionHeader(
                        title: context.l10n.networkConnections,
                      ),
                    ),
                  SliverList.builder(
                    itemCount: _connections.length,
                    itemBuilder: (context, index) {
                      final c = _connections[index];
                      return SettingsGroup(
                        children: [
                          SettingsItem(
                            icon: context.isMornye
                                ? CupertinoIcons.cloud
                                : Icons.dns_outlined,
                            showIconInMornye: true,
                            title: c.name,
                            subtitle:
                                '${_protocolLabel(c.protocol)} · ${c.root.host}',
                            onTap: () => _open(c),
                            showDivider: false,
                            trailing: _NetworkIconAction(
                              tooltip: context.l10n.networkEditConnection,
                              onPressed: () => _edit(c),
                              icon: Icons.edit_outlined,
                              cupertinoIcon: CupertinoIcons.pencil,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  SliverToBoxAdapter(child: _buildCrossDeviceSyncSection()),
                ],
                if (!_loading && !_failed && connection != null) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                      child: Text(
                        '${_protocolLabel(connection.protocol)} · ${connection.root.host}'
                        '${_subsonic ? '' : '\n/${widget.path}'}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  if (visible.isEmpty)
                    SliverToBoxAdapter(
                      child: _NetworkMessage(
                        icon: context.isMornye
                            ? CupertinoIcons.folder
                            : Icons.folder_open_rounded,
                        message: context.l10n.networkNoFiles,
                      ),
                    ),
                  SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final entry = visible[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Material(
                          color: settingsGroupColor(context),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(
                              index == 0
                                  ? (context.isMornye
                                        ? 28
                                        : context.tokens.radiusCard)
                                  : 0,
                            ),
                            bottom: Radius.circular(
                              index == visible.length - 1
                                  ? (context.isMornye
                                        ? 28
                                        : context.tokens.radiusCard)
                                  : 0,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: SettingsItem(
                            icon: entry.directory
                                ? Icons.folder_outlined
                                : Icons.music_note,
                            showIconInMornye: true,
                            title: _entryName(entry),
                            subtitle: entry.directory
                                ? null
                                : [
                                    if (entry.song != null) entry.song!.artist,
                                    entry.extension.toUpperCase(),
                                  ].join(' · '),
                            showDivider: index != visible.length - 1,
                            trailing: entry.directory
                                ? null
                                : _NetworkIconAction(
                                    tooltip: context.l10n.tooltipPlay,
                                    icon: Icons.play_arrow_rounded,
                                    cupertinoIcon: CupertinoIcons.play_fill,
                                    onPressed: _starting
                                        ? null
                                        : () => _play(entry),
                                  ),
                            onTap: _starting
                                ? null
                                : () => entry.directory
                                      ? _open(
                                          connection,
                                          entry.path,
                                          _entryName(entry),
                                        )
                                      : _play(entry),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

class _NetworkConnectionForm extends StatefulWidget {
  const _NetworkConnectionForm({required this.service, this.connection});
  final NetworkStorageService service;
  final NetworkConnection? connection;
  @override
  State<_NetworkConnectionForm> createState() => _NetworkConnectionFormState();
}

class _NetworkConnectionFormState extends State<_NetworkConnectionForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.connection?.name);
  late final _address = TextEditingController(text: widget.connection?.address);
  late final _user = TextEditingController(text: widget.connection?.username);
  late final _password = TextEditingController(
    text: widget.connection?.password,
  );
  late final _domain = TextEditingController(text: widget.connection?.domain);
  late final _apiKey = TextEditingController(text: widget.connection?.apiKey);
  late var _auth = widget.connection?.subsonicAuth ?? SubsonicAuth.saltedToken;
  late var _protocol = widget.connection?.protocol ?? NetworkProtocol.smb;
  late String? _trustedCertificate =
      widget.connection?.trustedCertificateSha256;
  late String? _trustedOrigin = widget.connection?.root.scheme == 'https'
      ? widget.connection!.root.origin
      : null;
  NetworkCertificateException? _pendingCertificate;
  bool _busy = false;
  bool _failed = false;
  NetworkStorageError _failure = NetworkStorageError.unknown;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _address,
      _user,
      _password,
      _domain,
      _apiKey,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _failed = false;
      _pendingCertificate = null;
    });
    try {
      final c = NetworkConnection(
        id: widget.connection?.id ?? NetworkStorageService.newId(),
        name: _name.text.trim(),
        address: _address.text.trim(),
        protocol: _protocol,
        username:
            _protocol == NetworkProtocol.subsonic &&
                _auth == SubsonicAuth.apiKey
            ? ''
            : _user.text,
        password:
            _protocol == NetworkProtocol.subsonic &&
                _auth == SubsonicAuth.apiKey
            ? ''
            : _password.text,
        domain: _domain.text.trim(),
        subsonicAuth: _auth,
        apiKey:
            _protocol == NetworkProtocol.subsonic &&
                _auth == SubsonicAuth.apiKey
            ? _apiKey.text.trim()
            : '',
        trustedCertificateSha256:
            Uri.tryParse(_address.text.trim())?.scheme == 'https' &&
                Uri.parse(_address.text.trim()).origin == _trustedOrigin
            ? _trustedCertificate
            : null,
      );
      c.validate();
      await widget.service.list(c);
      await widget.service.save(c);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failure = classifyNetworkStorageError(error);
          _pendingCertificate = error is NetworkCertificateException
              ? error
              : null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await widget.service.remove(widget.connection!.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
          _failure = classifyNetworkStorageError(error);
        });
      }
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool secret = false,
    String? hint,
  }) {
    String? validate(String? value) =>
        required && (value == null || value.trim().isEmpty)
        ? context.l10n.extensionAccountRequiredValue
        : null;
    if (context.isMornye) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            CupertinoTextFormFieldRow(
              key: ValueKey(label),
              controller: controller,
              enabled: !_busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: hint,
              padding: const EdgeInsets.symmetric(vertical: 10),
              style: Theme.of(context).textTheme.bodyLarge,
              validator: validate,
              textInputAction: TextInputAction.next,
            ),
            const Divider(height: 0.5),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Semantics(
            label: label,
            child: TextFormField(
              key: ValueKey(label),
              controller: controller,
              enabled: !_busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: colors.primary,
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: theme.brightness == Brightness.dark
                    ? Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.05),
                        colors.surface,
                      )
                    : colors.surface,
                isDense: true,
                border: border,
                enabledBorder: border,
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: colors.primary, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
              ),
              validator: validate,
              textInputAction: TextInputAction.next,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        AppSliverHeader.page(
          title: widget.connection == null
              ? context.l10n.networkAddConnection
              : context.l10n.networkEditConnection,
        ),
        SliverPadding(
          // Centered at the reading width on tablets, under the title.
          padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsSectionHeader(title: context.l10n.networkProtocol),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AbsorbPointer(
                      absorbing: _busy,
                      child: SettingsChoiceGrid(
                        children: [
                          for (final protocol in NetworkProtocol.values)
                            SettingsChoiceChip(
                              label: protocol == NetworkProtocol.http
                                  ? 'HTTP(S)'
                                  : _protocolLabel(protocol),
                              isSelected: _protocol == protocol,
                              onTap: () => setState(() => _protocol = protocol),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SettingsSectionHeader(title: context.l10n.networkServer),
                  SettingsGroup(
                    children: [
                      _field(
                        _name,
                        context.l10n.networkConnectionName,
                        required: true,
                      ),
                      _field(
                        _address,
                        context.l10n.networkAddress,
                        required: true,
                        hint: _protocol == NetworkProtocol.smb
                            ? 'smb://server/Music/'
                            : _protocol == NetworkProtocol.subsonic
                            ? 'https://server/navidrome/'
                            : 'https://server/music/',
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  SettingsSectionHeader(
                    title: _protocol == NetworkProtocol.subsonic
                        ? context.l10n.subsonicAuthentication
                        : context.l10n.networkCredentials,
                  ),
                  if (_protocol == NetworkProtocol.subsonic)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.tokens.gapLg,
                      ),
                      child: AbsorbPointer(
                        absorbing: _busy,
                        child: SettingsChoiceGrid(
                          children: [
                            for (final auth in SubsonicAuth.values)
                              SettingsChoiceChip(
                                label: switch (auth) {
                                  SubsonicAuth.saltedToken =>
                                    context.l10n.subsonicToken,
                                  SubsonicAuth.password =>
                                    context.l10n.subsonicPasswordAuth,
                                  SubsonicAuth.apiKey =>
                                    context.l10n.subsonicApiKey,
                                },
                                isSelected: auth == _auth,
                                onTap: () => setState(() => _auth = auth),
                              ),
                          ],
                        ),
                      ),
                    ),
                  SettingsGroup(
                    children: [
                      if (_protocol == NetworkProtocol.subsonic &&
                          _auth == SubsonicAuth.apiKey)
                        _field(
                          _apiKey,
                          context.l10n.subsonicApiKey,
                          required: true,
                          secret: true,
                        )
                      else ...[
                        _field(
                          _user,
                          _protocol == NetworkProtocol.subsonic
                              ? context.l10n.subsonicUsername
                              : context.l10n.networkUsername,
                          required: _protocol == NetworkProtocol.subsonic,
                        ),
                        _field(
                          _password,
                          _protocol == NetworkProtocol.subsonic
                              ? context.l10n.subsonicPassword
                              : context.l10n.networkPassword,
                          secret: true,
                          required: _protocol == NetworkProtocol.subsonic,
                        ),
                      ],
                      if (_protocol == NetworkProtocol.smb)
                        _field(_domain, context.l10n.networkDomain),
                      const SizedBox(height: 12),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      context.l10n.networkStorageDescription,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_failed)
                    _NetworkMessage(
                      icon: context.isMornye
                          ? CupertinoIcons.exclamationmark_circle
                          : Icons.error_outline,
                      message: switch (_pendingCertificate) {
                        final certificate? =>
                          '${context.l10n.networkCertificatePrompt}\n\n'
                              '${certificate.origin}\nSHA-256:\n'
                              '${certificate.fingerprint}',
                        null => _networkErrorMessage(context, _failure),
                      },
                    ),
                  if (_pendingCertificate != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      child: AppActionButton(
                        onPressed: _busy
                            ? null
                            : () {
                                final certificate = _pendingCertificate!;
                                _trustedCertificate = certificate.fingerprint;
                                _trustedOrigin = certificate.origin;
                                _save();
                              },
                        icon: const Icon(Icons.verified_user_outlined),
                        label: Text(context.l10n.networkTrustCertificate),
                      ),
                    ),
                  if (_busy) _NetworkProgress(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                    child: AppActionButton(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.check),
                      label: Text(context.l10n.networkConnectSave),
                    ),
                  ),
                  if (widget.connection != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      child: context.isMornye
                          ? CupertinoButton(
                              onPressed: _busy ? null : _remove,
                              child: Text(
                                context.l10n.networkRemoveConnection,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            )
                          : ExpressiveButton(
                              text: true,
                              onPressed: _busy ? null : _remove,
                              icon: const Icon(Icons.link_off),
                              style: TextButton.styleFrom(
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                              ),
                              child: Text(context.l10n.networkRemoveConnection),
                            ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const NavBarSliverSpacer(),
      ],
    ),
  );
}

PageRoute<void> _networkRoute(
  BuildContext context, {
  required WidgetBuilder builder,
}) => context.isMornye
    ? CupertinoPageRoute<void>(builder: builder)
    : MaterialPageRoute<void>(builder: builder);

String _protocolLabel(NetworkProtocol protocol) => switch (protocol) {
  NetworkProtocol.smb => 'SMB',
  NetworkProtocol.webdav => 'WebDAV',
  NetworkProtocol.http => 'HTTP / HTTPS',
  NetworkProtocol.subsonic => 'Subsonic',
};

String _networkErrorMessage(BuildContext context, NetworkStorageError error) =>
    switch (error) {
      NetworkStorageError.unreachable => context.l10n.networkErrorUnreachable,
      NetworkStorageError.timeout => context.l10n.networkErrorTimeout,
      NetworkStorageError.authentication =>
        context.l10n.networkErrorAuthentication,
      NetworkStorageError.permission => context.l10n.networkErrorPermission,
      NetworkStorageError.localNetworkPermission =>
        context.l10n.networkErrorLocalPermission,
      NetworkStorageError.missingShare => context.l10n.networkErrorShare,
      NetworkStorageError.incompatible => context.l10n.networkErrorProtocol,
      NetworkStorageError.invalidAddress => context.l10n.networkErrorAddress,
      NetworkStorageError.certificate => context.l10n.networkErrorCertificate,
      NetworkStorageError.serverApi => context.l10n.subsonicErrorApi,
      NetworkStorageError.unknown => context.l10n.networkConnectionError,
    };

class _NetworkIconAction extends StatelessWidget {
  const _NetworkIconAction({
    required this.tooltip,
    required this.icon,
    required this.cupertinoIcon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final IconData cupertinoIcon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => context.isMornye
      ? Tooltip(
          message: tooltip,
          child: CupertinoButton(
            onPressed: onPressed,
            padding: const EdgeInsets.all(12),
            child: Icon(
              cupertinoIcon,
              size: 24,
              semanticLabel: tooltip,
              color: onPressed == null
                  ? Theme.of(context).disabledColor
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        )
      : ExpressiveIconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
        );
}

class _NetworkProgress extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Center(
      child: context.isMornye
          ? const CupertinoActivityIndicator()
          : const AppLoadingIndicator(),
    ),
  );
}

class _NetworkMessage extends StatelessWidget {
  const _NetworkMessage({
    required this.icon,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.isMornye
                        ? MornyeTheme.controlFill(context)
                        : scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(
                      context.isMornye ? 16 : 24,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Icon(
                      icon,
                      size: 32,
                      color: context.isMornye
                          ? scheme.primary
                          : scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 24), action!],
            ],
          ),
        ),
      ],
    );
  }
}
