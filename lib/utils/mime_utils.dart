String audioMimeTypeForPath(String filePath) {
  final dotIndex = filePath.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == filePath.length - 1) {
    return 'audio/*';
  }

  final ext = filePath.substring(dotIndex + 1).toLowerCase();
  return switch (ext) {
    'flac' => 'audio/flac',
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'ogg' => 'audio/ogg',
    'wav' => 'audio/wav',
    'aiff' || 'aif' || 'aifc' => 'audio/aiff',
    'aac' => 'audio/aac',
    _ => 'audio/*',
  };
}
