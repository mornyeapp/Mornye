import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/utils/logger.dart';

const _maxRecentItems = 20;
final _log = AppLogger('RecentAccess');

bool isRecentDownloadAfterClear(
  DateTime downloadedAt,
  DateTime? downloadsClearedAt,
) {
  return downloadsClearedAt == null || downloadedAt.isAfter(downloadsClearedAt);
}

enum RecentAccessType { artist, album, track, playlist }

class RecentAccessItem {
  final String id;
  final String name;
  final String? subtitle;
  final String? imageUrl;
  final RecentAccessType type;
  final DateTime accessedAt;
  final String? providerId;

  const RecentAccessItem({
    required this.id,
    required this.name,
    this.subtitle,
    this.imageUrl,
    required this.type,
    required this.accessedAt,
    this.providerId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'subtitle': subtitle,
    'imageUrl': imageUrl,
    'type': type.name,
    'accessedAt': accessedAt.toIso8601String(),
    'providerId': providerId,
  };

  factory RecentAccessItem.fromJson(Map<String, dynamic> json) {
    return RecentAccessItem(
      id: json['id'] as String,
      name: json['name'] as String,
      subtitle: json['subtitle'] as String?,
      imageUrl: json['imageUrl'] as String?,
      type: RecentAccessType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => RecentAccessType.track,
      ),
      accessedAt: DateTime.parse(json['accessedAt'] as String),
      providerId: json['providerId'] as String?,
    );
  }

  String get uniqueKey => '${type.name}:${providerId ?? 'default'}:$id';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecentAccessItem &&
          runtimeType == other.runtimeType &&
          uniqueKey == other.uniqueKey;

  @override
  int get hashCode => uniqueKey.hashCode;
}

class RecentAccessState {
  final List<RecentAccessItem> items;
  final Set<String> hiddenDownloadIds;
  final DateTime? downloadsClearedAt;
  final bool isLoaded;

  const RecentAccessState({
    this.items = const [],
    this.hiddenDownloadIds = const {},
    this.downloadsClearedAt,
    this.isLoaded = false,
  });

  RecentAccessState copyWith({
    List<RecentAccessItem>? items,
    Set<String>? hiddenDownloadIds,
    DateTime? downloadsClearedAt,
    bool? isLoaded,
  }) {
    return RecentAccessState(
      items: items ?? this.items,
      hiddenDownloadIds: hiddenDownloadIds ?? this.hiddenDownloadIds,
      downloadsClearedAt: downloadsClearedAt ?? this.downloadsClearedAt,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

class RecentAccessNotifier extends Notifier<RecentAccessState> {
  RecentAccessNotifier({AppStateDatabase? database})
    : _appStateDb = database ?? AppStateDatabase.instance;

  final AppStateDatabase _appStateDb;
  Future<void> _writeChain = Future<void>.value();
  final _loadingEdits = <RecentAccessState Function(RecentAccessState)>[];
  final _clearingEdits =
      <List<RecentAccessState Function(RecentAccessState)>>[];

  @override
  RecentAccessState build() {
    _writeChain = _loadHistory();
    return const RecentAccessState();
  }

  void _editState(RecentAccessState Function(RecentAccessState) edit) {
    if (!state.isLoaded) _loadingEdits.add(edit);
    for (final edits in _clearingEdits) {
      edits.add(edit);
    }
    state = edit(state);
  }

  Future<void> _enqueueWrite(Future<void> Function() write) {
    final pending = _writeChain.then((_) => write());
    // The owner logs failures and keeps later edits writable. Awaitable
    // operations still receive their original persistence error.
    _writeChain = pending.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _log.e('Failed to save recent access history', error, stack);
      },
    );
    return pending;
  }

  Future<void> _loadHistory() async {
    try {
      await _appStateDb.migrateRecentAccessFromSharedPreferences();
      if (!ref.mounted) return;
      final rows = await _appStateDb.getRecentAccessRows(
        limit: _maxRecentItems,
      );
      if (!ref.mounted) return;
      final hiddenIds = await _appStateDb.getHiddenRecentDownloadIds();
      if (!ref.mounted) return;
      final downloadsClearedAt = await _appStateDb
          .getRecentDownloadsClearedAt();
      if (!ref.mounted) return;

      final items = <RecentAccessItem>[];
      for (final row in rows) {
        final itemJson = row['item_json'] as String?;
        if (itemJson == null || itemJson.isEmpty) continue;
        try {
          final decoded = jsonDecode(itemJson);
          if (decoded is! Map) continue;
          items.add(
            RecentAccessItem.fromJson(Map<String, dynamic>.from(decoded)),
          );
        } catch (_) {
          continue;
        }
      }

      var loaded = RecentAccessState(
        items: items,
        hiddenDownloadIds: hiddenIds,
        downloadsClearedAt: downloadsClearedAt,
        isLoaded: true,
      );
      for (final edit in _loadingEdits) {
        loaded = edit(loaded);
      }
      if (ref.mounted) state = loaded;
    } catch (error, stack) {
      _log.e('Failed to load recent access history', error, stack);
      if (ref.mounted) state = state.copyWith(isLoaded: true);
    } finally {
      _loadingEdits.clear();
    }
  }

  void recordArtistAccess({
    required String id,
    required String name,
    String? imageUrl,
    String? providerId,
  }) {
    _recordAccess(
      RecentAccessItem(
        id: id,
        name: name,
        imageUrl: durableCoverReference(imageUrl),
        type: RecentAccessType.artist,
        accessedAt: DateTime.now(),
        providerId: providerId,
      ),
    );
  }

  void recordAlbumAccess({
    required String id,
    required String name,
    String? artistName,
    String? imageUrl,
    String? providerId,
  }) {
    _recordAccess(
      RecentAccessItem(
        id: id,
        name: name,
        subtitle: artistName,
        imageUrl: durableCoverReference(imageUrl),
        type: RecentAccessType.album,
        accessedAt: DateTime.now(),
        providerId: providerId,
      ),
    );
  }

  void recordPlaylistAccess({
    required String id,
    required String name,
    String? ownerName,
    String? imageUrl,
    String? providerId,
  }) {
    _recordAccess(
      RecentAccessItem(
        id: id,
        name: name,
        subtitle: ownerName,
        imageUrl: imageUrl,
        type: RecentAccessType.playlist,
        accessedAt: DateTime.now(),
        providerId: providerId,
      ),
    );
  }

  void _recordAccess(RecentAccessItem item) {
    final previousTail = state.items.length == _maxRecentItems
        ? state.items.last
        : null;
    _editState(
      (current) => current.copyWith(
        items: [
          item,
          ...current.items.where((e) => e.uniqueKey != item.uniqueKey),
        ].take(_maxRecentItems).toList(),
      ),
    );
    final removedTail =
        previousTail != null && !state.items.contains(previousTail)
        ? previousTail
        : null;
    unawaited(
      _enqueueWrite(() async {
        await _appStateDb.upsertRecentAccessRow(
          uniqueKey: item.uniqueKey,
          itemJson: jsonEncode(item.toJson()),
          accessedAt: item.accessedAt.toIso8601String(),
        );
        if (removedTail != null) {
          await _appStateDb.deleteRecentAccessRow(removedTail.uniqueKey);
        }
      }),
    );
  }

  void removeItem(RecentAccessItem item) {
    _editState(
      (current) => current.copyWith(
        items: current.items
            .where((e) => e.uniqueKey != item.uniqueKey)
            .toList(),
      ),
    );
    unawaited(
      _enqueueWrite(() => _appStateDb.deleteRecentAccessRow(item.uniqueKey)),
    );
  }

  void hideDownloadFromRecents(String downloadId) {
    _editState(
      (current) => current.copyWith(
        hiddenDownloadIds: {...current.hiddenDownloadIds, downloadId},
      ),
    );
    unawaited(
      _enqueueWrite(() => _appStateDb.addHiddenRecentDownloadId(downloadId)),
    );
  }

  Future<void> clearHistory() async {
    final laterEdits = <RecentAccessState Function(RecentAccessState)>[];
    _clearingEdits.add(laterEdits);
    try {
      await _enqueueWrite(() async {
        final clearedAt = await _appStateDb.clearAllRecentAccess();
        if (!ref.mounted) return;
        var cleared = state.copyWith(
          items: [],
          hiddenDownloadIds: {},
          downloadsClearedAt: clearedAt,
        );
        for (final edit in laterEdits) {
          cleared = edit(cleared);
        }
        state = cleared;
      });
    } finally {
      _clearingEdits.remove(laterEdits);
    }
  }

  void clearHiddenDownloads() {
    _editState((current) => current.copyWith(hiddenDownloadIds: {}));
    unawaited(_enqueueWrite(_appStateDb.clearHiddenRecentDownloadIds));
  }
}

final recentAccessProvider =
    NotifierProvider<RecentAccessNotifier, RecentAccessState>(
      RecentAccessNotifier.new,
    );
