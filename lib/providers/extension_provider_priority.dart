// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'extension_provider.dart';

bool _stringListEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String>? _tryDecodeStringListPreference(String rawJson, String key) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException('expected a JSON list');
    }

    final values = <String>[];
    for (final item in decoded) {
      if (item is! String) {
        throw const FormatException('expected string entries');
      }
      final trimmed = item.trim();
      if (trimmed.isNotEmpty) {
        values.add(trimmed);
      }
    }
    return values;
  } catch (e) {
    _log.w('Ignoring invalid $key preference: $e');
    return null;
  }
}

/// Download/metadata/search provider priority: persistence, sanitizing, and
/// reconciliation when extensions are installed, removed, or toggled.
extension ExtensionNotifierProviderPriority on ExtensionNotifier {
  Future<void> _reconcileDownloadProviderPriority() async {
    if (state.providerPriority.isEmpty) {
      return;
    }

    final sanitized = _sanitizeDownloadProviderPriority(state.providerPriority);
    if (_stringListEquals(sanitized, state.providerPriority)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerPriorityKey, jsonEncode(sanitized));
    await PlatformBridge.setProviderPriority(sanitized);
    state = state.copyWith(providerPriority: sanitized);
    _log.d('Reconciled provider priority after extension update: $sanitized');
  }

  Future<void> _reconcileMetadataProviderPriority() async {
    if (state.metadataProviderPriority.isEmpty) {
      return;
    }

    final replaced = _replaceRetiredBuiltInMetadataProviders(
      state.metadataProviderPriority,
    );
    final sanitized = _sanitizeMetadataProviderPriority(replaced);
    if (_stringListEquals(sanitized, state.metadataProviderPriority)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_metadataProviderPriorityKey, jsonEncode(sanitized));
    await PlatformBridge.setMetadataProviderPriority(sanitized);
    state = state.copyWith(metadataProviderPriority: sanitized);
    _log.d(
      'Reconciled metadata provider priority after extension update: $sanitized',
    );
  }

  String? _firstEnabledExtensionDownloadProviderId() {
    return state.extensions
        .where((ext) => ext.enabled && ext.hasDownloadProvider)
        .map((ext) => ext.id)
        .firstOrNull;
  }

  String? _firstEnabledSearchProviderId() {
    return defaultSearchExtension(state.extensions)?.id;
  }

  String? _replacedBuiltInProviderFor(
    String providerId,
    bool Function(Extension ext) hasCapability,
  ) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    return state.extensions
        .where(
          (ext) =>
              ext.enabled &&
              hasCapability(ext) &&
              ext.replacesBuiltInProviders.contains(normalized),
        )
        .map((ext) => ext.id)
        .firstOrNull;
  }

  String? replacedBuiltInDownloadProviderFor(String providerId) =>
      _replacedBuiltInProviderFor(providerId, (ext) => ext.hasDownloadProvider);

  String? replacedBuiltInSearchProviderFor(String providerId) =>
      _replacedBuiltInProviderFor(providerId, (ext) => ext.hasCustomSearch);

  String? replacedBuiltInMetadataProviderFor(String providerId) =>
      _replacedBuiltInProviderFor(providerId, (ext) => ext.hasMetadataProvider);

  bool downloadProviderReplacesLegacyProvider(
    String providerId,
    String legacyProviderId,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedLegacy = legacyProviderId.trim().toLowerCase();
    if (normalizedProvider.isEmpty || normalizedLegacy.isEmpty) return false;
    if (normalizedProvider == normalizedLegacy) return true;

    final extension = state.extensions
        .where((ext) => ext.enabled && ext.hasDownloadProvider)
        .where((ext) => ext.id.toLowerCase() == normalizedProvider)
        .firstOrNull;
    return extension?.replacesBuiltInProviders.contains(normalizedLegacy) ??
        false;
  }

  Future<void> _reconcileDefaultDownloadService() async {
    final settings = ref.read(settingsProvider);
    final preferredExtensionId = _firstEnabledExtensionDownloadProviderId();
    final currentService = settings.defaultService.trim();

    if (currentService.isEmpty) {
      if (preferredExtensionId != null) {
        ref
            .read(settingsProvider.notifier)
            .setDefaultService(preferredExtensionId);
        _log.d(
          'Adopted first enabled download extension as default service: $preferredExtensionId',
        );
      }
      return;
    }

    final replacementExtensionId = replacedBuiltInDownloadProviderFor(
      currentService,
    );
    if (replacementExtensionId != null) {
      ref
          .read(settingsProvider.notifier)
          .setDefaultService(replacementExtensionId);
      _log.d(
        'Migrated retired built-in service $currentService to $replacementExtensionId',
      );
      return;
    }

    final currentExtension = state.extensions
        .where((ext) => ext.id == currentService)
        .firstOrNull;
    final isMissingOrInvalidExtension =
        currentExtension == null ||
        !currentExtension.enabled ||
        !currentExtension.hasDownloadProvider;
    if (isMissingOrInvalidExtension) {
      final fallbackService = preferredExtensionId ?? '';
      ref.read(settingsProvider.notifier).setDefaultService(fallbackService);
      _log.d(
        fallbackService.isEmpty
            ? 'Cleared default service because $currentService is no longer available'
            : 'Reset default service to $fallbackService because $currentService is no longer available',
      );
    }
  }

  void _reconcileSearchProvider() {
    final settings = ref.read(settingsProvider);
    final currentSearchProvider = settings.searchProvider?.trim() ?? '';
    final preferredSearchProvider = _firstEnabledSearchProviderId() ?? '';

    if (currentSearchProvider.isEmpty) {
      if (preferredSearchProvider.isNotEmpty) {
        ref
            .read(settingsProvider.notifier)
            .setSearchProvider(preferredSearchProvider);
        _log.d(
          'Adopted first enabled search provider as default: $preferredSearchProvider',
        );
      }
      return;
    }

    final replacementExtensionId = replacedBuiltInSearchProviderFor(
      currentSearchProvider,
    );
    if (replacementExtensionId != null) {
      ref
          .read(settingsProvider.notifier)
          .setSearchProvider(replacementExtensionId);
      _log.d(
        'Migrated retired built-in search provider $currentSearchProvider to $replacementExtensionId',
      );
      return;
    }

    final hasMatchingExtension = state.extensions.any(
      (ext) =>
          ext.enabled && ext.hasCustomSearch && ext.id == currentSearchProvider,
    );
    if (!hasMatchingExtension) {
      ref
          .read(settingsProvider.notifier)
          .setSearchProvider(
            preferredSearchProvider.isNotEmpty ? preferredSearchProvider : null,
          );
      _log.d(
        preferredSearchProvider.isNotEmpty
            ? 'Reset stale search provider $currentSearchProvider to $preferredSearchProvider'
            : 'Cleared stale search provider because $currentSearchProvider is no longer available',
      );
    }
  }

  Future<Map<String, dynamic>> getExtensionSettings(String extensionId) async {
    try {
      return await PlatformBridge.getExtensionSettings(extensionId);
    } catch (e) {
      _log.e('Failed to get extension settings: $e');
      return {};
    }
  }

  Future<bool> setExtensionSettings(
    String extensionId,
    Map<String, dynamic> settings,
  ) async {
    try {
      await PlatformBridge.setExtensionSettings(extensionId, settings);
      ref.invalidate(extensionSettingsProvider(extensionId));
      state = state.copyWith(
        settingsRevisions: {
          ...state.settingsRevisions,
          extensionId: (state.settingsRevisions[extensionId] ?? 0) + 1,
        },
      );
      _log.d('Updated settings for extension: $extensionId');
      return true;
    } catch (e) {
      _log.e('Failed to set extension settings: $e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> setHomeFeedRegion(String extensionId, String region) async {
    final extension = state.extensions
        .where((extension) => extension.id == extensionId)
        .firstOrNull;
    final setting = extension?.homeFeedRegionSetting;
    if (setting == null || !setting.options!.contains(region)) return false;
    try {
      final settings = await PlatformBridge.getExtensionSettings(extensionId);
      if ((settings[setting.key] ?? setting.defaultValue) == region) {
        return true;
      }
      return await setExtensionSettings(extensionId, {
        ...settings,
        setting.key: region,
      });
    } catch (error) {
      _log.e('Failed to update home feed country: $error');
      state = state.copyWith(error: error.toString());
      return false;
    }
  }

  /// Shared load path for the download/metadata priority lists: prefs first
  /// (sanitized), falling back to backend defaults, then persist + push the
  /// result back to the backend.
  Future<List<String>> _loadPriorityList({
    required String prefsKey,
    required String label,
    required List<String> Function(List<String>) sanitizeStored,
    required List<String> Function(List<String>) sanitizeBackend,
    required Future<List<String>> Function() fetchBackend,
    required Future<void> Function(List<String>) pushBackend,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(prefsKey);

    List<String> priority;
    if (savedJson != null) {
      final saved = _tryDecodeStringListPreference(savedJson, prefsKey);
      if (saved != null) {
        priority = sanitizeStored(saved);
        _log.d('Loaded $label from prefs: $priority');
      } else {
        await prefs.remove(prefsKey);
        priority = sanitizeBackend(await fetchBackend());
        _log.d('Recovered $label from defaults: $priority');
      }
    } else {
      priority = sanitizeBackend(await fetchBackend());
      _log.d('Using default $label: $priority');
    }
    await prefs.setString(prefsKey, jsonEncode(priority));
    await pushBackend(priority);
    return priority;
  }

  Future<void> loadProviderPriority() async {
    try {
      final priority = await _loadPriorityList(
        prefsKey: _providerPriorityKey,
        label: 'provider priority',
        sanitizeStored: _sanitizeDownloadProviderPriority,
        sanitizeBackend: _sanitizeDownloadProviderPriority,
        fetchBackend: PlatformBridge.getProviderPriority,
        pushBackend: PlatformBridge.setProviderPriority,
      );
      state = state.copyWith(providerPriority: priority);
    } catch (e) {
      _log.e('Failed to load provider priority: $e');
    }
  }

  Future<void> setProviderPriority(List<String> priority) async {
    try {
      final sanitized = _sanitizeDownloadProviderPriority(priority);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_providerPriorityKey, jsonEncode(sanitized));

      await PlatformBridge.setProviderPriority(sanitized);
      state = state.copyWith(providerPriority: sanitized);
      _log.d('Saved provider priority: $sanitized');
    } catch (e) {
      _log.e('Failed to set provider priority: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  List<String> _sanitizeDownloadProviderPriority(List<String> input) {
    final allowed = getAllDownloadProviders().toSet();
    final preferredOrder = getAllDownloadProviders();
    final result = <String>[];

    for (final provider in input) {
      if (allowed.contains(provider) && !result.contains(provider)) {
        result.add(provider);
      }
    }

    for (final provider in preferredOrder) {
      if (!result.contains(provider)) {
        result.add(provider);
      }
    }

    return result;
  }

  Future<void> loadMetadataProviderPriority() async {
    try {
      final priority = await _loadPriorityList(
        prefsKey: _metadataProviderPriorityKey,
        label: 'metadata provider priority',
        sanitizeStored: (saved) => _sanitizeMetadataProviderPriority(
          _replaceRetiredBuiltInMetadataProviders(saved),
        ),
        sanitizeBackend: _sanitizeMetadataProviderPriority,
        fetchBackend: PlatformBridge.getMetadataProviderPriority,
        pushBackend: PlatformBridge.setMetadataProviderPriority,
      );
      state = state.copyWith(metadataProviderPriority: priority);
    } catch (e) {
      _log.e('Failed to load metadata provider priority: $e');
    }
  }

  Future<void> setMetadataProviderPriority(List<String> priority) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sanitized = _sanitizeMetadataProviderPriority(
        _replaceRetiredBuiltInMetadataProviders(priority),
      );
      await prefs.setString(
        _metadataProviderPriorityKey,
        jsonEncode(sanitized),
      );

      await PlatformBridge.setMetadataProviderPriority(sanitized);
      state = state.copyWith(metadataProviderPriority: sanitized);
      _log.d('Saved metadata provider priority: $sanitized');
    } catch (e) {
      _log.e('Failed to set metadata provider priority: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  /// Priority lists for the extensions section of a backup. Empty lists are
  /// omitted so restoring them never replaces a device's own order.
  Map<String, dynamic> providerPriorityBackup() => {
    if (state.providerPriority.isNotEmpty)
      _providerPriorityKey: List<String>.from(state.providerPriority),
    if (state.metadataProviderPriority.isNotEmpty)
      _metadataProviderPriorityKey: List<String>.from(
        state.metadataProviderPriority,
      ),
  };

  /// Applies backed-up priority lists. Call after restored extensions are
  /// installed: the setters drop IDs that are not available yet, and later
  /// installs would otherwise be appended after the defaults.
  Future<void> restoreProviderPriorityBackup(Map<String, dynamic> data) async {
    final download = _backupProviderIds(data[_providerPriorityKey]);
    if (download.isNotEmpty) await setProviderPriority(download);
    final metadata = _backupProviderIds(data[_metadataProviderPriorityKey]);
    if (metadata.isNotEmpty) await setMetadataProviderPriority(metadata);
  }

  List<String> _backupProviderIds(Object? raw) => raw is List
      ? _distinctProviderIds(raw.whereType<String>())
      : const <String>[];

  List<String> getAllDownloadProviders() {
    return _distinctProviderIds(
      state.extensions
          .where((ext) => ext.enabled && ext.hasDownloadProvider)
          .map((ext) => ext.id),
    );
  }

  List<String> getAllMetadataProviders() {
    final metadataExtensions = state.extensions
        .where((ext) => ext.enabled && ext.hasMetadataProvider)
        .toList();
    final primarySearchMetadataExtensions = metadataExtensions
        .where((ext) => ext.searchBehavior?.primary == true)
        .map((ext) => ext.id);
    final otherMetadataExtensions = metadataExtensions
        .where((ext) => ext.searchBehavior?.primary != true)
        .map((ext) => ext.id);

    return _distinctProviderIds([
      ...primarySearchMetadataExtensions,
      ...otherMetadataExtensions,
    ]);
  }

  List<String> _distinctProviderIds(Iterable<String> ids) {
    final seen = <String>{};
    final result = <String>[];
    for (final id in ids) {
      final normalized = id.trim();
      if (normalized.isNotEmpty && seen.add(normalized)) {
        result.add(normalized);
      }
    }
    return result;
  }

  List<String> _replaceRetiredBuiltInMetadataProviders(List<String> input) {
    final result = <String>[];
    for (final provider in input) {
      final replacement = replacedBuiltInMetadataProviderFor(provider);
      final resolved = replacement ?? provider;
      if (!result.contains(resolved)) {
        result.add(resolved);
      }
    }
    return result;
  }

  List<String> _sanitizeMetadataProviderPriority(List<String> input) {
    final allowed = getAllMetadataProviders().toSet();
    final preferredOrder = getAllMetadataProviders();
    final result = <String>[];

    for (final provider in input) {
      if (allowed.contains(provider) && !result.contains(provider)) {
        result.add(provider);
      }
    }

    if (result.isEmpty && preferredOrder.isNotEmpty) {
      return List<String>.from(preferredOrder);
    }

    for (final provider in preferredOrder) {
      if (!result.contains(provider)) {
        result.add(provider);
      }
    }

    return result;
  }
}
