import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/providers/extension_provider.dart';

final _log = AppLogger('StoreProvider');
final RegExp _leadingVersionPrefix = RegExp(r'^v');
const _registryUrlPrefKey = 'store_registry_url';

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
  final bool hasUpdate;

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
    this.hasUpdate = false,
  });

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
      hasUpdate: json['has_update'] as bool? ?? false,
    );
  }

  bool get requiresNewerApp {
    if (minAppVersion == null || minAppVersion!.isEmpty) return false;
    return _compareVersions(minAppVersion!, AppInfo.version) > 0;
  }
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
  final String registryUrl;

  const RepoState({
    this.extensions = const [],
    this.selectedCategory,
    this.searchQuery = '',
    this.isLoading = false,
    this.isDownloading = false,
    this.downloadingId,
    this.error,
    this.isInitialized = false,
    this.registryUrl = '',
  });

  bool get hasRegistryUrl => registryUrl.isNotEmpty;

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
    String? registryUrl,
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
      registryUrl: registryUrl ?? this.registryUrl,
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

  int get updatesAvailableCount {
    return extensions.where((e) => e.hasUpdate).length;
  }
}

class RepoNotifier extends Notifier<RepoState> {
  Future<void>? _initialization;
  String? _cacheDir;

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

  Future<void> initialize(String cacheDir) {
    if (state.isInitialized) return Future<void>.value();
    _cacheDir = cacheDir;
    return _initialization ??= _initialize(cacheDir).whenComplete(() {
      _initialization = null;
    });
  }

  Future<void> _initialize(String cacheDir) async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_registryUrlPrefKey) ?? '';

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      registryUrl: savedUrl,
    );

    try {
      await ref.read(extensionProvider.notifier).ensureInitialized();
      await PlatformBridge.initExtensionRepo(cacheDir);

      if (savedUrl.isNotEmpty) {
        await PlatformBridge.setRepoRegistryUrl(savedUrl);
        await refresh();
      }

      state = state.copyWith(isInitialized: true, isLoading: false);
      _log.i(
        'Extension store initialized (registryUrl: ${savedUrl.isEmpty ? "not set" : savedUrl})',
      );
    } catch (e) {
      _log.e('Failed to initialize store: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> setRegistryUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(error: 'Please enter a valid URL');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    var previousUrl = state.registryUrl;
    var changedUrl = false;
    try {
      if (!state.isInitialized) {
        final cacheDir =
            _cacheDir ?? (await getApplicationCacheDirectory()).path;
        await initialize(cacheDir);
        if (!state.isInitialized) {
          throw StateError(
            state.error ?? 'Extension repository initialization failed',
          );
        }
        previousUrl = state.registryUrl;
        state = state.copyWith(isLoading: true, clearError: true);
      }
      await PlatformBridge.setRepoRegistryUrl(trimmed);
      changedUrl = true;

      final resolvedUrl = await PlatformBridge.getRepoRegistryUrl();

      // Validate the registry actually loads before persisting the URL, so a
      // broken link never survives an app restart (or a backup restore).
      final extensions = await PlatformBridge.getRepoExtensions(
        forceRefresh: true,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_registryUrlPrefKey, resolvedUrl);

      state = state.copyWith(
        registryUrl: resolvedUrl,
        extensions: extensions.map((e) => RepoExtension.fromJson(e)).toList(),
        isLoading: false,
      );

      _log.i('Registry URL set to: $resolvedUrl');
    } catch (e) {
      _log.e('Failed to set registry URL: $e');
      if (changedUrl) {
        try {
          if (previousUrl.isNotEmpty) {
            await PlatformBridge.setRepoRegistryUrl(previousUrl);
          } else {
            await PlatformBridge.clearRepoRegistryUrl();
          }
        } catch (restoreError) {
          _log.w('Failed to restore previous registry URL: $restoreError');
        }
      }
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> removeRegistryUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_registryUrlPrefKey);

      await PlatformBridge.clearRepoRegistryUrl();

      state = state.copyWith(
        registryUrl: '',
        extensions: const [],
        clearCategory: true,
        searchQuery: '',
        clearError: true,
      );

      _log.i('Registry URL removed');
    } catch (e) {
      _log.e('Failed to remove registry URL: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> refresh({bool forceRefresh = false}) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final extensions = await PlatformBridge.getRepoExtensions(
        forceRefresh: forceRefresh,
      );
      state = state.copyWith(
        extensions: extensions.map((e) => RepoExtension.fromJson(e)).toList(),
        isLoading: false,
      );
      _log.d('Loaded ${state.extensions.length} extensions from store');
    } catch (e) {
      _log.e('Failed to refresh store: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
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

  Future<bool> installExtension(
    String extensionId,
    String tempDir,
    String extensionsDir,
  ) {
    return _runSerialized(
      () => _downloadAndApplyExtension(
        extensionId,
        tempDir,
        action: 'install',
        apply: (notifier, path) => notifier.installExtension(path),
      ),
    );
  }

  /// Installs [extensionId] using the app's temp and extension directories.
  Future<bool> installExtensionToDefaultPaths(String extensionId) async {
    final tempDir = await getTemporaryDirectory();
    final storage = await ExtensionStorageService.prepare();
    return installExtension(extensionId, tempDir.path, storage.extensionsDir);
  }

  /// Updates [extensionId] using the app's temp directory.
  Future<bool> updateExtensionToDefaultPaths(String extensionId) async {
    final tempDir = await getTemporaryDirectory();
    return updateExtension(extensionId, tempDir.path);
  }

  Future<bool> updateExtension(String extensionId, String tempDir) {
    return _runSerialized(
      () => _downloadAndApplyExtension(
        extensionId,
        tempDir,
        action: 'update',
        apply: (notifier, path) => notifier.upgradeExtension(path),
      ),
    );
  }

  Future<bool> _downloadAndApplyExtension(
    String extensionId,
    String tempDir, {
    required String action,
    required Future<bool> Function(ExtensionNotifier notifier, String path)
    apply,
  }) async {
    state = state.copyWith(
      isDownloading: true,
      downloadingId: extensionId,
      clearError: true,
    );

    try {
      _log.i('Downloading extension: $extensionId');
      final downloadPath = await PlatformBridge.downloadRepoExtension(
        extensionId,
        tempDir,
      );

      _log.i('Applying $action from: $downloadPath');
      final success = await apply(
        ref.read(extensionProvider.notifier),
        downloadPath,
      );

      if (success) {
        _log.i('Extension $action succeeded: $extensionId');
        await refresh();
      }

      state = state.copyWith(isDownloading: false, clearDownloadingId: true);
      return success;
    } catch (e) {
      _log.e('Failed to $action extension: $e');
      state = state.copyWith(
        isDownloading: false,
        clearDownloadingId: true,
        error: e.toString(),
      );
      return false;
    }
  }
}

final repoProvider = NotifierProvider<RepoNotifier, RepoState>(
  RepoNotifier.new,
);
