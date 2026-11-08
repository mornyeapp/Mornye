import 'package:mornye/services/playable_media.dart';

/// The key that makes two queue entries the same song: where it plays from,
/// not its id or tags. Ids differ for one file between the Library, the
/// download history and a plain path, while a FLAC and an MP3 copy of a
/// song share their tags and are both meant to be queued.
///
/// - A local path is compared as is; a `file://` URI counts as its path.
/// - A SAF `content://` URI is reduced to its provider and document id, so
///   the same document reached through a folder tree matches.
/// - `network://` sources (NAS, Subsonic, a paired device) and CUE tracks
///   already name one song each and are compared as is.
/// - Stream URLs are compared as is; a URL carrying a fresh token never
///   matches, which keeps a copy rather than merging two different songs.
String queueIdentityKey(PlayableMedia media) {
  final source = media.source.trim();
  if (source.startsWith('file://')) {
    final uri = Uri.tryParse(source);
    if (uri != null) {
      try {
        return uri.toFilePath();
      } on UnsupportedError {
        return source;
      }
    }
  }
  if (source.startsWith('content://')) {
    final uri = Uri.tryParse(source);
    if (uri != null) {
      final document = uri.pathSegments.lastIndexOf('document');
      if (document >= 0 && document + 1 < uri.pathSegments.length) {
        return 'content://${uri.authority}/document/'
            '${Uri.encodeComponent(uri.pathSegments[document + 1])}';
      }
    }
  }
  return source;
}

/// What adding [incoming] to a queue without duplicates changes: the songs
/// to insert, each once and in their order, and the indexes of upcoming
/// entries (after [current]) they replace, highest first. The song at
/// [current] and the ones before it are never touched, so a song playing
/// or already played is queued again.
({List<PlayableMedia> insert, List<int> remove}) planQueueWithoutDuplicates({
  required List<PlayableMedia> queue,
  required int current,
  required List<PlayableMedia> incoming,
}) {
  final keys = <String>{};
  final insert = [
    for (final media in incoming)
      if (keys.add(queueIdentityKey(media))) media,
  ];
  final remove = [
    for (var i = queue.length - 1; i > current && i >= 0; i--)
      if (keys.contains(queueIdentityKey(queue[i]))) i,
  ];
  return (insert: insert, remove: remove);
}
