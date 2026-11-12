/// Protect manually installed Mornye Play online .sflx modifications from the
/// upstream extension store. Other extensions and other registries are
/// intentionally unaffected.
library;

/// Extensions that have Mornye Play online builds with the same extension IDs
/// as regular upstream downloads.
const protectedOnlineExtensionIds = <String>{
  'qobuz-web',
  'jellyfin',
  'soundcloud',
};

/// Mornye converts a GitHub repository URL to the raw registry.json URL.
/// Match the real URL authority and path segments instead of a string prefix
/// (which could incorrectly match another repository).
bool isOfficialMornyeExtensionRegistry(String registryUrl) {
  final uri = Uri.tryParse(registryUrl.trim());
  if (uri == null || uri.scheme != 'https') return false;

  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .map((segment) => segment.toLowerCase())
      .toList();
  if (segments.length < 2 ||
      segments[0] != 'mornyeapp' ||
      segments[1] != 'mornye-extension') {
    return false;
  }

  if (host == 'github.com') {
    return segments.length == 2 ||
        (segments.length == 3 && segments[2] == 'registry.json');
  }
  // Raw GitHub URLs contain a branch name before registry.json.
  if (host == 'raw.githubusercontent.com') {
    return segments.length >= 4 && segments.last == 'registry.json';
  }
  return false;
}

/// Do not replace a manually imported full-track-streaming .sflx with an
/// upstream package under the same ID. Disabled extensions are protected too.
bool isOfficialRepoUpdateBlocked({
  required String registryUrl,
  required String extensionId,
  required Map<String, dynamic>? installedCapabilities,
}) {
  return isOfficialMornyeExtensionRegistry(registryUrl) &&
      protectedOnlineExtensionIds.contains(extensionId.toLowerCase()) &&
      installedCapabilities?['fullTrackStreaming'] == true;
}
