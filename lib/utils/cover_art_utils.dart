import 'dart:io';

/// Whether the URL host [host] names this device (`localhost`, 127/8,
/// `::1`): a cover URL there ends with the process that serves it.
bool isLoopbackHost(String host) {
  final name = host.toLowerCase();
  return name == 'localhost' ||
      (InternetAddress.tryParse(name)?.isLoopback ?? false);
}

/// Deezer CDN cover size pattern: /WxH-q-p-o-n.jpg
final RegExp _deezerCoverSizeRegex = RegExp(
  r'/(\d+)x(\d+)-(\d+)-(\d+)-(\d+)-(\d+)\.jpg$',
);

/// Upgrades a Spotify/Deezer cover URL to a display-quality resolution.
/// Existing Deezer URLs at or above 1000px are preserved so provider
/// extensions can supply higher-resolution artwork without being downgraded.
/// Non-matching URLs pass through unchanged.
String? highResCoverUrl(String? url) {
  if (url == null) return null;
  if (url.contains('ab67616d00001e02')) {
    return url.replaceAll('ab67616d00001e02', 'ab67616d0000b273');
  }
  if (url.contains('cdn-images.dzcdn.net') &&
      _deezerCoverSizeRegex.hasMatch(url)) {
    return url.replaceAllMapped(_deezerCoverSizeRegex, (m) {
      final width = int.tryParse(m[1] ?? '') ?? 0;
      final height = int.tryParse(m[2] ?? '') ?? 0;
      if (width >= 1000 && height >= 1000) return m[0]!;
      return '/1000x1000-${m[3]}-${m[4]}-${m[5]}-${m[6]}.jpg';
    });
  }
  return url;
}
