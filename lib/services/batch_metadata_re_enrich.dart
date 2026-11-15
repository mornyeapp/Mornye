import 'package:mornye/models/settings.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/string_utils.dart';

/// Field group keys understood by the native re-enrich backend.
class ReEnrichFields {
  static const String cover = 'cover';
  static const String lyrics = 'lyrics';
  static const String basicTags = 'basic_tags';
  static const String trackInfo = 'track_info';
  static const String releaseInfo = 'release_info';
  static const String extra = 'extra';

  static const List<String> all = [
    cover,
    lyrics,
    basicTags,
    trackInfo,
    releaseInfo,
    extra,
  ];
}

enum ReEnrichBatchMode { isrcOnly, missingOnly, selectedFields, manualValues }

/// Tags where applying one shared value to multiple tracks is normally safe.
/// Per-track identifiers, titles, and track/disc numbers are deliberately
/// excluded so the batch editor cannot accidentally duplicate them.
const List<String> manualBatchMetadataFields = [
  'artist_name',
  'album_name',
  'album_artist',
  'release_date',
  'genre',
  'composer',
  'label',
  'copyright',
];

class ReEnrichFieldSelection {
  final ReEnrichBatchMode mode;
  final List<String> fields;
  final Map<String, String> manualValues;

  const ReEnrichFieldSelection({
    required this.mode,
    this.fields = const [],
    this.manualValues = const {},
  });

  bool get usesManualValues => mode == ReEnrichBatchMode.manualValues;

  List<String> updateFieldsFor(LocalLibraryItem item) {
    switch (mode) {
      case ReEnrichBatchMode.isrcOnly:
        return const ['isrc'];
      case ReEnrichBatchMode.selectedFields:
        return fields;
      case ReEnrichBatchMode.missingOnly:
        return missingReEnrichFields(item);
      case ReEnrichBatchMode.manualValues:
        return manualValues.entries
            .where(
              (entry) =>
                  manualBatchMetadataFields.contains(entry.key) &&
                  entry.value.trim().isNotEmpty,
            )
            .map((entry) => entry.key)
            .toList(growable: false);
    }
  }
}

bool _missingText(String? value) {
  final normalized = value?.trim().toLowerCase() ?? '';
  return normalized.isEmpty ||
      normalized == 'unknown' ||
      normalized == 'unknown title' ||
      normalized == 'unknown artist' ||
      normalized == 'unknown album';
}

/// Returns granular tag keys, preventing a missing value from causing its
/// already-populated neighbors in the same backend group to be overwritten.
List<String> missingReEnrichFields(LocalLibraryItem item) {
  final fields = <String>[];
  if (_missingText(item.trackName)) fields.add('track_name');
  if (_missingText(item.artistName)) fields.add('artist_name');
  if (_missingText(item.albumName)) fields.add('album_name');
  if (_missingText(item.albumArtist)) fields.add('album_artist');
  if ((item.trackNumber ?? 0) <= 0) fields.add('track_number');
  if ((item.totalTracks ?? 0) <= 0) fields.add('total_tracks');
  if ((item.discNumber ?? 0) <= 0) fields.add('disc_number');
  if ((item.totalDiscs ?? 0) <= 0) fields.add('total_discs');
  if (_missingText(item.releaseDate)) fields.add('release_date');
  if (_missingText(item.isrc)) fields.add('isrc');
  if (_missingText(item.genre)) fields.add('genre');
  if (_missingText(item.composer)) fields.add('composer');
  if (_missingText(item.label)) fields.add('label');
  if (_missingText(item.copyright)) fields.add('copyright');
  if (_missingText(item.coverPath)) fields.add('cover');
  return fields;
}

/// How well an online result fits a song, as the re-enrich backend rates it.
/// Automatic runs apply only [exact] and [strong] results, and [weak] ones
/// for songs without an album.
enum ReEnrichMatch {
  /// The same ISRC.
  exact,

  /// Title, artist and album agree, and the length when both are known.
  strong,

  /// Title and artist agree, but the album is unknown or another release.
  weak,

  /// Anything else a provider returned for the search.
  other,

  /// Nothing was found.
  none;

  static ReEnrichMatch fromWire(Object? value) => switch (value) {
    'exact' => exact,
    'strong' => strong,
    'weak' => weak,
    'other' => other,
    _ => none,
  };

  /// Worth listing under Best matches.
  bool get likely => this == exact || this == strong || this == weak;
}

/// The online results a preview listed for a song, best first.
List<Map<String, dynamic>> reEnrichCandidates(Object? raw) => [
  if (raw is List)
    for (final candidate in raw)
      if (candidate is Map)
        candidate.map((key, value) => MapEntry(key.toString(), value)),
];

ReEnrichMatch reEnrichCandidateMatch(Map<String, dynamic> candidate) =>
    ReEnrichMatch.fromWire(candidate['match']);

Map<String, dynamic> buildBatchReEnrichRequest({
  required LocalLibraryItem item,
  required AppSettings settings,
  required List<String> updateFields,
  bool previewOnly = false,
  Map<String, dynamic>? resolvedMetadata,
  String? sourceTrackId,

  /// Asks the preview for the results it chose from, so a song can be
  /// matched by hand.
  bool includeCandidates = false,

  /// A result a person picked; it is applied instead of searching.
  Map<String, dynamic>? selectedCandidate,
}) {
  final request = <String, dynamic>{
    'file_path': item.filePath,
    'cover_url': '',
    'cover_max_dimension': settings.embeddedCoverMaxDimension,
    'embed_lyrics': settings.embedLyrics,
    'lyrics_mode': settings.lyricsMode,
    'artist_tag_mode': settings.artistTagMode,
    'spotify_id': sourceTrackId ?? '',
    'track_name': item.trackName,
    'artist_name': item.artistName,
    'album_name': item.albumName,
    'album_artist': item.albumArtist ?? '',
    'track_number': item.trackNumber ?? 0,
    'total_tracks': item.totalTracks ?? 0,
    'disc_number': item.discNumber ?? 0,
    'total_discs': item.totalDiscs ?? 0,
    'release_date': item.releaseDate ?? '',
    'isrc': item.isrc ?? '',
    'genre': item.genre ?? '',
    'composer': item.composer ?? '',
    'label': item.label ?? '',
    'copyright': item.copyright ?? '',
    'duration_ms': (item.duration ?? 0) * 1000,
    // Lyrics-only previews do not need a second metadata-provider search.
    // Preserve the file's title/artist and fetch lyrics during apply.
    'search_online':
        selectedCandidate != null ||
        (resolvedMetadata == null &&
            !(updateFields.length == 1 &&
                updateFields.single == ReEnrichFields.lyrics)),
    'replace_release_metadata': false,
    'update_fields': updateFields,
    if (previewOnly) 'preview_only': true,
    // A batch keeps the search's stop at the first confident provider: a
    // song that matched lists what was searched, one that did not lists
    // every provider's results.
    if (previewOnly && includeCandidates) ...{
      'include_candidates': true,
      'quick_candidates': true,
    },
    'selected_candidate': ?selectedCandidate,
  };
  if (resolvedMetadata != null) {
    request.addAll(resolvedMetadata);
  }
  if ((request['spotify_id']?.toString().trim().isEmpty ?? true) &&
      sourceTrackId != null) {
    request['spotify_id'] = sourceTrackId;
  }
  return request;
}

class ReEnrichMetadataChange {
  final String field;
  final String oldValue;
  final String newValue;

  const ReEnrichMetadataChange({
    required this.field,
    required this.oldValue,
    required this.newValue,
  });
}

/// The current value of a lyrics change when the song already has lyrics.
const reEnrichHasLyricsValue = '__has_lyrics__';

/// The change fields a review can list. Other keys of a preview's metadata,
/// such as `spotify_id`, go with every write.
const reEnrichReviewFields = {
  'track_name',
  'artist_name',
  'album_name',
  'album_artist',
  'track_number',
  'total_tracks',
  'disc_number',
  'total_discs',
  'release_date',
  'isrc',
  'genre',
  'composer',
  'label',
  'copyright',
  'cover_url',
  'header_video',
  'lyrics',
};

/// The backend update field that writes the change to [field], or null for
/// motion artwork, which is saved in app storage instead of the file.
String? reEnrichUpdateField(String field) => switch (field) {
  'cover_url' => ReEnrichFields.cover,
  'header_video' => null,
  _ => field,
};

/// A cover's size in pixels.
typedef ReEnrichCoverSize = ({int width, int height});

/// Whether [change] likely makes the song's metadata worse, so a review
/// starts with it switched off: a new cover with fewer pixels than the
/// current one ([currentCover] and [newCover], when both were measured), or
/// an empty value replacing one the song has.
bool reEnrichChangeIsDowngrade(
  ReEnrichMetadataChange change, {
  ReEnrichCoverSize? currentCover,
  ReEnrichCoverSize? newCover,
}) {
  if (change.field == 'cover_url') {
    return currentCover != null &&
        newCover != null &&
        newCover.width * newCover.height <
            currentCover.width * currentCover.height;
  }
  return change.newValue.trim().isEmpty && change.oldValue.trim().isNotEmpty;
}

class BatchReEnrichPreview {
  final LocalLibraryItem item;
  final List<String> updateFields;
  final Map<String, dynamic> enrichedMetadata;
  final List<ReEnrichMetadataChange> changes;

  /// How well the automatically chosen result fits, or the picked one.
  final ReEnrichMatch match;

  /// The results the song can be matched to by hand, best first.
  final List<Map<String, dynamic>> candidates;

  /// The result picked by hand, if any.
  final Map<String, dynamic>? chosen;

  const BatchReEnrichPreview({
    required this.item,
    required this.updateFields,
    required this.enrichedMetadata,
    required this.changes,
    this.match = ReEnrichMatch.exact,
    this.candidates = const [],
    this.chosen,
  });

  /// No result fitted well enough to apply on its own, but one could be
  /// picked by hand.
  bool get needsChoice =>
      chosen == null && match == ReEnrichMatch.none && candidates.isNotEmpty;

  /// [candidate] picked by hand, with what its preview would change.
  BatchReEnrichPreview withChoice(
    Map<String, dynamic> candidate,
    Map<String, dynamic> metadata,
  ) => BatchReEnrichPreview(
    item: item,
    updateFields: updateFields,
    enrichedMetadata: metadata,
    changes: buildReEnrichMetadataChanges(item, metadata, updateFields),
    match: reEnrichCandidateMatch(candidate),
    candidates: candidates,
    chosen: candidate,
  );

  /// This preview with only the changes to [fields]. Its write touches only
  /// those: every other value stays as the song has it, never the result's.
  /// Choosing nothing the file holds leaves [updateFields] empty, and such a
  /// preview must not be written, since the backend reads an empty list as
  /// every field.
  BatchReEnrichPreview selecting(Set<String> fields) {
    final kept = [
      for (final change in changes)
        if (fields.contains(change.field)) change,
    ];
    final keptFields = {for (final change in kept) change.field};
    return BatchReEnrichPreview(
      item: item,
      updateFields: {
        for (final change in kept) ?reEnrichUpdateField(change.field),
      }.toList(growable: false),
      enrichedMetadata: {
        for (final entry in enrichedMetadata.entries)
          if (!reEnrichReviewFields.contains(entry.key) ||
              keptFields.contains(entry.key))
            entry.key: entry.value,
      },
      changes: kept,
      match: match,
      candidates: candidates,
      chosen: chosen,
    );
  }
}

BatchReEnrichPreview? buildManualBatchReEnrichPreview(
  LocalLibraryItem item,
  ReEnrichFieldSelection selection,
) {
  if (!selection.usesManualValues) return null;

  final enrichedMetadata = <String, dynamic>{
    for (final entry in selection.manualValues.entries)
      if (manualBatchMetadataFields.contains(entry.key) &&
          entry.value.trim().isNotEmpty)
        entry.key: entry.value.trim(),
  };
  final updateFields = enrichedMetadata.keys.toList(growable: false);
  if (updateFields.isEmpty) return null;

  final changes = buildReEnrichMetadataChanges(
    item,
    enrichedMetadata,
    updateFields,
  );
  if (changes.isEmpty) return null;

  return BatchReEnrichPreview(
    item: item,
    updateFields: updateFields,
    enrichedMetadata: enrichedMetadata,
    changes: changes,
  );
}

String _displayValue(Object? value) {
  if (value == null) return '';
  if (value is num && value == 0) return '';
  return value.toString().trim();
}

List<ReEnrichMetadataChange> buildReEnrichMetadataChanges(
  LocalLibraryItem item,
  Map<String, dynamic> enrichedMetadata,
  List<String> updateFields,
) {
  final current = <String, Object?>{
    'track_name': item.trackName,
    'artist_name': item.artistName,
    'album_name': item.albumName,
    'album_artist': item.albumArtist,
    'track_number': item.trackNumber,
    'total_tracks': item.totalTracks,
    'disc_number': item.discNumber,
    'total_discs': item.totalDiscs,
    'release_date': item.releaseDate,
    'isrc': item.isrc,
    'genre': item.genre,
    'composer': item.composer,
    'label': item.label,
    'copyright': item.copyright,
    'cover_url': item.coverPath,
  };
  final changes = <ReEnrichMetadataChange>[];
  for (final field in current.keys) {
    if (!enrichedMetadata.containsKey(field)) continue;
    final oldValue = _displayValue(current[field]);
    final newValue = _displayValue(enrichedMetadata[field]);
    if (newValue.isEmpty || oldValue == newValue) continue;
    changes.add(
      ReEnrichMetadataChange(
        field: field,
        oldValue: oldValue,
        newValue: newValue,
      ),
    );
  }
  if (updateFields.contains(ReEnrichFields.cover) &&
      normalizeRemoteHttpUrl(enrichedMetadata['header_video']?.toString()) !=
          null) {
    changes.add(
      const ReEnrichMetadataChange(
        field: 'header_video',
        oldValue: '',
        newValue: '__refresh_online__',
      ),
    );
  }
  if (updateFields.contains(ReEnrichFields.lyrics) ||
      updateFields.contains('lyrics')) {
    changes.add(
      ReEnrichMetadataChange(
        field: 'lyrics',
        oldValue: item.hasLyrics ? reEnrichHasLyricsValue : '',
        newValue: '__refresh_online__',
      ),
    );
  }
  return changes;
}
