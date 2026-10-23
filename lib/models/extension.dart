class ExtensionRestoreResult {
  final int installed;
  final int alreadyPresent;
  final int failed;
  final List<String> failedIds;

  const ExtensionRestoreResult({
    this.installed = 0,
    this.alreadyPresent = 0,
    this.failed = 0,
    this.failedIds = const [],
  });
}

class ExtensionDownloadTransferPolicy {
  final int maxAttempts;
  final String resumePolicy;
  final bool persistentCheckpoint;
  final int maxParallelSegments;
  final int maxConcurrentDownloads;

  const ExtensionDownloadTransferPolicy({
    this.maxAttempts = 3,
    this.resumePolicy = 'none',
    this.persistentCheckpoint = false,
    this.maxParallelSegments = 3,
    this.maxConcurrentDownloads = 3,
  });

  factory ExtensionDownloadTransferPolicy.fromCapabilities(
    Map<String, dynamic> capabilities,
  ) {
    final raw = capabilities['downloadTransfer'];
    if (raw is! Map) return const ExtensionDownloadTransferPolicy();
    final values = Map<String, dynamic>.from(raw);
    int boundedInt(String key, int fallback, int min, int max) {
      final value = values[key];
      final parsed = value is num ? value.round() : fallback;
      return parsed.clamp(min, max).toInt();
    }

    final requestedResume = values['resumePolicy']?.toString().trim();
    final resumePolicy = requestedResume == 'validated' ? 'validated' : 'none';
    return ExtensionDownloadTransferPolicy(
      maxAttempts: boundedInt('maxAttempts', 3, 1, 8),
      resumePolicy: resumePolicy,
      persistentCheckpoint:
          resumePolicy == 'validated' && values['persistentCheckpoint'] == true,
      maxParallelSegments: boundedInt('maxParallelSegments', 3, 1, 8),
      maxConcurrentDownloads: boundedInt('maxConcurrentDownloads', 3, 1, 3),
    );
  }
}

/// First enabled custom-search extension, preferring ones marked primary.
Extension? defaultSearchExtension(List<Extension> extensions) {
  return extensions
          .where(
            (ext) =>
                ext.enabled &&
                ext.hasCustomSearch &&
                ext.searchBehavior?.primary == true,
          )
          .firstOrNull ??
      extensions.where((ext) => ext.enabled && ext.hasCustomSearch).firstOrNull;
}

class Extension {
  final String id;
  final String name;
  final String displayName;
  final String version;
  final String description;
  final bool enabled;
  final String status;
  final String? errorMessage;
  final String? iconPath;
  final List<String> permissions;
  final List<ExtensionSetting> settings;
  final List<QualityOption> qualityOptions;
  final bool hasMetadataProvider;
  final bool hasDownloadProvider;
  final bool hasLyricsProvider;
  final bool skipMetadataEnrichment;
  final bool skipLyrics;
  final bool stopProviderFallback;
  final SearchBehavior? searchBehavior;
  final URLHandler? urlHandler;
  final TrackMatching? trackMatching;
  final PostProcessing? postProcessing;
  final List<ExtensionServiceHealthCheck> serviceHealth;
  final Map<String, dynamic> capabilities;

  const Extension({
    required this.id,
    required this.name,
    required this.displayName,
    required this.version,
    required this.description,
    required this.enabled,
    required this.status,
    this.errorMessage,
    this.iconPath,
    this.permissions = const [],
    this.settings = const [],
    this.qualityOptions = const [],
    this.hasMetadataProvider = false,
    this.hasDownloadProvider = false,
    this.hasLyricsProvider = false,
    this.skipMetadataEnrichment = false,
    this.skipLyrics = false,
    this.stopProviderFallback = false,
    this.searchBehavior,
    this.urlHandler,
    this.trackMatching,
    this.postProcessing,
    this.serviceHealth = const [],
    this.capabilities = const {},
  });

  factory Extension.fromJson(Map<String, dynamic> json) {
    return Extension(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      displayName:
          json['display_name'] as String? ?? json['name'] as String? ?? '',
      version: json['version'] as String? ?? '0.0.0',
      description: json['description'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      status: json['status'] as String? ?? 'loaded',
      errorMessage: json['error_message'] as String?,
      iconPath: json['icon_path'] as String?,
      permissions:
          (json['permissions'] as List<dynamic>?)?.cast<String>() ?? [],
      settings:
          (json['settings'] as List<dynamic>?)
              ?.map((s) => ExtensionSetting.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      qualityOptions:
          (json['quality_options'] as List<dynamic>?)
              ?.map((q) => QualityOption.fromJson(q as Map<String, dynamic>))
              .toList() ??
          [],
      hasMetadataProvider: json['has_metadata_provider'] as bool? ?? false,
      hasDownloadProvider: json['has_download_provider'] as bool? ?? false,
      hasLyricsProvider: json['has_lyrics_provider'] as bool? ?? false,
      skipMetadataEnrichment:
          json['skip_metadata_enrichment'] as bool? ?? false,
      skipLyrics: json['skip_lyrics'] as bool? ?? false,
      stopProviderFallback: json['stop_provider_fallback'] as bool? ?? false,
      searchBehavior: json['search_behavior'] != null
          ? SearchBehavior.fromJson(
              json['search_behavior'] as Map<String, dynamic>,
            )
          : null,
      urlHandler: json['url_handler'] != null
          ? URLHandler.fromJson(json['url_handler'] as Map<String, dynamic>)
          : null,
      trackMatching: json['track_matching'] != null
          ? TrackMatching.fromJson(
              json['track_matching'] as Map<String, dynamic>,
            )
          : null,
      postProcessing: json['post_processing'] != null
          ? PostProcessing.fromJson(
              json['post_processing'] as Map<String, dynamic>,
            )
          : null,
      serviceHealth:
          (json['service_health'] as List<dynamic>?)
              ?.map(
                (h) => ExtensionServiceHealthCheck.fromJson(
                  h as Map<String, dynamic>,
                ),
              )
              .toList() ??
          [],
      capabilities: (json['capabilities'] as Map<String, dynamic>?) ?? const {},
    );
  }

  Extension copyWith({
    String? id,
    String? name,
    String? displayName,
    String? version,
    String? description,
    bool? enabled,
    String? status,
    String? errorMessage,
    String? iconPath,
    List<String>? permissions,
    List<ExtensionSetting>? settings,
    List<QualityOption>? qualityOptions,
    bool? hasMetadataProvider,
    bool? hasDownloadProvider,
    bool? hasLyricsProvider,
    bool? skipMetadataEnrichment,
    bool? skipLyrics,
    bool? stopProviderFallback,
    SearchBehavior? searchBehavior,
    URLHandler? urlHandler,
    TrackMatching? trackMatching,
    PostProcessing? postProcessing,
    List<ExtensionServiceHealthCheck>? serviceHealth,
    Map<String, dynamic>? capabilities,
  }) {
    return Extension(
      id: id ?? this.id,
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      version: version ?? this.version,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      iconPath: iconPath ?? this.iconPath,
      permissions: permissions ?? this.permissions,
      settings: settings ?? this.settings,
      qualityOptions: qualityOptions ?? this.qualityOptions,
      hasMetadataProvider: hasMetadataProvider ?? this.hasMetadataProvider,
      hasDownloadProvider: hasDownloadProvider ?? this.hasDownloadProvider,
      hasLyricsProvider: hasLyricsProvider ?? this.hasLyricsProvider,
      skipMetadataEnrichment:
          skipMetadataEnrichment ?? this.skipMetadataEnrichment,
      skipLyrics: skipLyrics ?? this.skipLyrics,
      stopProviderFallback: stopProviderFallback ?? this.stopProviderFallback,
      searchBehavior: searchBehavior ?? this.searchBehavior,
      urlHandler: urlHandler ?? this.urlHandler,
      trackMatching: trackMatching ?? this.trackMatching,
      postProcessing: postProcessing ?? this.postProcessing,
      serviceHealth: serviceHealth ?? this.serviceHealth,
      capabilities: capabilities ?? this.capabilities,
    );
  }

  bool get hasCustomSearch => searchBehavior?.enabled ?? false;
  bool get hasURLHandler => urlHandler?.enabled ?? false;
  bool get hasCustomMatching => trackMatching?.customMatching ?? false;
  bool get hasPostProcessing => postProcessing?.enabled ?? false;
  bool get hasServiceHealth => serviceHealth.isNotEmpty;
  bool get hasHomeFeed => capabilities['homeFeed'] == true;

  /// The extension owns its country choices and the setting sent to its API.
  ExtensionSetting? get homeFeedRegionSetting {
    if (!hasHomeFeed) return null;
    final key = capabilities['homeFeedRegionSetting'];
    if (key is! String || key.isEmpty) return null;
    return settings.where((setting) {
      final options = setting.options;
      return setting.key == key &&
          (setting.type == 'select' || setting.type == 'string') &&
          options != null &&
          options.isNotEmpty &&
          options.every((code) => RegExp(r'^[a-zA-Z]{2}$').hasMatch(code));
    }).firstOrNull;
  }

  ExtensionDownloadTransferPolicy get downloadTransferPolicy =>
      ExtensionDownloadTransferPolicy.fromCapabilities(capabilities);
  bool get requiresNativeContainerConversion =>
      capabilities['requiresContainerConversion'] == true ||
      capabilities['requiresNativeContainerConversion'] == true;
  List<String> get replacesBuiltInProviders {
    final value = capabilities['replacesBuiltInProviders'];
    if (value is! List) return const [];

    final normalized = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final trimmed = item.trim().toLowerCase();
      if (trimmed.isEmpty || normalized.contains(trimmed)) continue;
      normalized.add(trimmed);
    }
    return normalized;
  }

  String? get preferredDownloadOutputExtension {
    final value = capabilities['downloadOutputExtension'];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<String> get preservedNativeOutputExtensions {
    final value = capabilities['preserveNativeOutputExtensions'];
    if (value is! List) return const [];

    final normalized = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final trimmed = item.trim().toLowerCase();
      if (trimmed.isEmpty) continue;
      normalized.add(trimmed.startsWith('.') ? trimmed : '.$trimmed');
    }
    return normalized;
  }
}

String resolveEffectiveDownloadService(
  String requestedService,
  ExtensionState extensionState,
) => _resolveEffectiveProvider(
  requestedService,
  extensionState,
  (ext) => ext.hasDownloadProvider,
);

String resolveEffectiveMetadataProvider(
  String requestedProvider,
  ExtensionState extensionState,
) => _resolveEffectiveProvider(
  requestedProvider,
  extensionState,
  (ext) => ext.hasMetadataProvider,
);

String _resolveEffectiveProvider(
  String requested,
  ExtensionState extensionState,
  bool Function(Extension) hasProvider,
) {
  final normalizedRequested = requested.trim().toLowerCase();
  final enabled = extensionState.extensions
      .where((ext) => ext.enabled && hasProvider(ext))
      .toList(growable: false);

  if (normalizedRequested.isNotEmpty) {
    final matching = enabled
        .where((ext) => ext.id.trim().toLowerCase() == normalizedRequested)
        .firstOrNull;
    if (matching != null) {
      return matching.id;
    }

    final replacement = enabled
        .where(
          (ext) => ext.replacesBuiltInProviders.contains(normalizedRequested),
        )
        .firstOrNull;
    if (replacement != null) {
      return replacement.id;
    }
  }

  return enabled.firstOrNull?.id ?? '';
}

bool isDeezerCompatibleDownloadService(
  String service,
  ExtensionState extensionState,
) {
  final normalizedService = service.trim().toLowerCase();
  if (normalizedService.isEmpty) {
    return false;
  }

  return extensionState.extensions.any(
    (ext) =>
        ext.enabled &&
        ext.hasDownloadProvider &&
        ext.id.trim().toLowerCase() == normalizedService &&
        ext.replacesBuiltInProviders.contains('deezer'),
  );
}

class SearchFilter {
  final String id;
  final String? label;
  final String? icon;

  const SearchFilter({required this.id, this.label, this.icon});

  factory SearchFilter.fromJson(Map<String, dynamic> json) {
    return SearchFilter(
      id: json['id'] as String? ?? '',
      label: json['label'] as String?,
      icon: json['icon'] as String?,
    );
  }
}

String canonicalExtensionSearchFilterId(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '',
  );
  return switch (normalized) {
    'track' || 'tracks' || 'song' || 'songs' || 'music' => 'track',
    'artist' || 'artists' => 'artist',
    'album' || 'albums' => 'album',
    'playlist' || 'playlists' => 'playlist',
    _ => normalized,
  };
}

class SearchBehavior {
  final bool enabled;
  final String? placeholder;
  final bool primary;
  final String? icon;
  final String? thumbnailRatio;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
  final List<SearchFilter> filters;

  const SearchBehavior({
    required this.enabled,
    this.placeholder,
    this.primary = false,
    this.icon,
    this.thumbnailRatio,
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.filters = const [],
  });

  factory SearchBehavior.fromJson(Map<String, dynamic> json) {
    return SearchBehavior(
      enabled: json['enabled'] as bool? ?? false,
      placeholder: json['placeholder'] as String?,
      primary: json['primary'] as bool? ?? false,
      icon: json['icon'] as String?,
      thumbnailRatio: json['thumbnailRatio'] as String?,
      thumbnailWidth: json['thumbnailWidth'] as int?,
      thumbnailHeight: json['thumbnailHeight'] as int?,
      filters:
          (json['filters'] as List<dynamic>?)
              ?.map((f) => SearchFilter.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  String? filterIdForKind(String kind) {
    final canonicalKind = canonicalExtensionSearchFilterId(kind);
    for (final filter in filters) {
      if (canonicalExtensionSearchFilterId(filter.id) == canonicalKind ||
          (filter.label != null &&
              canonicalExtensionSearchFilterId(filter.label!) ==
                  canonicalKind) ||
          (filter.icon != null &&
              canonicalExtensionSearchFilterId(filter.icon!) ==
                  canonicalKind)) {
        final id = filter.id.trim();
        if (id.isNotEmpty) return id;
      }
    }
    return null;
  }

  (double, double) getThumbnailSize({double defaultSize = 56}) {
    if (thumbnailWidth != null && thumbnailHeight != null) {
      return (thumbnailWidth!.toDouble(), thumbnailHeight!.toDouble());
    }

    return switch (thumbnailRatio) {
      'wide' => (defaultSize * 16 / 9, defaultSize),
      'portrait' => (defaultSize * 2 / 3, defaultSize),
      _ => (defaultSize, defaultSize),
    };
  }
}

class TrackMatching {
  final bool customMatching;
  final String? strategy;
  final int durationTolerance;

  const TrackMatching({
    required this.customMatching,
    this.strategy,
    this.durationTolerance = 3,
  });

  factory TrackMatching.fromJson(Map<String, dynamic> json) {
    return TrackMatching(
      customMatching: json['customMatching'] as bool? ?? false,
      strategy: json['strategy'] as String?,
      durationTolerance: json['durationTolerance'] as int? ?? 3,
    );
  }
}

class PostProcessing {
  final bool enabled;
  final List<PostProcessingHook> hooks;

  const PostProcessing({required this.enabled, this.hooks = const []});

  factory PostProcessing.fromJson(Map<String, dynamic> json) {
    return PostProcessing(
      enabled: json['enabled'] as bool? ?? false,
      hooks:
          (json['hooks'] as List<dynamic>?)
              ?.map(
                (h) => PostProcessingHook.fromJson(h as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }
}

class URLHandler {
  final bool enabled;
  final List<String> patterns;

  const URLHandler({required this.enabled, this.patterns = const []});

  factory URLHandler.fromJson(Map<String, dynamic> json) {
    return URLHandler(
      enabled: json['enabled'] as bool? ?? false,
      patterns: (json['patterns'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

class ExtensionServiceHealthCheck {
  final String id;
  final String? label;
  final String url;
  final String method;
  final String? serviceKey;
  final int? timeoutMs;
  final int? cacheTtlSeconds;
  final bool required;

  const ExtensionServiceHealthCheck({
    required this.id,
    this.label,
    required this.url,
    this.method = 'GET',
    this.serviceKey,
    this.timeoutMs,
    this.cacheTtlSeconds,
    this.required = false,
  });

  factory ExtensionServiceHealthCheck.fromJson(Map<String, dynamic> json) {
    return ExtensionServiceHealthCheck(
      id: json['id'] as String? ?? '',
      label: json['label'] as String?,
      url: json['url'] as String? ?? '',
      method: json['method'] as String? ?? 'GET',
      serviceKey: json['serviceKey'] as String?,
      timeoutMs: json['timeoutMs'] as int?,
      cacheTtlSeconds: json['cacheTtlSeconds'] as int?,
      required: json['required'] as bool? ?? false,
    );
  }
}

class ExtensionHealthStatus {
  final String extensionId;
  final String status;
  final DateTime? checkedAt;
  final List<ExtensionHealthCheckStatus> checks;

  const ExtensionHealthStatus({
    required this.extensionId,
    required this.status,
    this.checkedAt,
    this.checks = const [],
  });

  factory ExtensionHealthStatus.fromJson(Map<String, dynamic> json) {
    return ExtensionHealthStatus(
      extensionId: json['extension_id'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      checkedAt: DateTime.tryParse(json['checked_at'] as String? ?? ''),
      checks:
          (json['checks'] as List<dynamic>?)
              ?.map(
                (c) => ExtensionHealthCheckStatus.fromJson(
                  c as Map<String, dynamic>,
                ),
              )
              .toList() ??
          [],
    );
  }
}

class ExtensionHealthCheckStatus {
  final String id;
  final String? label;
  final String url;
  final String method;
  final String? serviceKey;
  final bool required;
  final String status;
  final int? httpStatus;
  final int latencyMs;
  final String? message;
  final String? error;
  final DateTime? checkedAt;

  const ExtensionHealthCheckStatus({
    required this.id,
    this.label,
    required this.url,
    required this.method,
    this.serviceKey,
    this.required = false,
    required this.status,
    this.httpStatus,
    this.latencyMs = 0,
    this.message,
    this.error,
    this.checkedAt,
  });

  factory ExtensionHealthCheckStatus.fromJson(Map<String, dynamic> json) {
    return ExtensionHealthCheckStatus(
      id: json['id'] as String? ?? '',
      label: json['label'] as String?,
      url: json['url'] as String? ?? '',
      method: json['method'] as String? ?? 'GET',
      serviceKey: json['service_key'] as String?,
      required: json['required'] as bool? ?? false,
      status: json['status'] as String? ?? 'unknown',
      httpStatus: json['http_status'] as int?,
      latencyMs: json['latency_ms'] as int? ?? 0,
      message: json['message'] as String?,
      error: json['error'] as String?,
      checkedAt: DateTime.tryParse(json['checked_at'] as String? ?? ''),
    );
  }

  String get displayLabel => label?.trim().isNotEmpty == true ? label! : id;
}

class PostProcessingHook {
  final String id;
  final String name;
  final String? description;
  final bool defaultEnabled;
  final List<String> supportedFormats;

  const PostProcessingHook({
    required this.id,
    required this.name,
    this.description,
    this.defaultEnabled = false,
    this.supportedFormats = const [],
  });

  factory PostProcessingHook.fromJson(Map<String, dynamic> json) {
    return PostProcessingHook(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      defaultEnabled: json['defaultEnabled'] as bool? ?? false,
      supportedFormats:
          (json['supportedFormats'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

class QualityOption {
  final String id;
  final String label;
  final String? description;
  final List<QualitySpecificSetting> settings;

  const QualityOption({
    required this.id,
    required this.label,
    this.description,
    this.settings = const [],
  });

  factory QualityOption.fromJson(Map<String, dynamic> json) {
    return QualityOption(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      description: json['description'] as String?,
      settings:
          (json['settings'] as List<dynamic>?)
              ?.map(
                (s) =>
                    QualitySpecificSetting.fromJson(s as Map<String, dynamic>),
              )
              .toList() ??
          [],
    );
  }
}

class QualitySpecificSetting {
  final String key;
  final String label;
  final String type;
  final dynamic defaultValue;
  final String? description;
  final List<String>? options;
  final bool required;
  final bool secret;

  const QualitySpecificSetting({
    required this.key,
    required this.label,
    required this.type,
    this.defaultValue,
    this.description,
    this.options,
    this.required = false,
    this.secret = false,
  });

  factory QualitySpecificSetting.fromJson(Map<String, dynamic> json) {
    return QualitySpecificSetting(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      type: json['type'] as String? ?? 'string',
      defaultValue: json['default'],
      description: json['description'] as String?,
      options: (json['options'] as List<dynamic>?)?.cast<String>(),
      required: json['required'] as bool? ?? false,
      secret: json['secret'] as bool? ?? false,
    );
  }
}

class ExtensionSetting {
  final String key;
  final String label;
  final String type;
  final dynamic defaultValue;
  final String? description;
  final List<String>? options;
  final bool required;
  final String? action;

  const ExtensionSetting({
    required this.key,
    required this.label,
    required this.type,
    this.defaultValue,
    this.description,
    this.options,
    this.required = false,
    this.action,
  });

  factory ExtensionSetting.fromJson(Map<String, dynamic> json) {
    return ExtensionSetting(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      type: json['type'] as String? ?? 'string',
      defaultValue: json['default'],
      description: json['description'] as String?,
      options: (json['options'] as List<dynamic>?)?.cast<String>(),
      required: json['required'] as bool? ?? false,
      action: json['action'] as String?,
    );
  }
}

class ExtensionState {
  final List<Extension> extensions;
  final List<String> providerPriority;
  final List<String> metadataProviderPriority;
  final Map<String, ExtensionHealthStatus> healthStatuses;
  final bool isLoading;
  final String? error;
  final bool isInitialized;
  final Map<String, int> settingsRevisions;

  const ExtensionState({
    this.extensions = const [],
    this.providerPriority = const [],
    this.metadataProviderPriority = const [],
    this.healthStatuses = const {},
    this.isLoading = false,
    this.error,
    this.isInitialized = false,
    this.settingsRevisions = const {},
  });

  ExtensionState copyWith({
    List<Extension>? extensions,
    List<String>? providerPriority,
    List<String>? metadataProviderPriority,
    Map<String, ExtensionHealthStatus>? healthStatuses,
    bool? isLoading,
    String? error,
    bool? isInitialized,
    Map<String, int>? settingsRevisions,
  }) {
    return ExtensionState(
      extensions: extensions ?? this.extensions,
      providerPriority: providerPriority ?? this.providerPriority,
      metadataProviderPriority:
          metadataProviderPriority ?? this.metadataProviderPriority,
      healthStatuses: healthStatuses ?? this.healthStatuses,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isInitialized: isInitialized ?? this.isInitialized,
      settingsRevisions: settingsRevisions ?? this.settingsRevisions,
    );
  }
}

class ExtensionInstallBatchResult {
  final int attempted;
  final int installed;
  final Map<String, String> failures;

  const ExtensionInstallBatchResult({
    required this.attempted,
    required this.installed,
    this.failures = const {},
  });

  bool get hasFailures => failures.isNotEmpty;
  bool get anyInstalled => installed > 0;
}
