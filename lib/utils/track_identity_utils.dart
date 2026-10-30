import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:mornye/utils/artist_utils.dart';

/// Pure Dart Track Identity Engine for cross-device listening synchronization.
///
/// Provides deterministic canonical track keys, remaster/edition noise stripping,
/// musical version preservation (Live, Remix, Acoustic), and duration guard matching.
abstract class TrackIdentityUtils {
  TrackIdentityUtils._();

  static final List<RegExp> _editionPatterns = [
    RegExp(r'\s*-\s*\d{4}\s*Remaster.*$', caseSensitive: false),
    RegExp(r'\s*-\s*Remaster(ed)?.*$', caseSensitive: false),
    RegExp(r'\s*\(\d{4}\s*Remaster(ed)?.*?\)', caseSensitive: false),
    RegExp(r'\s*\(Remaster(ed)?.*?\)', caseSensitive: false),
    RegExp(r'\s*\(Deluxe\s*(Edition|Version)?.*?\)', caseSensitive: false),
    RegExp(r'\s*\(Special\s*(Edition|Version)?.*?\)', caseSensitive: false),
    RegExp(r'\s*\(Bonus\s*Track.*?\)', caseSensitive: false),
    RegExp(r'\s*\(Anniversary\s*(Edition)?.*?\)', caseSensitive: false),
    RegExp(r'\s*-\s*Single(\s*Version)?$', caseSensitive: false),
    RegExp(r'\s*\(Single(\s*Version)?\)', caseSensitive: false),
    RegExp(r'\s*-\s*Original\s*Mix$', caseSensitive: false),
    RegExp(r'\s*\(Original\s*Mix\)', caseSensitive: false),
  ];

  static final List<RegExp> _featuredArtistPatterns = [
    RegExp(r'\s*\(feat\.?.*?\)', caseSensitive: false),
    RegExp(r'\s*\(ft\.?.*?\)', caseSensitive: false),
    RegExp(r'\s*\(featuring.*?\)', caseSensitive: false),
    RegExp(r'\s*\(with.*?\)', caseSensitive: false),
    RegExp(r'\s*-\s*feat\.?.*$', caseSensitive: false),
    RegExp(r'\s*-\s*ft\.?.*$', caseSensitive: false),
  ];

  static final RegExp _multipleWhitespacePattern = RegExp(r'\s+');

  /// Normalizes and simplifies a track title:
  /// - Strips edition/remaster noise so remasters merge with originals.
  /// - Strips inline featured artist tags so collaboration titles align.
  /// - RETAINS performance versions: (Live), (Acoustic), (Remix), (Instrumental),
  ///   (Radio Edit) to prevent merging distinct musical recordings.
  static String simplifyTrackTitle(String rawTitle) {
    var title = rawTitle.trim();
    if (title.isEmpty) return '';

    for (final pattern in _editionPatterns) {
      title = title.replaceAll(pattern, '');
    }
    for (final pattern in _featuredArtistPatterns) {
      title = title.replaceAll(pattern, '');
    }

    return title
        .replaceAll(_multipleWhitespacePattern, ' ')
        .trim()
        .toLowerCase();
  }

  /// Extracts the primary artist name to align multi-artist credits across platforms.
  /// E.g. "Future, Drake" -> "future", "The Weeknd & Daft Punk" -> "the weeknd",
  /// "The Weeknd / Daft Punk" -> "the weeknd".
  static String extractPrimaryArtist(String rawArtist, {String? albumArtist}) {
    // Also treat slash ('/') as a collaborator separator common in ID3/Vorbis tags
    final normalized = rawArtist.replaceAll(RegExp(r'\s*/\s*'), ', ');
    final primary = primaryArtistName(normalized, albumArtist: albumArtist);
    return primary
        .replaceAll(_multipleWhitespacePattern, ' ')
        .trim()
        .toLowerCase();
  }

  /// Computes the universal deterministic canonical cross-device track key.
  ///
  /// Merges remastered reissues and differently tagged collaborations while
  /// isolating different songs and distinct versions (Live, Acoustic, Remix).
  static String canonicalKey({
    required String title,
    required String artist,
    String? albumArtist,
    String? source,
  }) {
    final cleanTitle = simplifyTrackTitle(title);
    final cleanArtist = extractPrimaryArtist(artist, albumArtist: albumArtist);

    // Conservative Fallback: Untagged tracks (e.g. empty or generic "Track 01")
    if (cleanTitle.isEmpty ||
        cleanArtist.isEmpty ||
        cleanTitle == 'track' ||
        cleanTitle.startsWith('track ') ||
        cleanTitle.startsWith('track_')) {
      final fallbackInput = source != null && source.isNotEmpty
          ? source
          : '$title|$artist';
      final digest = sha256.convert(utf8.encode(fallbackInput)).toString();
      return 'local_orphan:$digest';
    }

    return '$cleanTitle|$cleanArtist';
  }

  /// Duration Guard Matching Rule:
  /// Verifies whether candidate audio tracks match duration within acceptable tolerance.
  ///
  /// Allows up to 15 seconds or 8% tolerance to accommodate intro/outro silence
  /// across differing CD/vinyl/web encodings, while rejecting 3-minute radio edits
  /// against 7-minute live jams that lack explicit version tags.
  static bool matchesDuration(int durationMsA, int durationMsB) {
    if (durationMsA <= 0 || durationMsB <= 0) {
      return true; // Duration unmeasured
    }
    final diff = (durationMsA - durationMsB).abs();
    final maxAllowed = (durationMsA * 0.08).round().clamp(5000, 15000);
    return diff <= maxAllowed;
  }
}
