import 'package:flutter/foundation.dart';

class AppInfo {
  static const String version = '5.3.1';
  static const String buildNumber = '167';

  /// The release whose What's New tour people see once after updating. Change
  /// it together with the tour's pages when a release earns a new one.
  static const String whatsNewRelease = '5.3';

  static const String gitCommit = String.fromEnvironment('GIT_COMMIT');
  static String get shortGitCommit =>
      gitCommit.length > 8 ? gitCommit.substring(0, 8) : gitCommit;

  /// The version shown to people; debug builds stay internal.
  static String get displayVersion => versionLabel();

  @visibleForTesting
  static String versionLabel({bool debug = kDebugMode}) =>
      debug ? 'Internal' : version;

  static const String appName = 'Mornye Play';
  static const String license = 'LGPL-3.0-only';
  static const String copyright = '© 2026 Zarz Eleutherius';

  static const String mobileAuthor = 'zarzet';

  static const String githubRepo = 'famous37/Mornye';
  static const String githubUrl = 'https://github.com/$githubRepo';

  /// Desktop packages are published here; the source stays in [githubRepo].
  static const String desktopGithubRepo = 'mornyeapp/Mornye-Desktop';
  // The server keeps the endpoint name from before the rename.
  static const String remoteConfigApiUrl =
      'https://api.zarz.moe/v1/spotiflac-mobile/config';

  static const String kofiUrl = 'https://ko-fi.com/zarzet';
  static const String githubSponsorsUrl = 'https://github.com/sponsors/zarzet/';
}
