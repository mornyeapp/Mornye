import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('UpdateChecker');

enum _ApkVariant { arm64, arm32, universal }

class _ApkAsset {
  final String name;
  final String url;
  final _ApkVariant variant;
  final String? sha256;

  const _ApkAsset({
    required this.name,
    required this.url,
    required this.variant,
    this.sha256,
  });
}

/// How the running build applies an update.
enum UpdateInstallKind {
  /// Android: download the APK and hand it to the package installer.
  apk,

  /// Windows: run the Inno Setup installer silently, then quit.
  windowsInstaller,

  /// macOS: open the disk image in Finder. Unsigned builds are not replaced
  /// in place; the user drags the new app over the old one.
  macosDiskImage,

  /// Linux AppImage: replace the running AppImage file, then restart.
  linuxAppImage,

  /// No self-update (iOS, deb, Flatpak, a plain bundle, or no matching
  /// asset): open the release page.
  releasePage,
}

/// How a Linux build was installed.
enum LinuxPackageKind { appImage, deb, flatpak, bundle }

/// The operating system, CPU and install format the update must match.
class UpdateHost {
  /// A [Platform.operatingSystem] value, or `unsupported`.
  final String os;

  /// `x64`, `arm64` or `other`.
  final String arch;

  /// Set on Linux only.
  final LinuxPackageKind? linuxPackage;

  /// The running AppImage file (`$APPIMAGE`), when [linuxPackage] is
  /// [LinuxPackageKind.appImage].
  final String? appImagePath;

  const UpdateHost({
    required this.os,
    this.arch = 'other',
    this.linuxPackage,
    this.appImagePath,
  });

  static const android = UpdateHost(os: 'android');
  static const unsupported = UpdateHost(os: 'unsupported');

  factory UpdateHost.current() {
    if (Platform.isAndroid) return android;
    if (!isDesktopPlatform) return unsupported;
    final arch = archForAbi(Abi.current());
    if (!Platform.isLinux) {
      return UpdateHost(os: Platform.operatingSystem, arch: arch);
    }
    final environment = Platform.environment;
    final package = detectLinuxPackage(
      environment: environment,
      resolvedExecutable: Platform.resolvedExecutable,
      flatpakInfoExists: File('/.flatpak-info').existsSync(),
    );
    return UpdateHost(
      os: 'linux',
      arch: arch,
      linuxPackage: package,
      appImagePath: package == LinuxPackageKind.appImage
          ? environment['APPIMAGE']
          : null,
    );
  }

  static String archForAbi(Abi abi) {
    if (abi == Abi.macosArm64 ||
        abi == Abi.windowsArm64 ||
        abi == Abi.linuxArm64) {
      return 'arm64';
    }
    if (abi == Abi.macosX64 || abi == Abi.windowsX64 || abi == Abi.linuxX64) {
      return 'x64';
    }
    return 'other';
  }

  /// The AppImage runtime exports `APPIMAGE`; Flatpak exports `FLATPAK_ID`
  /// and mounts `/.flatpak-info`. Anything else under `/usr` or `/opt` came
  /// from the deb (or another system package).
  static LinuxPackageKind detectLinuxPackage({
    required Map<String, String> environment,
    required String resolvedExecutable,
    bool flatpakInfoExists = false,
  }) {
    if (flatpakInfoExists || (environment['FLATPAK_ID'] ?? '').isNotEmpty) {
      return LinuxPackageKind.flatpak;
    }
    final appImage = environment['APPIMAGE'] ?? '';
    if (appImage.startsWith('/')) return LinuxPackageKind.appImage;
    if (resolvedExecutable.startsWith('/usr/') ||
        resolvedExecutable.startsWith('/opt/')) {
      return LinuxPackageKind.deb;
    }
    return LinuxPackageKind.bundle;
  }

  bool get supportsUpdateCheck =>
      os == 'android' || os == 'macos' || os == 'windows' || os == 'linux';

  /// The install path this host would use if the release has its asset.
  UpdateInstallKind get installKind => switch (os) {
    'android' => UpdateInstallKind.apk,
    'windows' => UpdateInstallKind.windowsInstaller,
    'macos' => UpdateInstallKind.macosDiskImage,
    'linux'
        when linuxPackage == LinuxPackageKind.appImage &&
            appImagePath != null =>
      UpdateInstallKind.linuxAppImage,
    _ => UpdateInstallKind.releasePage,
  };
}

/// A downloadable file of a GitHub release.
class ReleaseAsset {
  final String name;
  final String url;

  /// GitHub's `digest` for the asset, when it reports one.
  final String? sha256;

  const ReleaseAsset({required this.name, required this.url, this.sha256});
}

class UpdateInfo {
  final String version;
  final String changelog;
  final String downloadUrl;
  final String? apkDownloadUrl;
  final String? apkSha256;

  /// How many stable (non-prerelease) releases are newer than the installed
  /// version. Drives the forced-update flow.
  final int releasesBehind;

  final UpdateInstallKind installKind;

  /// The desktop package to download (dmg, installer or AppImage).
  final String? assetName;
  final String? assetUrl;
  final String? assetSha256;

  /// The release's SHA256SUMS.txt, which desktop downloads are checked
  /// against.
  final String? checksumsUrl;

  /// The AppImage file to replace, for [UpdateInstallKind.linuxAppImage].
  final String? appImagePath;

  const UpdateInfo({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
    this.apkDownloadUrl,
    this.apkSha256,
    this.releasesBehind = 0,
    UpdateInstallKind? installKind,
    this.assetName,
    this.assetUrl,
    this.assetSha256,
    this.checksumsUrl,
    this.appImagePath,
  }) : installKind =
           installKind ??
           (apkDownloadUrl != null
               ? UpdateInstallKind.apk
               : UpdateInstallKind.releasePage);

  /// True when the update is a desktop package the app downloads itself.
  bool get hasDesktopPackage =>
      assetUrl != null &&
      assetName != null &&
      (installKind == UpdateInstallKind.windowsInstaller ||
          installKind == UpdateInstallKind.macosDiskImage ||
          installKind == UpdateInstallKind.linuxAppImage);
}

class UpdateChecker {
  final http.Client? _client;
  final String _installedVersion;
  final UpdateHost _host;
  final List<String>? _supportedAbis;

  /// [host] defaults to the running build. [isAndroid] is a shorthand for
  /// tests: true for Android, false for a platform without updates.
  UpdateChecker({
    http.Client? client,
    String installedVersion = AppInfo.version,
    bool? isAndroid,
    List<String>? supportedAbis,
    UpdateHost? host,
  }) : _client = client,
       _installedVersion = installedVersion,
       _host =
           host ??
           switch (isAndroid) {
             true => UpdateHost.android,
             false => UpdateHost.unsupported,
             null => UpdateHost.current(),
           },
       _supportedAbis = supportedAbis;

  /// Android updates come from the main repository; desktop packages are
  /// released in their own.
  String get _releaseRepo => _host.os == UpdateHost.android.os
      ? AppInfo.githubRepo
      : AppInfo.desktopGithubRepo;

  /// Installed versions this many stable releases (or more) behind must
  /// update before continuing to use the app.
  static const int forceUpdateThreshold = 3;

  // Revalidate on every check. A local TTL can hide a newly published release;
  // ETag still avoids downloading the release list when it has not changed.
  static const String _cachedBodyKey = 'update_checker_releases_json';
  static const String _cachedAtKey = 'update_checker_releases_fetched_at';
  static const String _cachedEtagKey = 'update_checker_releases_etag';
  static const String _cachedRepoKey = 'update_checker_releases_repo';

  Future<({String body, bool verified})?> _fetchReleasesBody() async {
    final prefs = await SharedPreferences.getInstance();
    final repo = _releaseRepo;
    // A list saved before the desktop repository split (no repo recorded) is
    // the main repository's.
    final cachedRepo = prefs.getString(_cachedRepoKey) ?? AppInfo.githubRepo;
    var cachedBody = cachedRepo == repo
        ? prefs.getString(_cachedBodyKey)
        : null;
    if (cachedBody != null) {
      try {
        _parseReleases(cachedBody);
      } on FormatException {
        cachedBody = null;
        _log.w('Ignoring invalid cached release list');
      }
    }

    final cachedEtag = prefs.getString(_cachedEtagKey);
    try {
      final response = await (_client?.get ?? http.get)(
        Uri.parse('https://api.github.com/repos/$repo/releases?per_page=30'),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'Cache-Control': 'no-cache',
          if (cachedBody != null && cachedEtag != null)
            'If-None-Match': cachedEtag,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 304 && cachedBody != null) {
        _log.i('Release list revalidated by GitHub (304)');
        await prefs.setInt(_cachedAtKey, DateTime.now().millisecondsSinceEpoch);
        return (body: cachedBody, verified: true);
      }
      if (response.statusCode != 200) {
        throw http.ClientException(
          'GitHub API returned ${response.statusCode}',
        );
      }

      // Invalid responses must not overwrite a usable offline snapshot.
      _parseReleases(response.body);
      await prefs.setString(_cachedBodyKey, response.body);
      await prefs.setString(_cachedRepoKey, repo);
      final etag = response.headers['etag'];
      if (etag != null) {
        await prefs.setString(_cachedEtagKey, etag);
      } else {
        await prefs.remove(_cachedEtagKey);
      }
      await prefs.setInt(_cachedAtKey, DateTime.now().millisecondsSinceEpoch);
      _log.i('Fetched current release list from GitHub (200)');
      return (body: response.body, verified: true);
    } catch (error) {
      _log.w('Could not refresh releases: $error');
      return cachedBody == null ? null : (body: cachedBody, verified: false);
    }
  }

  static List<Map<String, dynamic>> _parseReleases(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List<dynamic> ||
        decoded.any((release) => release is! Map<String, dynamic>)) {
      throw const FormatException('Invalid GitHub release list');
    }
    return decoded.cast<Map<String, dynamic>>();
  }

  Future<UpdateInfo?> checkForUpdate({String channel = 'stable'}) async {
    if (!_host.supportsUpdateCheck) {
      return null;
    }

    try {
      final snapshot = await _fetchReleasesBody();
      if (snapshot == null) {
        return null;
      }

      final releases = _parseReleases(snapshot.body);
      if (releases.isEmpty) {
        _log.i('No releases found');
        return null;
      }

      Map<String, dynamic>? releaseData;
      if (channel == 'preview') {
        releaseData = releases.first;
      } else {
        for (final release in releases) {
          if (release['prerelease'] != true) {
            releaseData = release;
            break;
          }
        }
      }
      if (releaseData == null) {
        _log.i('No stable release found');
        return null;
      }

      final tagName = releaseData['tag_name'] as String? ?? '';
      final latestVersion = tagName.replaceFirst('v', '');
      final isPrerelease = releaseData['prerelease'] as bool? ?? false;

      var releasesBehind = 0;
      for (final release in releases) {
        if (release['prerelease'] == true) continue;
        final version = (release['tag_name'] as String? ?? '').replaceFirst(
          'v',
          '',
        );
        if (version.isNotEmpty && _isNewerVersion(version, _installedVersion)) {
          releasesBehind++;
        }
      }

      if (!_isNewerVersion(latestVersion, _installedVersion)) {
        if (snapshot.verified) {
          _log.i(
            'No update available (current: $_installedVersion, latest: $latestVersion, channel: $channel)',
          );
        } else {
          _log.w(
            'Update availability could not be verified '
            '(current: $_installedVersion, cached latest: $latestVersion, channel: $channel)',
          );
        }
        return null;
      }

      final body = releaseData['body'] as String? ?? 'No changelog available';
      final htmlUrl =
          releaseData['html_url'] as String? ??
          'https://github.com/$_releaseRepo/releases';

      final releaseAssets = _collectReleaseAssets(
        releaseData['assets'] as List<dynamic>? ?? const [],
      );

      if (_host.os != 'android') {
        final asset = selectDesktopAsset(releaseAssets, _host);
        final installKind = asset == null
            ? UpdateInstallKind.releasePage
            : _host.installKind;
        _log.i(
          'Update available: $latestVersion (prerelease: $isPrerelease, '
          'releases behind: $releasesBehind), install: ${installKind.name}, '
          'asset: ${asset?.name ?? 'none'}',
        );
        return UpdateInfo(
          version: latestVersion,
          changelog: body,
          downloadUrl: htmlUrl,
          releasesBehind: releasesBehind,
          installKind: installKind,
          assetName: asset?.name,
          assetUrl: asset?.url,
          assetSha256: asset?.sha256,
          checksumsUrl: _checksumsAsset(releaseAssets)?.url,
          appImagePath: installKind == UpdateInstallKind.linuxAppImage
              ? _host.appImagePath
              : null,
        );
      }

      final assets = _collectApkAssets(releaseAssets);
      final selectedAsset = await _selectApkForCurrentDevice(assets);
      final apkUrl = selectedAsset?.url;

      _log.i(
        'Update available: $latestVersion (prerelease: $isPrerelease, '
        'releases behind: $releasesBehind), '
        'APK asset: ${selectedAsset?.name ?? 'none'}, APK URL: $apkUrl',
      );

      return UpdateInfo(
        version: latestVersion,
        changelog: body,
        downloadUrl: htmlUrl,
        apkDownloadUrl: apkUrl,
        apkSha256: selectedAsset?.sha256,
        releasesBehind: releasesBehind,
      );
    } catch (e) {
      _log.e('Error checking for updates: $e');
      return null;
    }
  }

  static bool _isNewerVersion(String latest, String current) {
    try {
      final latestBase = latest.split('-').first;
      final currentBase = current.split('-').first;

      final latestParts = latestBase.split('.').map(int.parse).toList();
      final currentParts = currentBase.split('.').map(int.parse).toList();

      while (latestParts.length < 3) {
        latestParts.add(0);
      }
      while (currentParts.length < 3) {
        currentParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }

      final latestHasSuffix = latest.contains('-');
      final currentHasSuffix = current.contains('-');

      if (!latestHasSuffix && currentHasSuffix) return true;

      return false;
    } catch (e) {
      _log.e('Error comparing versions: $e');
      return false;
    }
  }

  static List<ReleaseAsset> _collectReleaseAssets(List<dynamic> assets) {
    final releaseAssets = <ReleaseAsset>[];

    for (final asset in assets.whereType<Map<Object?, Object?>>()) {
      final assetMap = Map<String, dynamic>.from(asset);
      final name = (assetMap['name'] as String? ?? '').trim();
      if (name.isEmpty) continue;

      final downloadUrl = assetMap['browser_download_url'] as String?;
      final uri = downloadUrl != null ? Uri.tryParse(downloadUrl) : null;
      if (uri == null || uri.scheme != 'https') {
        _log.w('Skipping non-HTTPS asset URL: $downloadUrl');
        continue;
      }

      releaseAssets.add(
        ReleaseAsset(
          name: name,
          url: uri.toString(),
          sha256: _normalizeAssetDigest(assetMap['digest']?.toString()),
        ),
      );
    }

    return releaseAssets;
  }

  static List<_ApkAsset> _collectApkAssets(List<ReleaseAsset> assets) {
    final apkAssets = <_ApkAsset>[];

    for (final asset in assets) {
      final normalizedName = asset.name.toLowerCase();
      if (!normalizedName.endsWith('.apk')) {
        continue;
      }

      final variant = _apkVariantFromName(normalizedName);
      if (variant == null) {
        _log.w('Skipping APK with unknown variant: ${asset.name}');
        continue;
      }

      apkAssets.add(
        _ApkAsset(
          name: asset.name,
          url: asset.url,
          variant: variant,
          sha256: asset.sha256,
        ),
      );
    }

    return apkAssets;
  }

  static const _archAliases = {
    'x64': ['x86_64', 'x64', 'amd64'],
    'arm64': ['aarch64', 'arm64'],
  };

  static bool _nameMatchesArch(String lowerName, String arch) =>
      (_archAliases[arch] ?? const []).any(lowerName.contains);

  /// Picks the package [host] installs: the universal dmg on macOS, the
  /// setup .exe for the CPU on Windows (x64 runs emulated on Windows on
  /// Arm), and the AppImage for the CPU on Linux. Returns null when the host
  /// does not self-update or the release has no matching package.
  static ReleaseAsset? selectDesktopAsset(
    Iterable<ReleaseAsset> assets,
    UpdateHost host,
  ) {
    ReleaseAsset? firstWhere(bool Function(String lowerName) test) {
      for (final asset in assets) {
        if (test(asset.name.toLowerCase())) return asset;
      }
      return null;
    }

    switch (host.installKind) {
      case UpdateInstallKind.macosDiskImage:
        return firstWhere(
              (name) => name.endsWith('.dmg') && name.contains('universal'),
            ) ??
            firstWhere(
              (name) =>
                  name.endsWith('.dmg') && _nameMatchesArch(name, host.arch),
            );
      case UpdateInstallKind.windowsInstaller:
        bool isInstaller(String name) =>
            name.endsWith('.exe') && name.contains('setup');
        return firstWhere(
              (name) => isInstaller(name) && _nameMatchesArch(name, host.arch),
            ) ??
            (host.arch == 'arm64'
                ? firstWhere(
                    (name) =>
                        isInstaller(name) && _nameMatchesArch(name, 'x64'),
                  )
                : null);
      case UpdateInstallKind.linuxAppImage:
        return firstWhere(
          (name) =>
              name.endsWith('.appimage') && _nameMatchesArch(name, host.arch),
        );
      case UpdateInstallKind.apk:
      case UpdateInstallKind.releasePage:
        return null;
    }
  }

  static ReleaseAsset? _checksumsAsset(List<ReleaseAsset> assets) {
    for (final asset in assets) {
      final name = asset.name.toLowerCase();
      if (name == 'sha256sums.txt' || name == 'sha256sums') return asset;
    }
    return null;
  }

  static final _checksumLine = RegExp(r'^([a-fA-F0-9]{64})\s+\*?(.+)$');

  /// Reads [assetName]'s digest from `sha256sum` output (SHA256SUMS.txt).
  static String? sha256FromChecksums(String checksums, String assetName) {
    for (final line in const LineSplitter().convert(checksums)) {
      final match = _checksumLine.firstMatch(line.trim());
      if (match == null) continue;
      var name = match.group(2)!.trim();
      if (name.startsWith('./')) name = name.substring(2);
      if (name == assetName) return match.group(1)!.toLowerCase();
    }
    return null;
  }

  static String? _normalizeAssetDigest(String? digest) {
    if (digest == null) return null;
    final normalized = digest.trim().toLowerCase().replaceFirst(
      RegExp(r'^sha256:'),
      '',
    );
    return RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized) ? normalized : null;
  }

  static _ApkVariant? _apkVariantFromName(String name) {
    if (name.contains('universal')) {
      return _ApkVariant.universal;
    }
    if (name.contains('arm64') || name.contains('arm64-v8a')) {
      return _ApkVariant.arm64;
    }
    if (name.contains('arm32') ||
        name.contains('armeabi') ||
        name.contains('armv7') ||
        name.contains('v7a')) {
      return _ApkVariant.arm32;
    }
    return null;
  }

  Future<_ApkAsset?> _selectApkForCurrentDevice(List<_ApkAsset> assets) async {
    if (assets.isEmpty) {
      return null;
    }

    _ApkAsset? arm64Asset;
    _ApkAsset? arm32Asset;
    _ApkAsset? universalAsset;
    for (final asset in assets) {
      switch (asset.variant) {
        case _ApkVariant.arm64:
          arm64Asset ??= asset;
          break;
        case _ApkVariant.arm32:
          arm32Asset ??= asset;
          break;
        case _ApkVariant.universal:
          universalAsset ??= asset;
          break;
      }
    }

    final supportedAbis = _supportedAbis ?? await _getSupportedAndroidAbis();
    final hasArm64 = supportedAbis.any(_isArm64Abi);
    final hasArm32 = supportedAbis.any(_isArm32Abi);

    if (hasArm64) {
      return arm64Asset ?? universalAsset ?? arm32Asset;
    }
    if (hasArm32) {
      return arm32Asset ?? universalAsset;
    }

    if (universalAsset != null) {
      _log.w(
        'Could not match APK asset to supported ABIs ${supportedAbis.join(', ')}; '
        'falling back to universal APK.',
      );
      return universalAsset;
    }

    _log.w(
      'Could not match APK asset to supported ABIs ${supportedAbis.join(', ')}; '
      'no universal APK available.',
    );
    return null;
  }

  static Future<List<String>> _getSupportedAndroidAbis() async {
    if (!Platform.isAndroid) {
      return const [];
    }

    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final supportedAbis = androidInfo.supportedAbis
          .map((abi) => abi.toLowerCase())
          .where((abi) => abi.isNotEmpty)
          .toSet()
          .toList();
      _log.i('Detected supported Android ABIs: ${supportedAbis.join(', ')}');
      return supportedAbis;
    } catch (e) {
      _log.w('Failed to detect supported Android ABIs: $e');
      return const [];
    }
  }

  static bool _isArm64Abi(String abi) =>
      abi.contains('arm64') || abi.contains('aarch64');

  static bool _isArm32Abi(String abi) =>
      abi.contains('armeabi') || abi.contains('armv7') || abi.contains('arm');
}
