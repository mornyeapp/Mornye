import 'package:mornye/utils/artist_utils.dart';

/// Pure metadata-key conversion used by the different audio containers.
///
/// Keeping these mappings independent from FFmpeg execution makes the tag
/// contract directly testable and prevents container-specific policy from
/// being buried in the conversion orchestration.
class AudioMetadataMapper {
  const AudioMetadataMapper._();

  static String? extractLyricsForId3(Map<String, String>? metadata) {
    if (metadata == null) return null;

    String? fallback;
    for (final entry in metadata.entries) {
      final key = _normalizeKey(entry.key);
      if (key != 'UNSYNCEDLYRICS' && key != 'LYRICS') continue;

      final value = entry.value;
      if (value.trim().isEmpty) continue;
      if (key == 'UNSYNCEDLYRICS') return value;
      fallback ??= value;
    }

    return fallback;
  }

  /// Maps Vorbis-comment keys to the fields consumed by the native WAV/AIFF
  /// metadata writer.
  static Map<String, String> vorbisToNativeChunkFields(
    Map<String, String> metadata,
  ) {
    final fields = <String, String>{};

    void setIndexPair(String numberKey, String totalKey, String value) {
      final normalized = value.trim();
      if (normalized.isEmpty || normalized == '0') return;
      if (normalized.contains('/')) {
        final parts = normalized.split('/');
        fields[numberKey] = parts[0].trim();
        if (parts.length > 1 && parts[1].trim().isNotEmpty) {
          fields[totalKey] = parts[1].trim();
        }
      } else {
        fields[numberKey] = normalized;
      }
    }

    for (final entry in metadata.entries) {
      final key = _normalizeKey(entry.key);
      final value = entry.value;
      if (value.trim().isEmpty) continue;

      switch (key) {
        case 'TITLE':
          fields['title'] = value;
        case 'ARTIST':
          fields['artist'] = value;
        case 'ALBUM':
          fields['album'] = value;
        case 'ALBUMARTIST':
          fields['album_artist'] = value;
        case 'TRACKNUMBER':
        case 'TRACK':
        case 'TRCK':
          setIndexPair('track_number', 'track_total', value);
        case 'TRACKTOTAL':
        case 'TOTALTRACKS':
          if (value.trim() != '0') fields['track_total'] = value.trim();
        case 'DISCNUMBER':
        case 'DISC':
        case 'TPOS':
          setIndexPair('disc_number', 'disc_total', value);
        case 'DISCTOTAL':
        case 'TOTALDISCS':
          if (value.trim() != '0') fields['disc_total'] = value.trim();
        case 'DATE':
          fields['date'] = value;
        case 'YEAR':
          if ((fields['date'] ?? '').isEmpty) fields['date'] = value;
        case 'ISRC':
          fields['isrc'] = value;
        case 'GENRE':
          fields['genre'] = value;
        case 'COMPOSER':
          fields['composer'] = value;
        case 'ORGANIZATION':
        case 'LABEL':
        case 'PUBLISHER':
          fields['label'] = value;
        case 'COPYRIGHT':
          fields['copyright'] = value;
        case 'COMMENT':
        case 'DESCRIPTION':
          fields['comment'] = value;
        case 'ITUNESADVISORY':
        case 'EXPLICIT':
        case 'ISEXPLICIT':
          fields['explicit'] = _normalizeAdvisoryValue(value);
        case 'LYRICS':
        case 'UNSYNCEDLYRICS':
          fields['lyrics'] = value;
        case 'REPLAYGAINTRACKGAIN':
          fields['replaygain_track_gain'] = value;
        case 'REPLAYGAINTRACKPEAK':
          fields['replaygain_track_peak'] = value;
        case 'REPLAYGAINALBUMGAIN':
          fields['replaygain_album_gain'] = value;
        case 'REPLAYGAINALBUMPEAK':
          fields['replaygain_album_peak'] = value;
      }
    }

    return fields;
  }

  static Map<String, String> normalizeToVorbisComments(
    Map<String, String> metadata,
  ) {
    final vorbis = <String, String>{};

    for (final entry in metadata.entries) {
      final key = _normalizeKey(entry.key);
      final value = entry.value;

      switch (key) {
        case 'TITLE':
          vorbis['TITLE'] = value;
        case 'ARTIST':
          vorbis['ARTIST'] = value;
        case 'ALBUM':
          vorbis['ALBUM'] = value;
        case 'ALBUMARTIST':
          vorbis['ALBUMARTIST'] = value;
        case 'TRACKNUMBER':
        case 'TRACKNBR':
        case 'TRACK':
        case 'TRCK':
          if (value != '0') vorbis['TRACKNUMBER'] = value;
        case 'DISCNUMBER':
        case 'DISC':
        case 'TPOS':
          if (value != '0') vorbis['DISCNUMBER'] = value;
        case 'DATE':
          vorbis['DATE'] = value;
          final yearMatch = RegExp(r'^(\d{4})').firstMatch(value);
          if (yearMatch != null &&
              (!vorbis.containsKey('YEAR') || vorbis['YEAR']!.isEmpty)) {
            vorbis['YEAR'] = yearMatch.group(1)!;
          }
        case 'YEAR':
          vorbis['YEAR'] = value;
          if (!vorbis.containsKey('DATE') || vorbis['DATE']!.isEmpty) {
            vorbis['DATE'] = value;
          }
        case 'GENRE':
          vorbis['GENRE'] = value;
        case 'ISRC':
          vorbis['ISRC'] = value;
        case 'LABEL':
        case 'ORGANIZATION':
          vorbis['ORGANIZATION'] = value;
        case 'COPYRIGHT':
          vorbis['COPYRIGHT'] = value;
        case 'COMPOSER':
          vorbis['COMPOSER'] = value;
        case 'COMMENT':
          vorbis['COMMENT'] = value;
        case 'ITUNESADVISORY':
        case 'EXPLICIT':
        case 'ISEXPLICIT':
          vorbis['ITUNESADVISORY'] = _normalizeAdvisoryValue(value);
        case 'LYRICS':
        case 'UNSYNCEDLYRICS':
          vorbis['LYRICS'] = value;
          vorbis['UNSYNCEDLYRICS'] = value;
        case 'REPLAYGAINTRACKGAIN':
          vorbis['REPLAYGAIN_TRACK_GAIN'] = value;
        case 'REPLAYGAINTRACKPEAK':
          vorbis['REPLAYGAIN_TRACK_PEAK'] = value;
        case 'REPLAYGAINALBUMGAIN':
          vorbis['REPLAYGAIN_ALBUM_GAIN'] = value;
        case 'REPLAYGAINALBUMPEAK':
          vorbis['REPLAYGAIN_ALBUM_PEAK'] = value;
        case 'R128TRACKGAIN':
          vorbis['R128_TRACK_GAIN'] = value;
        case 'R128ALBUMGAIN':
          vorbis['R128_ALBUM_GAIN'] = value;
      }
    }

    return vorbis;
  }

  static void appendVorbisMetadataArguments(
    List<String> arguments,
    Map<String, String> metadata, {
    String artistTagMode = artistTagModeJoined,
  }) {
    for (final entry in buildVorbisMetadataEntries(
      metadata,
      artistTagMode: artistTagMode,
    )) {
      arguments
        ..add('-metadata')
        ..add('${entry.key}=${entry.value}');
    }
  }

  static void appendMappedMetadataArguments(
    List<String> arguments,
    Map<String, String> metadata,
  ) {
    for (final entry in metadata.entries) {
      arguments
        ..add('-metadata')
        ..add('${entry.key}=${entry.value}');
    }
  }

  static List<MapEntry<String, String>> buildVorbisMetadataEntries(
    Map<String, String> metadata, {
    String artistTagMode = artistTagModeJoined,
  }) {
    final vorbis = normalizeToVorbisComments(metadata);
    final entries = <MapEntry<String, String>>[];

    for (final entry in vorbis.entries) {
      if (entry.key == 'ARTIST' || entry.key == 'ALBUMARTIST') {
        continue;
      }
      entries.add(entry);
    }

    _appendVorbisArtistEntries(
      entries,
      'ARTIST',
      vorbis['ARTIST'],
      artistTagMode: (metadata['artist_separator'] ?? '').isEmpty
          ? artistTagMode
          : artistTagModeJoined,
    );
    _appendVorbisArtistEntries(
      entries,
      'ALBUMARTIST',
      vorbis['ALBUMARTIST'],
      artistTagMode: (metadata['album_artist_separator'] ?? '').isEmpty
          ? artistTagMode
          : artistTagModeJoined,
    );

    return entries;
  }

  /// Maps generic metadata keys to M4A/MP4 tag names understood by FFmpeg.
  static Map<String, String> convertToM4aTags(Map<String, String> metadata) {
    final m4a = <String, String>{};

    for (final entry in metadata.entries) {
      if (entry.key.endsWith('_separator')) continue;
      final key = _normalizeKey(entry.key);
      final value = entry.value;

      switch (key) {
        case 'TITLE':
          m4a['title'] = value;
        case 'ARTIST':
          m4a['artist'] = value;
        case 'ALBUM':
          m4a['album'] = value;
        case 'ALBUMARTIST':
          m4a['album_artist'] = value;
        case 'TRACKNUMBER':
        case 'TRACK':
        case 'TRCK':
          m4a['track'] = value;
        case 'DISCNUMBER':
        case 'DISC':
        case 'TPOS':
          m4a['disc'] = value;
        case 'DATE':
          m4a['date'] = value;
        case 'YEAR':
          if (!m4a.containsKey('date') || m4a['date']!.isEmpty) {
            m4a['date'] = value;
          }
        case 'GENRE':
          m4a['genre'] = value;
        case 'ISRC':
          m4a['isrc'] = value;
        case 'COMPOSER':
          m4a['composer'] = value;
        case 'COMMENT':
          m4a['comment'] = value;
        case 'COPYRIGHT':
          m4a['copyright'] = value;
        case 'LABEL':
        case 'ORGANIZATION':
          m4a['organization'] = value;
        case 'LYRICS':
        case 'UNSYNCEDLYRICS':
          m4a['lyrics'] = value;
      }
    }

    return m4a;
  }

  /// Maps content-advisory and release identity tags to fields consumed by
  /// the native M4A editor. Content advisory is written as the integer `rtng`
  /// atom by that editor instead of an arbitrary MP4 text tag.
  static Map<String, String> m4aReleaseIdentityFields(
    Map<String, String> metadata,
  ) {
    final fields = <String, String>{};
    for (final entry in metadata.entries) {
      final key = _normalizeKey(entry.key);
      switch (key) {
        case 'ITUNESADVISORY':
        case 'EXPLICIT':
        case 'ISEXPLICIT':
          fields['explicit'] = _normalizeAdvisoryValue(entry.value);
        case 'RELEASETYPE':
          fields['album_type'] = entry.value;
        case 'BARCODE':
        case 'UPC':
          fields['upc'] = entry.value;
        case 'COMPILATION':
          fields['compilation'] = entry.value;
      }
    }
    return fields;
  }

  /// Maps generic metadata keys to ID3 names understood by FFmpeg.
  static Map<String, String> convertToId3Tags(Map<String, String> metadata) {
    final id3 = <String, String>{};

    for (final entry in metadata.entries) {
      if (entry.key.endsWith('_separator')) continue;
      final originalKey = entry.key.toUpperCase();
      final key = _normalizeKey(originalKey);
      final value = entry.value;

      switch (key) {
        case 'TITLE':
          id3['title'] = value;
        case 'ARTIST':
          id3['artist'] = value;
        case 'ALBUM':
          id3['album'] = value;
        case 'ALBUMARTIST':
          id3['album_artist'] = value;
        case 'TRACKNUMBER':
        case 'TRACK':
        case 'TRCK':
          if (value != '0') id3['track'] = value;
        case 'DISCNUMBER':
        case 'DISC':
        case 'TPOS':
          if (value != '0') id3['disc'] = value;
        case 'DATE':
          id3['date'] = value;
        case 'YEAR':
          if (!id3.containsKey('date') || id3['date']!.isEmpty) {
            id3['date'] = value;
          }
        case 'ISRC':
          id3['TSRC'] = value;
        case 'LYRICS':
        case 'UNSYNCEDLYRICS':
          id3['lyrics'] = value;
        case 'COMPOSER':
          id3['composer'] = value;
        case 'COMMENT':
          id3['comment'] = value;
        case 'ITUNESADVISORY':
        case 'EXPLICIT':
        case 'ISEXPLICIT':
          // ID3 has no dedicated advisory frame. FFmpeg stores this as the
          // conventional TXXX:ITUNESADVISORY user-text frame.
          id3['ITUNESADVISORY'] = _normalizeAdvisoryValue(value);
        case 'REPLAYGAINTRACKGAIN':
          id3['REPLAYGAIN_TRACK_GAIN'] = value;
        case 'REPLAYGAINTRACKPEAK':
          id3['REPLAYGAIN_TRACK_PEAK'] = value;
        case 'REPLAYGAINALBUMGAIN':
          id3['REPLAYGAIN_ALBUM_GAIN'] = value;
        case 'REPLAYGAINALBUMPEAK':
          id3['REPLAYGAIN_ALBUM_PEAK'] = value;
        default:
          id3[originalKey.toLowerCase()] = value;
      }
    }

    return id3;
  }

  static void _appendVorbisArtistEntries(
    List<MapEntry<String, String>> entries,
    String key,
    String? rawValue, {
    String artistTagMode = artistTagModeJoined,
  }) {
    if (rawValue == null) return;
    final value = rawValue.trim();
    if (value.isEmpty) {
      // Preserve an empty entry so FFmpeg clears an existing tag.
      entries.add(MapEntry(key, ''));
      return;
    }

    if (!shouldSplitVorbisArtistTags(artistTagMode)) {
      entries.add(MapEntry(key, artistTagValueForMode(value, artistTagMode)));
      return;
    }

    for (final artist in splitArtistTagValues(value)) {
      entries.add(MapEntry(key, artist));
    }
  }

  static String _normalizeKey(String key) =>
      key.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String _normalizeAdvisoryValue(String value) {
    return switch (value.trim().toLowerCase()) {
      'true' || 'yes' || 'explicit' => '1',
      'false' || 'no' => '0',
      final value => value,
    };
  }
}
