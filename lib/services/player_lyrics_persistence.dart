import 'package:path/path.dart' as p;
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/utils/artist_utils.dart';

/// Writes to the owning source, never to a resolved playback cache or stream.
Future<void> persistPlayerLyrics(String source, String lyrics) async {
  final uri = Uri.tryParse(source);
  final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : source;
  if (!source.startsWith('content://') &&
      !source.startsWith('network://') &&
      !p.posix.isAbsolute(localPath) &&
      !p.windows.isAbsolute(localPath)) {
    throw UnsupportedError('The playing source is not an editable audio file');
  }
  final covers = MetadataCoverResources();
  try {
    final result = await MetadataPersistenceService(covers: covers).save(
      MetadataSaveRequest(
        filePath: localPath,
        metadata: {'lyrics': lyrics},
        artistTagMode: artistTagModeJoined,
        preserveUnspecifiedTags: true,
      ),
    );
    if (result.failure != null) {
      throw result.error ?? StateError('Could not embed the fetched lyrics');
    }
  } finally {
    await covers.dispose();
  }
}
