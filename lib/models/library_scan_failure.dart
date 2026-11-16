/// A file a Library scan could not read, with the reason the reader gave.
class LibraryScanFailure {
  const LibraryScanFailure({required this.path, required this.message});

  /// A file path, or a SAF document URI on Android.
  final String path;
  final String message;

  factory LibraryScanFailure.fromJson(Map<String, dynamic> json) =>
      LibraryScanFailure(
        path: json['path'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'path': path, 'message': message};

  /// The path as a person would write it. A document URI ends in an encoded
  /// document ID such as `primary:Music/Album/Song.flac`; the volume before
  /// the colon is dropped.
  String get _readablePath {
    var value = path;
    if (value.startsWith('content://')) {
      try {
        final segments = Uri.parse(value).pathSegments;
        if (segments.isNotEmpty) value = segments.last;
      } on FormatException {
        // A malformed URI still ends in the document name.
      }
      final volume = value.indexOf(':');
      if (volume >= 0) value = value.substring(volume + 1);
    }
    return value.replaceAll('\\', '/');
  }

  String get fileName {
    final value = _readablePath;
    final name = value.substring(value.lastIndexOf('/') + 1);
    return name.isEmpty ? path : name;
  }

  /// The folder of the file, empty when it sits at the top of the source.
  String get folder {
    final value = _readablePath;
    final end = value.lastIndexOf('/');
    return end <= 0 ? '' : value.substring(0, end);
  }
}

/// What the last scan of one Library source could not read. [files] lists at
/// most the first hundred; [count] includes the rest.
class LibraryScanFailures {
  const LibraryScanFailures({required this.count, required this.files});

  final int count;
  final List<LibraryScanFailure> files;

  factory LibraryScanFailures.fromProgress(Map<String, dynamic> progress) =>
      LibraryScanFailures(
        count: (progress['error_count'] as num?)?.toInt() ?? 0,
        files: _files(progress['failures']),
      );

  factory LibraryScanFailures.fromJson(Map<String, dynamic> json) =>
      LibraryScanFailures(
        count: (json['count'] as num?)?.toInt() ?? 0,
        files: _files(json['files']),
      );

  Map<String, dynamic> toJson() => {
    'count': count,
    'files': [for (final file in files) file.toJson()],
  };

  static List<LibraryScanFailure> _files(Object? value) => [
    if (value is List)
      for (final entry in value)
        if (entry is Map) LibraryScanFailure.fromJson(entry.cast()),
  ];
}
