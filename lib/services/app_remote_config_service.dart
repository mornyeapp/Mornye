import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AppRemoteConfig');

class AppRemoteConfig {
  final RemoteAnnouncement? announcement;
  final DonateConfig donate;

  const AppRemoteConfig({this.announcement, required this.donate});

  factory AppRemoteConfig.fromJson(Map<String, dynamic> json) {
    final announcementJson = json['announcement'];
    final donateJson = json['donate'];

    return AppRemoteConfig(
      announcement: announcementJson is Map
          ? RemoteAnnouncement.fromJson(
              Map<String, dynamic>.from(announcementJson),
            )
          : null,
      donate: donateJson is Map
          ? DonateConfig.fromJson(Map<String, dynamic>.from(donateJson))
          : DonateConfig.fallback(),
    );
  }
}

class RemoteConfigSnapshot {
  final AppRemoteConfig config;
  final String rawJson;
  final bool changed;

  const RemoteConfigSnapshot({
    required this.config,
    required this.rawJson,
    required this.changed,
  });
}

class RemoteAnnouncement {
  final String id;
  final bool enabled;
  final String title;
  final String message;
  final bool ctaEnabled;
  final String? ctaLabel;
  final String? ctaUrl;
  final bool dismissible;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String? minVersion;
  final String? maxVersion;
  final String priority;

  const RemoteAnnouncement({
    required this.id,
    required this.enabled,
    required this.title,
    required this.message,
    this.ctaEnabled = false,
    this.ctaLabel,
    this.ctaUrl,
    this.dismissible = true,
    this.startsAt,
    this.endsAt,
    this.minVersion,
    this.maxVersion,
    this.priority = 'normal',
  });

  factory RemoteAnnouncement.fromJson(Map<String, dynamic> json) {
    return RemoteAnnouncement(
      id: _readString(json['id']),
      enabled: json['enabled'] as bool? ?? true,
      title: _readString(json['title']),
      message: _readString(json['message']),
      ctaEnabled: _readBool(json['cta_enabled'] ?? json['ctaEnabled']),
      ctaLabel: _readNullableString(json['cta_label'] ?? json['ctaLabel']),
      ctaUrl: _readNullableString(json['cta_url'] ?? json['ctaUrl']),
      dismissible: json['dismissible'] as bool? ?? true,
      startsAt: _readDate(json['starts_at'] ?? json['startsAt']),
      endsAt: _readDate(json['ends_at'] ?? json['endsAt']),
      minVersion: _readNullableString(
        json['min_version'] ?? json['minVersion'],
      ),
      maxVersion: _readNullableString(
        json['max_version'] ?? json['maxVersion'],
      ),
      priority: _readString(json['priority']).isEmpty
          ? 'normal'
          : _readString(json['priority']),
    );
  }

  bool get hasCta =>
      ctaEnabled &&
      ctaLabel != null &&
      ctaLabel!.isNotEmpty &&
      ctaUrl != null &&
      ctaUrl!.isNotEmpty;

  bool isActive({DateTime? now, String currentVersion = AppInfo.version}) {
    if (!enabled || id.isEmpty || title.isEmpty || message.isEmpty) {
      return false;
    }

    final referenceTime = now ?? DateTime.now();
    if (startsAt != null && referenceTime.isBefore(startsAt!)) {
      return false;
    }
    if (endsAt != null && referenceTime.isAfter(endsAt!)) {
      return false;
    }
    if (minVersion != null &&
        minVersion!.isNotEmpty &&
        _compareVersions(currentVersion, minVersion!) < 0) {
      return false;
    }
    if (maxVersion != null &&
        maxVersion!.isNotEmpty &&
        _compareVersions(currentVersion, maxVersion!) > 0) {
      return false;
    }

    return true;
  }
}

class DonateConfig {
  final bool enabled;
  final String title;
  final List<DonateMethod> methods;
  final List<String> supporters;
  final List<String> notices;
  final MonthlyDonationGoal? monthlyGoal;

  const DonateConfig({
    required this.enabled,
    required this.title,
    required this.methods,
    required this.supporters,
    required this.notices,
    this.monthlyGoal,
  });

  factory DonateConfig.fromJson(Map<String, dynamic> json) {
    final monthlyGoalJson = json['monthly_goal'];
    final methods = (json['methods'] as List<dynamic>? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((value) => DonateMethod.fromJson(Map<String, dynamic>.from(value)))
        .where((method) => method.isValid)
        .toList(growable: false);

    return DonateConfig(
      enabled: json['enabled'] as bool? ?? true,
      title: _readString(json['title']).isEmpty
          ? 'Support ${AppInfo.appName}'
          : _mobileDonationText(_readString(json['title'])),
      methods: methods.isEmpty ? DonateConfig.fallback().methods : methods,
      supporters: _readStringList(
        json['supporters'] ?? json['recent_supporters'],
      ),
      notices: _readStringList(json['notices']).isEmpty
          ? DonateConfig.fallback().notices
          : _readStringList(json['notices']),
      monthlyGoal: monthlyGoalJson is Map
          ? MonthlyDonationGoal.fromJson(
              Map<String, dynamic>.from(monthlyGoalJson),
            )
          : null,
    );
  }

  factory DonateConfig.fallback() {
    return const DonateConfig(
      enabled: true,
      title: 'Support ${AppInfo.appName}',
      methods: [
        DonateMethod(
          id: 'kofi',
          title: 'Ko-fi',
          subtitle: 'ko-fi.com/zarzet',
          url: AppInfo.kofiUrl,
          icon: 'kofi',
          color: 0xFFFF5E5B,
        ),
        DonateMethod(
          id: 'github-sponsors',
          title: 'GitHub Sponsors',
          subtitle: 'github.com/sponsors/zarzet',
          url: AppInfo.githubSponsorsUrl,
          icon: 'github',
          color: 0xFF2D333B,
        ),
        DonateMethod(
          id: 'usdt-trc20',
          title: 'USDT (TRC20)',
          subtitle: 'TL7iAqjq9M8BwVMi9AtHvuAGHtdwEvsDta',
          walletAddress: 'TL7iAqjq9M8BwVMi9AtHvuAGHtdwEvsDta',
          icon: 'crypto',
          color: 0xFF26A17B,
        ),
      ],
      supporters: [],
      notices: [
        'Not selling early access, premium features, or paywalls',
        'Funds go to dev tools and testing devices',
        'Your support helps keep this project active',
        'Supporter list can be updated from the app API',
      ],
    );
  }
}

class MonthlyDonationGoal {
  final bool enabled;
  final bool active;
  final String period;
  final String title;
  final String description;
  final double progressPercent;
  final double progressRatio;
  final bool goalReached;
  final bool showAmounts;
  final bool showPercentage;
  final bool showSupporterCount;
  final bool showSourceBreakdown;
  final String currency;
  final double? targetAmount;
  final double? raisedAmount;
  final int supporterCount;
  final Map<String, MonthlyDonationSource> sources;

  const MonthlyDonationGoal({
    required this.enabled,
    required this.active,
    required this.period,
    required this.title,
    required this.description,
    required this.progressPercent,
    required this.progressRatio,
    required this.goalReached,
    required this.showAmounts,
    required this.showPercentage,
    required this.showSupporterCount,
    required this.showSourceBreakdown,
    required this.currency,
    required this.targetAmount,
    required this.raisedAmount,
    required this.supporterCount,
    required this.sources,
  });

  factory MonthlyDonationGoal.fromJson(Map<String, dynamic> json) {
    final display = json['display'] is Map
        ? Map<String, dynamic>.from(json['display'] as Map)
        : const <String, dynamic>{};
    final sourcesJson = json['sources'];
    return MonthlyDonationGoal(
      enabled: _readBool(json['enabled']),
      active: _readBool(json['active']),
      period: _readString(json['period']),
      title: _mobileDonationText(
        _readNullableString(json['title']) ??
            'Monthly ${AppInfo.appName} development goal',
      ),
      description: _mobileDonationText(_readString(json['description'])),
      progressPercent: (_readFiniteNumber(json['progress_percent']) ?? 0).clamp(
        0,
        double.maxFinite,
      ),
      progressRatio: (_readFiniteNumber(json['progress_ratio']) ?? 0).clamp(
        0,
        1,
      ),
      goalReached: _readBool(json['goal_reached']),
      showAmounts: _readBool(display['amounts'] ?? json['amounts_visible']),
      showPercentage: _readBool(display['percentage']),
      showSupporterCount: _readBool(display['supporter_count']),
      showSourceBreakdown: _readBool(display['source_breakdown']),
      currency: _readNullableString(json['currency']) ?? 'USD',
      targetAmount: _readFiniteNumber(json['target_amount']),
      raisedAmount: _readFiniteNumber(json['raised_amount']),
      supporterCount: (_readFiniteNumber(json['supporter_count']) ?? 0)
          .clamp(0, double.maxFinite)
          .toInt(),
      sources: {
        if (sourcesJson is Map)
          for (final entry in sourcesJson.entries)
            if (entry.key is String && entry.value is Map)
              entry.key as String: MonthlyDonationSource.fromJson(
                Map<String, dynamic>.from(entry.value as Map),
              ),
      },
    );
  }

  bool get isVisible => enabled && active;
}

class MonthlyDonationSource {
  final double? amount;

  const MonthlyDonationSource({required this.amount});

  factory MonthlyDonationSource.fromJson(Map<String, dynamic> json) =>
      MonthlyDonationSource(amount: _readFiniteNumber(json['amount']));
}

class DonateMethod {
  final String id;
  final String title;
  final String subtitle;
  final String? url;
  final String? walletAddress;
  final String icon;
  final int color;

  const DonateMethod({
    required this.id,
    required this.title,
    required this.subtitle,
    this.url,
    this.walletAddress,
    this.icon = 'heart',
    this.color = 0xFF6750A4,
  });

  factory DonateMethod.fromJson(Map<String, dynamic> json) {
    return DonateMethod(
      id: _readString(json['id']),
      title: _readString(json['title'] ?? json['label']),
      subtitle: _readString(json['subtitle']),
      url: _readNullableString(json['url']),
      walletAddress: _readNullableString(
        json['wallet_address'] ?? json['walletAddress'],
      ),
      icon: _readString(json['icon']).isEmpty
          ? 'heart'
          : _readString(json['icon']),
      color: _readColor(json['color']) ?? 0xFF6750A4,
    );
  }

  bool get isWallet => walletAddress != null && walletAddress!.isNotEmpty;

  bool get isLink => url != null && url!.isNotEmpty;

  bool get isValid => id.isNotEmpty && title.isNotEmpty && (isLink || isWallet);
}

class AppRemoteConfigService {
  static const _cachedConfigJsonKey = 'app_remote_config_cached_json';
  static const _cachedConfigFetchedAtKey =
      'app_remote_config_cached_fetched_at';
  static const _dismissedAnnouncementIdsKey =
      'app_remote_config_dismissed_announcement_ids';

  final http.Client? _client;
  final String endpoint;

  AppRemoteConfigService({
    http.Client? client,
    this.endpoint = AppInfo.remoteConfigApiUrl,
  }) : _client = client;

  Future<RemoteConfigSnapshot?> readCachedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = prefs.getString(_cachedConfigJsonKey);
    if (cachedJson == null || cachedJson.isEmpty) {
      return null;
    }

    return _parseSnapshot(cachedJson, changed: false);
  }

  Future<RemoteConfigSnapshot?> fetchConfigSnapshot({String? locale}) async {
    // A default client belongs to this request; an injected client belongs to
    // its caller. Cached config and dismissal helpers need no HTTP resources.
    final client = _client ?? http.Client();
    try {
      final uri = Uri.parse(endpoint).replace(
        queryParameters: {
          'platform': Platform.isAndroid ? 'android' : Platform.operatingSystem,
          'version': AppInfo.version,
          'build': AppInfo.buildNumber,
          if (locale != null && locale.isNotEmpty) 'locale': locale,
        },
      );

      final response = await client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'User-Agent': '${AppInfo.appName}/${AppInfo.version}',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        _log.w('Remote config API returned ${response.statusCode}');
        return null;
      }

      final snapshot = _parseSnapshot(response.body);
      if (snapshot == null) return null;

      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(_cachedConfigJsonKey);
      if (cachedJson != snapshot.rawJson) {
        await prefs.setString(_cachedConfigJsonKey, snapshot.rawJson);
        await prefs.setString(
          _cachedConfigFetchedAtKey,
          DateTime.now().toIso8601String(),
        );
        return RemoteConfigSnapshot(
          config: snapshot.config,
          rawJson: snapshot.rawJson,
          changed: true,
        );
      }

      return snapshot;
    } catch (e) {
      _log.w('Remote config fetch failed: $e');
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<RemoteAnnouncement?> fetchActiveAnnouncement({String? locale}) async {
    final snapshot =
        await fetchConfigSnapshot(locale: locale) ?? await readCachedConfig();
    final announcement = snapshot?.config.announcement;
    if (announcement == null || !announcement.isActive()) {
      return null;
    }

    final prefs = await SharedPreferences.getInstance();
    final dismissedIds =
        prefs.getStringList(_dismissedAnnouncementIdsKey) ?? const <String>[];
    if (dismissedIds.contains(announcement.id)) {
      return null;
    }

    return announcement;
  }

  Future<void> markAnnouncementDismissed(String id) async {
    if (id.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final dismissedIds =
        prefs.getStringList(_dismissedAnnouncementIdsKey) ?? const <String>[];
    if (dismissedIds.contains(id)) return;

    await prefs.setStringList(_dismissedAnnouncementIdsKey, [
      ...dismissedIds,
      id,
    ]);
  }

  RemoteConfigSnapshot? _parseSnapshot(String body, {bool changed = false}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        _log.w('Remote config API returned non-object JSON');
        return null;
      }

      final normalizedJson = jsonEncode(decoded);
      return RemoteConfigSnapshot(
        config: AppRemoteConfig.fromJson(Map<String, dynamic>.from(decoded)),
        rawJson: normalizedJson,
        changed: changed,
      );
    } catch (e) {
      _log.w('Remote config JSON parse failed: $e');
      return null;
    }
  }
}

String _readString(Object? value) {
  return value is String ? value.trim() : '';
}

String _mobileDonationText(String text) => text.replaceAll(
  RegExp(r'\bSpotiFLAC(?:[ -]+Mobile)?\b', caseSensitive: false),
  AppInfo.appName,
);

double? _readFiniteNumber(Object? value) {
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return number != null && number.isFinite ? number : null;
}

String? _readNullableString(Object? value) {
  final text = _readString(value);
  return text.isEmpty ? null : text;
}

bool _readBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

DateTime? _readDate(Object? value) {
  final text = _readString(value);
  return text.isEmpty ? null : DateTime.tryParse(text);
}

List<String> _readStringList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<String>()
      .map((text) => text.trim())
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

int? _readColor(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is! String) {
    return null;
  }

  final normalized = value.trim().replaceFirst('#', '').replaceFirst('0x', '');
  if (normalized.length == 6) {
    return int.tryParse('FF$normalized', radix: 16);
  }
  if (normalized.length == 8) {
    return int.tryParse(normalized, radix: 16);
  }
  return null;
}

int _compareVersions(String left, String right) {
  final leftParts = _versionParts(left);
  final rightParts = _versionParts(right);

  for (var index = 0; index < 3; index++) {
    if (leftParts[index] > rightParts[index]) return 1;
    if (leftParts[index] < rightParts[index]) return -1;
  }

  return 0;
}

List<int> _versionParts(String version) {
  final base = version.split('-').first;
  final parts = base
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList(growable: true);
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts.take(3).toList(growable: false);
}
