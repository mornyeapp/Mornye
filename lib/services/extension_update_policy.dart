/// A manually installed Mornye Play .sflx must not be overwritten by any
/// extension repository update. Ordinary upstream extensions are unaffected.
library;

/// These IDs are shared by the original and our experimental online builds.
/// Only installed packages carrying the custom streaming capability are pinned.
const protectedOnlineExtensionIds = <String>{
  'qobuz-web',
  'jellyfin',
  'soundcloud',
};

/// Detect the *installed modified package*, never the repository URL.
///
/// This is intentionally applied to all store installs/upgrades regardless
/// of which registry supplied them. Manual import of a newer trusted .sflx
/// through Settings → Extensions is still permitted.
bool isModifiedSflxRepoUpdateBlocked({
  required String extensionId,
  required Map<String, dynamic>? installedCapabilities,
}) {
  return protectedOnlineExtensionIds.contains(extensionId.trim().toLowerCase()) &&
      installedCapabilities?['fullTrackStreaming'] == true;
}
