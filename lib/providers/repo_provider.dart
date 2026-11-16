import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/providers/extension_provider.dart';

final _log = AppLogger('StoreProvider');
final RegExp _leadingVersionPrefix = RegExp(r'^v');

/// The first repository only, kept so an older app version still finds one.
const _legacyRegistryUrlPrefKey = 'store_registry_url';

/// The ordered repositories, a JSON array of registry URLs.
const _registryUrlsPrefKey = 'store_registry_urls';

/// Pins: a JSON object from lowercase extension id to the registry URL the
/// extension was installed from (or adopted).
const _extensionSourcesPrefKey = 'store_extension_sources';

int _compareVersions(String v1, String v2) {
  final parts1 = v1.replaceAll(_leadingVersionPrefix, '').split('.');
  final parts2 = v2.replaceAll(_leadingVersionPrefix, '').split('.');

  final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;

  for (var i = 0; i < maxLen; i++) {
    final n1 = i < parts1.length ? (int.tryParse(parts1[i]) ?? 0) : 0;
    final n2 = i < parts2.length ? (int.tryParse(parts2[i]) ?? 0) : 0;

    if (n1 < n2) return -1;
    if (n1 > n2) return 1;
  }
  return 0;
}

class RepoCategory {
  static const String metadata = 'metadata';
  static const String download = 'download';
  static const String utility = 'utility';
  static const String lyrics = 'lyrics';
  static const String integration = 'integration';
}

class RepoExtension {
  final String id;
  final String name;
  final String displayName;
  final String version;
  final String description;
  final String? iconUrl;
  final String category;
  final List<String> tags;
  final String updatedAt;
  final String? minAppVersion;
  final bool isInstalled;
  final String? installedVersion;
  final bool hasUpdate;

  /// The repository this entry comes from. On a merged store entry it is
  /// the primary source: the pinned one when installed, else the first
  /// repository that lists the id.
  final String registryUrl;
  final String registryName;

  /// Every repository's entry for this id, in repository order. Empty on a
  /// single repository's own entry.
  final List<RepoExtension> sources;

  /// The extension is pinned to a repository that no longer lists it, so it
  /// shows no update.
  final bool sourceMissing;

  const RepoExtension({
    required this.id,
    required this.name,
    required this.displayName,
    required this.version,
    required this.description,
    this.iconUrl,
    required this.category,
    this.tags = const [],
    required this.updatedAt,
    this.minAppVersion,
    this.isInstalled = false,
    this.installedVersion,
    this.hasUpdate = false,
    this.registryUrl = '',
    this.registryName = '',
    this.sources = const [],
    this.sourceMissing = false,
  });

  RepoExtension copyWith({
    String? version,
    bool? hasUpdate,
    String? registryUrl,
    String? registryName,
    List<RepoExtension>? sources,
    bool? sourceMissing,
  }) {
    return RepoExtension(
      id: id,
      name: name,
      displayName: displayName,
      version: version ?? this.version,
      description: description,
      iconUrl: iconUrl,
      category: category,
      tags: tags,
      updatedAt: updatedAt,
      minAppVersion: minAppVersion,
      isInstalled: isInstalled,
      installedVersion: installedVersion,
      hasUpdate: hasUpdate ?? this.hasUpdate,
      registryUrl: registryUrl ?? this.registryUrl,
      registryName: registryName ?? this.registryName,
      sources: sources ?? this.sources,
      sourceMissing: sourceMissing ?? this.sourceMissing,
    );
  }

  /// This id's entry in the repository at [url], if that repository lists it.
  RepoExtension? sourceEntry(String url) {
    for (final entry in sources) {
      if (entry.registryUrl == url) return entry;
    }
    return null;
  }

  factory RepoExtension.fromJson(Map<String, dynamic> json) {
    return RepoExtension(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      displayName:
          json['display_name'] as String? ?? json['name'] as String? ?? '',
      version: json['version'] as String? ?? '0.0.0',
      description: json['description'] as String? ?? '',
      iconUrl: json['icon_url'] as String?,
      category: json['category'] as String? ?? 'utility',
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      updatedAt: json['updated_at'] as String? ?? '',
      minAppVersion: json['min_app_version'] as String?,
      isInstalled: json['is_installed'] as bool? ?? false,
      installedVersion: json['installed_version'] as String?,
      hasUpdate: json['has_update'] as bool? ?? false,
      registryUrl: json['registry_url'] as String? ?? '',
      registryName: json['registry_name'] as String? ?? '',
    );
  }

  bool get requiresNewerApp {
    if (minAppVersion == null || minAppVersion!.isEmpty) return false;
    return _compareVersions(minAppVersion!, AppInfo.version) > 0;
  }
}

/// One configured repository as the last catalog reported it.
class RepoSource {
  final String registryUrl;
  final String name;
  final int extensionCount;

  /// Why this repository has no registry (no cache either); empty when it
  /// loaded.
  final String error;

  const RepoSource({
    required this.registryUrl,
    this.name = '',
    this.extensionCount = 0,
    this.error = '',
  });

  factory RepoSource.fromJson(Map<String, dynamic> json) {
    final url = json['registry_url'] as String? ?? '';
    final name = json['name'] as String? ?? '';
    return RepoSource(
      registryUrl: url,
      name: name.isEmpty ? url : name,
      extensionCount: (json['extension_count'] as num?)?.toInt() ?? 0,
      error: json['error'] as String? ?? '',
    );
  }

  bool get hasError => error.isNotEmpty;
}

/// Repositories with the same name (two registry files of one GitHub
/// repository) get their file name added, or else their URL, so rows,
/// sheets and messages can tell them apart.
List<RepoSource> distinctRepoSourceNames(List<RepoSource> sources) {
  bool shared(List<RepoSource> list, String name) =>
      list.where((s) => s.name == name).length > 1;
  RepoSource renamed(RepoSource source, String name) => RepoSource(
    registryUrl: source.registryUrl,
    name: name,
    extensionCount: source.extensionCount,
    error: source.error,
  );

  final withFile = [
    for (final source in sources)
      if (shared(sources, source.name))
        renamed(source, '${source.name} (${_registryFileName(source)})')
      else
        source,
  ];
  return [
    for (final source in withFile)
      if (shared(withFile, source.name))
        renamed(source, source.registryUrl)
      else
        source,
  ];
}

String _registryFileName(RepoSource source) {
  final segments = Uri.tryParse(source.registryUrl)?.pathSegments ?? const [];
  final file = segments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
  return file.isEmpty ? source.registryUrl : file;
}

/// The store list from every repository's entries: one entry per id.
class RepoCatalogMerge {
  final List<RepoExtension> extensions;

  /// The pins after adoption: [pinsChanged] when an installed extension
  /// without a valid pin adopted its first repository.
  final Map<String, String> pins;
  final bool pinsChanged;

  const RepoCatalogMerge({
    required this.extensions,
    required this.pins,
    required this.pinsChanged,
  });
}

/// Merges [entries] (every repository's entries, in repository order) into
/// one entry per id, case-insensitive, under the pinned-source rule:
///
/// - Installed and pinned to a configured repository: that repository's
///   entry. When that repository no longer lists the id, the entry has no
///   update and is [RepoExtension.sourceMissing] (unless that repository
///   failed to load, which says nothing about its list).
/// - Installed without a valid pin: the first repository that lists it,
///   and that pin is added to the returned pins.
/// - Not installed: the first repository that lists it.
RepoCatalogMerge mergeRepoCatalog({
  required List<RepoExtension> entries,
  required List<RepoSource> sources,
  required Map<String, String> pins,
}) {
  final sourceByUrl = {
    for (final source in sources) source.registryUrl: source,
  };
  final groups = <String, List<RepoExtension>>{};
  for (final entry in entries) {
    if (entry.id.isEmpty) continue;
    (groups[entry.id.toLowerCase()] ??= []).add(entry);
  }

  final nextPins = Map<String, String>.of(pins);
  var pinsChanged = false;
  final merged = <RepoExtension>[];
  for (final MapEntry(key: key, value: group) in groups.entries) {
    final first = group.first;
    final installed = group.any((e) => e.isInstalled);
    var primary = first;
    final pin = pins[key];
    if (installed && pin != null && sourceByUrl.containsKey(pin)) {
      final pinned = group.where((e) => e.registryUrl == pin).firstOrNull;
      if (pinned != null) {
        primary = pinned;
      } else {
        final pinnedSource = sourceByUrl[pin]!;
        primary = first.copyWith(
          version: first.installedVersion,
          hasUpdate: false,
          registryUrl: pin,
          registryName: pinnedSource.name,
          sourceMissing: !pinnedSource.hasError,
        );
      }
    } else if (installed && first.registryUrl.isNotEmpty) {
      nextPins[key] = first.registryUrl;
      pinsChanged = true;
    }
    merged.add(primary.copyWith(sources: List.unmodifiable(group)));
  }
  return RepoCatalogMerge(
    extensions: merged,
    pins: nextPins,
    pinsChanged: pinsChanged,
  );
}

enum RepoAddStatus { added, duplicate, failed }

class RepoAddResult {
  final RepoAddStatus status;

  /// The resolved registry URL (empty when it could not be resolved).
  final String registryUrl;

  /// Why it failed, for [RepoAddStatus.failed].
  final String? error;

  const RepoAddResult(this.status, {this.registryUrl = '', this.error});

  bool get added => status == RepoAddStatus.added;
}

class RepoState {
  final List<RepoExtension> extensions;
  final String? selectedCategory;
  final String searchQuery;
  final bool isLoading;
  final bool isDownloading;
  final String? downloadingId;
  final String? error;
  final bool isInitialized;

  /// The configured repositories, in order.
  final List<String> registryUrls;

  /// Each repository as the last catalog reported it, in order.
  final List<RepoSource> sources;

  /// A repository is being validated before it is added.
  final bool isAddingRepository;

  const RepoState({
    this.extensions = const [],
    this.selectedCategory,
    this.searchQuery = '',
    this.isLoading = false,
    this.isDownloading = false,
    this.downloadingId,
    this.error,
    this.isInitialized = false,
    this.registryUrls = const [],
    this.sources = const [],
    this.isAddingRepository = false,
  });

  bool get hasRegistryUrls => registryUrls.isNotEmpty;

  /// Store rows name their repository only when there is more than one.
  bool get hasMultipleRepositories => registryUrls.length > 1;

  /// The last reported state of the repository at [url], if any.
  RepoSource? sourceFor(String url) {
    for (final source in sources) {
      if (source.registryUrl == url) return source;
    }
    return null;
  }

  RepoState copyWith({
    List<RepoExtension>? extensions,
    String? selectedCategory,
    bool clearCategory = false,
    String? searchQuery,
    bool? isLoading,
    bool? isDownloading,
    String? downloadingId,
    bool clearDownloadingId = false,
    String? error,
    bool clearError = false,
    bool? isInitialized,
    List<String>? registryUrls,
    List<RepoSource>? sources,
    bool? isAddingRepository,
  }) {
    return RepoState(
      extensions: extensions ?? this.extensions,
      selectedCategory: clearCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      searchQuery: searchQuery ?? this.searchQuery,
      isLoading: isLoading ?? this.isLoading,
      isDownloading: isDownloading ?? this.isDownloading,
      downloadingId: clearDownloadingId
          ? null
          : (downloadingId ?? this.downloadingId),
      error: clearError ? null : (error ?? this.error),
      isInitialized: isInitialized ?? this.isInitialized,
      registryUrls: registryUrls ?? this.registryUrls,
      sources: sources ?? this.sources,
      isAddingRepository: isAddingRepository ?? this.isAddingRepository,
    );
  }

  List<RepoExtension> get filteredExtensions {
    var result = extensions;

    if (selectedCategory != null) {
      result = result.where((e) => e.category == selectedCategory).toList();
    }

    if (searchQuery.isNotEmpty) {
      final query = searchQuery.toLowerCase();
      result = result
          .where(
            (e) =>
                e.name.toLowerCase().contains(query) ||
                e.displayName.toLowerCase().contains(query) ||
                e.description.toLowerCase().contains(query) ||
                e.tags.any((t) => t.toLowerCase().contains(query)),
          )
          .toList();
    }

    return result;
  }

  /// Updates of the merged entries, so only from each pinned repository.
  int get updatesAvailableCount {
    return extensions.where((e) => e.hasUpdate).length;
  }
}

List<String> _decodeUrlList(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return normalizeRegistryUrls(decoded.whereType<String>());
    }
  } catch (_) {}
  return const [];
}

/// Trimmed, non-empty and without exact duplicates, keeping the first, as
/// the native side keeps the list.
List<String> normalizeRegistryUrls(Iterable<String> urls) {
  final seen = <String>{};
  return [
    for (final url in urls.map((u) => u.trim()))
      if (url.isNotEmpty && seen.add(url)) url,
  ];
}

class RepoNotifier extends Notifier<RepoState> {
  Future<void>? _initialization;
  String? _cacheDir;

  /// Every repository's entries from the last catalog, before merging.
  List<RepoExtension> _entries = const [];

  /// Lowercase extension id to its pinned registry URL.
  Map<String, String>? _pins;

  /// Serializes install/upgrade so two never race the native VM teardown/reload.
  Future<void> _mutationChain = Future<void>.value();

  Future<T> _runSerialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationChain = _mutationChain.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  @override
  RepoState build() {
    return const RepoState();
  }

  /// Whether any store repository is saved, read without any network work.
  static Future<bool> hasSavedRegistryUrls() async =>
      (await savedRegistryUrls()).isNotEmpty;

  /// The saved repositories, in order. A device that only has the legacy
  /// single URL gets it as a one-entry list, written at once.
  static Future<List<String>> savedRegistryUrls() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_registryUrlsPrefKey);
    if (raw != null) return _decodeUrlList(raw);
    final legacy = (prefs.getString(_legacyRegistryUrlPrefKey) ?? '').trim();
    if (legacy.isEmpty) return const [];
    final urls = [legacy];
    await _writeRegistryUrls(prefs, urls);
    return urls;
  }

  static Future<void> _writeRegistryUrls(
    SharedPreferences prefs,
    List<String> urls,
  ) async {
    await prefs.setString(_registryUrlsPrefKey, jsonEncode(urls));
    if (urls.isEmpty) {
      await prefs.remove(_legacyRegistryUrlPrefKey);
    } else {
      await prefs.setString(_legacyRegistryUrlPrefKey, urls.first);
    }
  }

  /// The saved pins: lowercase extension id to registry URL.
  static Future<Map<String, String>> savedExtensionSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_extensionSourcesPrefKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final MapEntry(:key, :value) in decoded.entries)
            if (key is String && value is String && value.isNotEmpty)
              key.toLowerCase(): value,
        };
      }
    } catch (_) {}
    return {};
  }

  Future<Map<String, String>> _loadPins() async =>
      _pins ??= await savedExtensionSources();

  Future<void> _savePins(Map<String, String> pins) async {
    _pins = pins;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_extensionSourcesPrefKey, jsonEncode(pins));
  }

  /// Records pins (extension id to registry URL), as a restore does.
  Future<void> saveExtensionSources(Map<String, String> pins) async {
    if (pins.isEmpty) return;
    final next = Map<String, String>.of(await _loadPins());
    pins.forEach((id, url) => next[id.toLowerCase()] = url);
    await _savePins(next);
    _remerge();
  }

  /// Initializes the store with the app's cache directory.
  Future<void> initializeToDefaultPaths() async {
    if (state.isInitialized) return;
    final cacheDir = _cacheDir ?? (await getApplicationCacheDirectory()).path;
    await initialize(cacheDir);
  }

  Future<void> initialize(String cacheDir) {
    if (state.isInitialized) return Future<void>.value();
    _cacheDir = cacheDir;
    return _initialization ??= _initialize(cacheDir).whenComplete(() {
      _initialization = null;
    });
  }

  Future<void> _initialize(String cacheDir) async {
    final savedUrls = await savedRegistryUrls();
    await _loadPins();

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      registryUrls: savedUrls,
    );

    try {
      await ref.read(extensionProvider.notifier).ensureInitialized();
      await PlatformBridge.initExtensionRepo(cacheDir);

      if (savedUrls.isNotEmpty) {
        await PlatformBridge.setRepoRegistryUrls(savedUrls);
        await refresh();
      }

      state = state.copyWith(isInitialized: true, isLoading: false);
      _log.i('Extension store initialized (${savedUrls.length} repositories)');
    } catch (e) {
      _log.e('Failed to initialize store: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> _ensureInitializedForChange() async {
    if (state.isInitialized) return;
    final cacheDir = _cacheDir ?? (await getApplicationCacheDirectory()).path;
    await initialize(cacheDir);
    if (!state.isInitialized) {
      throw StateError(
        state.error ?? 'Extension repository initialization failed',
      );
    }
  }

  Future<void> _persistRegistryUrls(List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeRegistryUrls(prefs, urls);
  }

  /// Adds a repository after the others. The link is resolved first (a
  /// repository page becomes its registry), a repository already in the
  /// list is rejected, and the new one must load before it is kept: when
  /// it reports an error the list goes back to what it was.
  Future<RepoAddResult> addRegistryUrl(String url) =>
      _runSerialized(() => _addRegistryUrl(url));

  Future<RepoAddResult> _addRegistryUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const RepoAddResult(
        RepoAddStatus.failed,
        error: 'Please enter a valid URL',
      );
    }

    state = state.copyWith(isAddingRepository: true);
    List<String>? previous;
    var resolved = '';
    try {
      await _ensureInitializedForChange();
      resolved = (await PlatformBridge.resolveRepoRegistryUrl(trimmed)).trim();
      if (resolved.isEmpty) resolved = trimmed;
      if (state.registryUrls.contains(resolved)) {
        return RepoAddResult(RepoAddStatus.duplicate, registryUrl: resolved);
      }

      final before = state.registryUrls;
      final next = [...before, resolved];
      await PlatformBridge.setRepoRegistryUrls(next);
      previous = before;

      // The new repository must load before the list is saved, so a broken
      // link never survives an app restart (or a backup restore).
      final catalog = await PlatformBridge.getRepoCatalog(forceRefresh: true);
      final sources = _parseSources(catalog);
      final added = sources.where((s) => s.registryUrl == resolved).firstOrNull;
      final addError = added == null
          ? 'Repository did not load'
          : added.hasError
          ? added.error
          : null;
      if (addError != null) {
        await _restoreRegistryUrls(before);
        previous = null;
        return RepoAddResult(
          RepoAddStatus.failed,
          registryUrl: resolved,
          error: addError,
        );
      }

      previous = null;
      await _persistRegistryUrls(next);
      state = state.copyWith(registryUrls: next);
      await _applyCatalog(catalog);
      _log.i('Repository added: $resolved');
      return RepoAddResult(RepoAddStatus.added, registryUrl: resolved);
    } catch (e) {
      _log.e('Failed to add repository: $e');
      if (previous != null) await _restoreRegistryUrls(previous);
      return RepoAddResult(
        RepoAddStatus.failed,
        registryUrl: resolved,
        error: e.toString(),
      );
    } finally {
      state = state.copyWith(isAddingRepository: false);
    }
  }

  Future<void> _restoreRegistryUrls(List<String> urls) async {
    try {
      await PlatformBridge.setRepoRegistryUrls(urls);
    } catch (restoreError) {
      _log.w('Failed to restore the repository list: $restoreError');
    }
  }

  /// Appends repositories (from a backup) that are not in the list yet,
  /// without validating them. A link the native side rejects is skipped.
  Future<void> appendRegistryUrls(Iterable<String> urls) =>
      _runSerialized(() async {
        await _ensureInitializedForChange();
        var next = state.registryUrls;
        final missing = normalizeRegistryUrls(
          urls,
        ).where((url) => !next.contains(url)).toList();
        if (missing.isEmpty) return;
        try {
          await PlatformBridge.setRepoRegistryUrls([...next, ...missing]);
          next = [...next, ...missing];
        } catch (e) {
          _log.w('Restore: a repository was rejected, adding one by one: $e');
          for (final url in missing) {
            try {
              await PlatformBridge.setRepoRegistryUrls([...next, url]);
              next = [...next, url];
            } catch (e) {
              _log.w('Restore: skipped repository $url: $e');
            }
          }
          await _restoreRegistryUrls(next);
        }
        await _persistRegistryUrls(next);
        state = state.copyWith(registryUrls: next);
      });

  /// Removes a repository and the pins that point to it; those extensions
  /// then adopt the first remaining repository that lists them.
  Future<void> removeRegistryUrl(String url) =>
      _runSerialized(() => _removeRegistryUrl(url));

  Future<void> _removeRegistryUrl(String url) async {
    try {
      final next = [
        for (final existing in state.registryUrls)
          if (existing != url) existing,
      ];
      await PlatformBridge.setRepoRegistryUrls(next);
      await _persistRegistryUrls(next);

      final pins = await _loadPins();
      if (pins.containsValue(url)) {
        await _savePins({
          for (final MapEntry(:key, :value) in pins.entries)
            if (value != url) key: value,
        });
      }

      state = state.copyWith(registryUrls: next, clearError: true);
      _log.i('Repository removed: $url');
      if (next.isEmpty) {
        _entries = const [];
        state = state.copyWith(
          extensions: const [],
          sources: const [],
          clearCategory: true,
          searchQuery: '',
        );
      } else {
        await refresh();
      }
    } catch (e) {
      _log.e('Failed to remove repository: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  /// Moves [extensionId]'s pin to [registryUrl]. Nothing is reinstalled;
  /// its update badge follows that repository's version from now on.
  Future<void> changeExtensionSource(
    String extensionId,
    String registryUrl,
  ) async {
    final next = Map<String, String>.of(await _loadPins());
    next[extensionId.toLowerCase()] = registryUrl;
    await _savePins(next);
    _remerge();
    _log.i('Extension $extensionId now follows $registryUrl');
  }

  Future<void> refresh({bool forceRefresh = false}) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final catalog = await PlatformBridge.getRepoCatalog(
        forceRefresh: forceRefresh,
      );
      await _applyCatalog(catalog);
      _log.d('Loaded ${state.extensions.length} extensions from store');
    } catch (e) {
      _log.e('Failed to refresh store: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  static List<RepoSource> _parseSources(Map<String, dynamic> catalog) =>
      distinctRepoSourceNames([
        for (final raw in (catalog['sources'] as List<dynamic>? ?? const []))
          if (raw is Map) RepoSource.fromJson(raw.cast<String, dynamic>()),
      ]);

  Future<void> _applyCatalog(Map<String, dynamic> catalog) async {
    final sources = _parseSources(catalog);
    final names = {
      for (final source in sources) source.registryUrl: source.name,
    };
    _entries = [
      for (final raw in (catalog['extensions'] as List<dynamic>? ?? const []))
        if (raw is Map)
          _withSourceName(
            RepoExtension.fromJson(raw.cast<String, dynamic>()),
            names,
          ),
    ];
    final merge = mergeRepoCatalog(
      entries: _entries,
      sources: sources,
      pins: await _loadPins(),
    );
    if (merge.pinsChanged) await _savePins(merge.pins);

    // A repository's own error shows on its row; the store as a whole only
    // fails when every repository did.
    final failed = sources.isNotEmpty && sources.every((s) => s.hasError);
    state = state.copyWith(
      sources: sources,
      extensions: merge.extensions,
      isLoading: false,
      error: failed ? _combinedError(sources) : null,
      clearError: !failed,
    );
  }

  static RepoExtension _withSourceName(
    RepoExtension entry,
    Map<String, String> names,
  ) {
    final name = names[entry.registryUrl];
    return name == null || name == entry.registryName
        ? entry
        : entry.copyWith(registryName: name);
  }

  static String _combinedError(List<RepoSource> sources) => sources.length == 1
      ? sources.single.error
      : sources.map((s) => '${s.name}: ${s.error}').join('\n');

  /// Merges the last catalog again after the pins changed.
  void _remerge() {
    final pins = _pins;
    if (pins == null || _entries.isEmpty) return;
    final merge = mergeRepoCatalog(
      entries: _entries,
      sources: state.sources,
      pins: pins,
    );
    state = state.copyWith(extensions: merge.extensions);
  }

  /// The repository an install or update of [extensionId] uses: its
  /// merged entry's primary source, or empty to let the native side pick
  /// the first repository that lists it.
  String _primaryRegistryUrl(String extensionId) {
    final key = extensionId.toLowerCase();
    for (final ext in state.extensions) {
      if (ext.id.toLowerCase() == key) return ext.registryUrl;
    }
    return '';
  }

  void setCategory(String? category) {
    if (category == null) {
      state = state.copyWith(clearCategory: true);
    } else {
      state = state.copyWith(selectedCategory: category);
    }
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void clearSearch() {
    state = state.copyWith(searchQuery: '', clearCategory: true);
  }

  /// Installs [extensionId] from [registryUrl], by default its primary
  /// repository, and pins it there on success.
  Future<bool> installExtension(
    String extensionId,
    String tempDir,
    String extensionsDir, {
    String? registryUrl,
  }) {
    return _runSerialized(
      () => _downloadAndApplyExtension(
        extensionId,
        tempDir,
        registryUrl: registryUrl ?? _primaryRegistryUrl(extensionId),
        action: 'install',
        apply: (notifier, path) => notifier.installExtension(path),
      ),
    );
  }

  /// Installs [extensionId] using the app's temp and extension directories.
  Future<bool> installExtensionToDefaultPaths(
    String extensionId, {
    String? registryUrl,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final storage = await ExtensionStorageService.prepare();
    return installExtension(
      extensionId,
      tempDir.path,
      storage.extensionsDir,
      registryUrl: registryUrl,
    );
  }

  /// Updates [extensionId] using the app's temp directory. A [quiet] update
  /// (a background one) logs a failure without showing it on any screen.
  Future<bool> updateExtensionToDefaultPaths(
    String extensionId, {
    bool quiet = false,
  }) async {
    final tempDir = await getTemporaryDirectory();
    return updateExtension(extensionId, tempDir.path, quiet: quiet);
  }

  /// Updates [extensionId] from its pinned repository.
  Future<bool> updateExtension(
    String extensionId,
    String tempDir, {
    bool quiet = false,
  }) {
    return _runSerialized(
      () => _downloadAndApplyExtension(
        extensionId,
        tempDir,
        registryUrl: _primaryRegistryUrl(extensionId),
        action: 'update',
        quiet: quiet,
        apply: (notifier, path) =>
            notifier.upgradeExtension(path, quiet: quiet),
      ),
    );
  }

  Future<bool> _downloadAndApplyExtension(
    String extensionId,
    String tempDir, {
    required String registryUrl,
    required String action,
    required Future<bool> Function(ExtensionNotifier notifier, String path)
    apply,
    bool quiet = false,
  }) async {
    state = state.copyWith(
      isDownloading: true,
      downloadingId: extensionId,
      clearError: !quiet,
    );

    try {
      _log.i('Downloading extension: $extensionId');
      final downloadPath = await PlatformBridge.downloadRepoExtension(
        extensionId,
        tempDir,
        registryUrl: registryUrl,
      );

      _log.i('Applying $action from: $downloadPath');
      final success = await apply(
        ref.read(extensionProvider.notifier),
        downloadPath,
      );

      if (success) {
        _log.i('Extension $action succeeded: $extensionId');
        if (registryUrl.isNotEmpty) {
          final pins = Map<String, String>.of(await _loadPins());
          pins[extensionId.toLowerCase()] = registryUrl;
          await _savePins(pins);
        }
        await refresh();
      }

      state = state.copyWith(isDownloading: false, clearDownloadingId: true);
      return success;
    } catch (e) {
      _log.e('Failed to $action extension: $e');
      state = state.copyWith(
        isDownloading: false,
        clearDownloadingId: true,
        error: quiet ? null : e.toString(),
      );
      return false;
    }
  }
}

final repoProvider = NotifierProvider<RepoNotifier, RepoState>(
  RepoNotifier.new,
);
