part of 'network_storage_service.dart';

class SubsonicException implements Exception {
  const SubsonicException(this.code);
  final int code;

  @override
  String toString() => 'Subsonic server error $code';
}

String _subsonicId(String id) =>
    base64Url.encode(utf8.encode(id)).replaceAll('=', '');

String _decodeSubsonicId(String encoded) {
  if (encoded.isEmpty ||
      encoded.length > 8192 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
    throw const FormatException('Invalid Subsonic identifier');
  }
  return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
}

/// The library path of the Subsonic song [id]: `subsonic/song/<id>.<format>`.
String subsonicSongPath(String id, String format) =>
    'subsonic/song/${_subsonicId(id)}.$format';

/// The library path of the Subsonic cover art [id]:
/// `subsonic/cover/<id>.image`.
String subsonicCoverPath(String id) =>
    'subsonic/cover/${_subsonicId(id)}.image';

/// The Subsonic song id behind a [subsonicSongPath], or null for any other
/// path.
String? subsonicSongIdFromPath(String path) {
  final segments = path.split('/');
  if (segments.length != 3 ||
      segments.first != 'subsonic' ||
      segments[1] != 'song') {
    return null;
  }
  try {
    return _decodeSubsonicId(segments.last.split('.').first);
  } on FormatException {
    return null;
  }
}

Uri _subsonicTarget(
  NetworkConnection connection,
  String method,
  Map<String, String> arguments,
) {
  final root = connection.root;
  final path = root.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (path.lastOrNull != 'rest') path.add('rest');
  path.add('$method.view');
  final parameters = <String, String>{
    'v': '1.16.1',
    'c': 'Mornye',
    'f': 'json',
    ...arguments,
  };
  switch (connection.subsonicAuth) {
    case SubsonicAuth.apiKey:
      if (connection.apiKey.isEmpty) throw const SubsonicException(40);
      parameters['apiKey'] = connection.apiKey;
    case SubsonicAuth.saltedToken:
      final salt = NetworkStorageService.newId();
      parameters.addAll({
        'u': connection.username,
        's': salt,
        't': md5.convert(utf8.encode('${connection.password}$salt')).toString(),
      });
    case SubsonicAuth.password:
      parameters.addAll({
        'u': connection.username,
        'p':
            'enc:${utf8.encode(connection.password).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}',
      });
  }
  return Uri(
    scheme: root.scheme,
    host: root.host,
    port: root.hasPort ? root.port : null,
    pathSegments: ['', ...path],
    queryParameters: parameters,
  );
}

Uri _subsonicMediaTarget(NetworkConnection connection, String path) {
  final segments = networkPath(path).split('/');
  if (segments.length != 3 || segments.first != 'subsonic') {
    throw const FormatException('Invalid Subsonic media path');
  }
  final encoded = segments.last.split('.').first;
  final id = _decodeSubsonicId(encoded);
  return switch (segments[1]) {
    'song' => _subsonicTarget(connection, 'stream', {
      'id': id,
      'format': 'raw',
    }),
    'cover' => _subsonicTarget(connection, 'getCoverArt', {'id': id}),
    _ => throw const FormatException('Invalid Subsonic media path'),
  };
}

Map<String, dynamic> _subsonicMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const HttpException('Invalid Subsonic response');
  }
  return value;
}

Map<String, dynamic> _decodeSubsonicResponse(Uint8List bytes) => _subsonicMap(
  _subsonicMap(jsonDecode(utf8.decode(bytes)))['subsonic-response'],
);

List<Map<String, dynamic>> _subsonicList(Object? value) {
  if (value == null) return [];
  if (value is! List) throw const HttpException('Invalid Subsonic response');
  return value.map(_subsonicMap).toList();
}

String _subsonicText(Map<String, dynamic> value, String key) =>
    value[key] is String ? value[key] as String : '';

class SubsonicSong {
  SubsonicSong(Map<String, dynamic> data) : data = Map.unmodifiable(data) {
    if (id.isEmpty || id.length > 4096 || data['isDir'] == true) {
      throw const HttpException('Invalid Subsonic song');
    }
  }

  final Map<String, dynamic> data;
  String get id => _subsonicText(data, 'id');
  String get title => _subsonicText(data, 'title');
  String get artist => _subsonicText(data, 'displayArtist').isNotEmpty
      ? _subsonicText(data, 'displayArtist')
      : _subsonicText(data, 'artist');
  String get album => _subsonicText(data, 'album');
  String get coverId => _subsonicText(data, 'coverArt');
  String get format {
    final suffix = _subsonicText(data, 'suffix').toLowerCase();
    if (RegExp(r'^[a-z0-9]{1,10}$').hasMatch(suffix)) return suffix;
    return switch (_subsonicText(data, 'contentType').toLowerCase()) {
      'audio/flac' || 'audio/x-flac' => 'flac',
      'audio/mp4' || 'audio/x-m4a' => 'm4a',
      'audio/ogg' || 'application/ogg' => 'ogg',
      'audio/opus' => 'opus',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => 'mp3',
    };
  }

  String get path => subsonicSongPath(id, format);
  String? get coverPath => coverId.isEmpty ? null : subsonicCoverPath(coverId);
  NetworkEntry get entry => NetworkEntry(
    path,
    '$title.$format',
    song: this,
    size: (data['size'] as num?)?.toInt(),
  );

  late final Map<String, dynamic> metadata = Map.unmodifiable(_metadata());

  Map<String, dynamic> _metadata() {
    final replayGain = data['replayGain'] is Map
        ? _subsonicMap(data['replayGain'])
        : const <String, dynamic>{};
    final isrc = data['isrc'];
    return {
      'title': title,
      'artist': artist,
      'album': album,
      'album_artist': _subsonicText(data, 'displayAlbumArtist'),
      'audio_codec': format,
      'format': format,
      'genre': _subsonicText(data, 'genre'),
      'explicit': data['explicitStatus'] == 'explicit',
      if (isrc is List && isrc.isNotEmpty) 'isrc': isrc.first.toString(),
      if (isrc is String) 'isrc': isrc,
      if (data['year'] != null) 'date': data['year'].toString(),
      for (final field in const {
        'duration': 'duration',
        'track': 'track_number',
        'discNumber': 'disc_number',
        'bitRate': 'bitrate',
        'samplingRate': 'sample_rate',
        'bitDepth': 'bit_depth',
        'bpm': 'bpm',
      }.entries)
        if (data[field.key] is num)
          field.value: (data[field.key] as num).toInt(),
      if (data['moods'] is List) 'mood': (data['moods'] as List).join('; '),
      for (final field in const {
        'trackGain': 'replaygain_track_gain',
        'albumGain': 'replaygain_album_gain',
      }.entries)
        if (replayGain[field.key] is num)
          field.value: '${replayGain[field.key]} dB',
      for (final field in const {
        'trackPeak': 'replaygain_track_peak',
        'albumPeak': 'replaygain_album_peak',
      }.entries)
        if (replayGain[field.key] is num)
          field.value: replayGain[field.key].toString(),
    };
  }
}

extension SubsonicStorage on NetworkStorageService {
  SubsonicClient openSubsonic(NetworkConnection connection) {
    connection.validate();
    if (connection.protocol != NetworkProtocol.subsonic) {
      throw const FormatException('Expected a Subsonic connection');
    }
    return SubsonicClient._(this, connection, _client());
  }

  Future<List<NetworkEntry>> searchSubsonic(
    NetworkConnection connection,
    String query,
  ) async {
    final client = openSubsonic(connection);
    try {
      return await client.search(query);
    } finally {
      client.close();
    }
  }
}

class SubsonicClient {
  SubsonicClient._(this._storage, this.connection, this._http);
  final NetworkStorageService _storage;
  final NetworkConnection connection;
  final HttpClient _http;
  bool _closed = false;

  void close() {
    _closed = true;
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, String> arguments = const {},
  ]) => _protectTransport(() => _requestJson(method, arguments));

  Future<T> _protectTransport<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on HttpException catch (error) {
      // HttpClient exceptions can carry the credential-bearing request URI.
      throw HttpException(
        RegExp(r'^Server returned \d{3}$').hasMatch(error.message)
            ? error.message
            : 'Subsonic request failed',
      );
    }
  }

  Future<Map<String, dynamic>> _requestJson(
    String method, [
    Map<String, String> arguments = const {},
  ]) async {
    if (_closed) throw StateError('Subsonic request cancelled');
    final response = await _storage._request(
      _http,
      connection,
      'GET',
      _subsonicTarget(connection, method, arguments),
    );
    if (response.statusCode != 200) {
      await _storage._discardResponse(response);
      throw HttpException('Server returned ${response.statusCode}');
    }
    final bytes = BytesBuilder();
    await for (final chunk in response.timeout(NetworkStorageService.timeout)) {
      if (_closed) throw StateError('Subsonic request cancelled');
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw const HttpException('Subsonic response is too large');
      }
      bytes.add(chunk);
    }
    final Map<String, dynamic> result;
    try {
      result = bytes.length > 64 * 1024
          ? await compute(_decodeSubsonicResponse, bytes.takeBytes())
          : _decodeSubsonicResponse(bytes.takeBytes());
    } on FormatException {
      throw const HttpException('Invalid Subsonic response');
    }
    if (result['status'] == 'failed') {
      final code = _subsonicMap(result['error'])['code'];
      throw SubsonicException(code is num ? code.toInt() : 0);
    }
    if (result['status'] != 'ok') {
      throw const HttpException('Invalid Subsonic response');
    }
    return result;
  }

  NetworkEntry _artist(Map<String, dynamic> value) => NetworkEntry(
    'subsonic/artist/${_subsonicId(_subsonicText(value, 'id'))}/',
    _subsonicText(value, 'name'),
    directory: true,
  );
  NetworkEntry _album(Map<String, dynamic> value) => NetworkEntry(
    'subsonic/album/${_subsonicId(_subsonicText(value, 'id'))}/',
    _subsonicText(value, 'name').isNotEmpty
        ? _subsonicText(value, 'name')
        : _subsonicText(value, 'title'),
    directory: true,
  );

  Future<List<NetworkEntry>> list(String path) async {
    networkPath(path);
    if (path.isEmpty) {
      await request('ping');
      return const [
        NetworkEntry('subsonic/artists/', 'Artists', directory: true),
        NetworkEntry('subsonic/albums/', 'Albums', directory: true),
      ];
    }
    if (path == 'subsonic/artists/') {
      final artists = _subsonicMap((await request('getArtists'))['artists']);
      return NetworkStorageService._sorted([
        for (final index in _subsonicList(artists['index']))
          for (final artist in _subsonicList(index['artist'])) _artist(artist),
      ]);
    }
    final segments = path.split('/');
    if (path == 'subsonic/albums/' ||
        (segments.length == 4 &&
            segments.first == 'subsonic' &&
            segments[1] == 'albums' &&
            segments.last.isEmpty)) {
      final offset = path == 'subsonic/albums/' ? 0 : int.tryParse(segments[2]);
      if (offset == null || offset < 0 || offset > 1000000) {
        throw const FormatException('Invalid album page');
      }
      final albums = await _albums(offset);
      return [
        ...albums.map(_album),
        if (albums.length == 200)
          NetworkEntry(
            'subsonic/albums/${offset + 200}/',
            'More albums',
            directory: true,
          ),
      ];
    }
    if (segments.length != 4 ||
        segments.first != 'subsonic' ||
        segments.last.isNotEmpty) {
      throw const FormatException('Invalid Subsonic folder');
    }
    final id = _decodeSubsonicId(segments[2]);
    if (segments[1] == 'artist') {
      final artist = _subsonicMap(
        (await request('getArtist', {'id': id}))['artist'],
      );
      return _subsonicList(artist['album']).map(_album).toList();
    }
    if (segments[1] == 'album') {
      return (await _songs(id)).map((song) => song.entry).toList();
    }
    throw const FormatException('Invalid Subsonic folder');
  }

  Future<List<Map<String, dynamic>>> _albums(int offset) async => _subsonicList(
    _subsonicMap(
      (await request('getAlbumList2', {
        'type': 'alphabeticalByName',
        'size': '200',
        'offset': '$offset',
      }))['albumList2'],
    )['album'],
  );

  Future<List<SubsonicSong>> _songs(String albumId) async => _subsonicList(
    _subsonicMap((await request('getAlbum', {'id': albumId}))['album'])['song'],
  ).where((song) => song['isVideo'] != true).map(SubsonicSong.new).toList();

  Future<List<NetworkEntry>> search(String query) async {
    final result = _subsonicMap(
      (await request('search3', {
        'query': query.trim(),
        'artistCount': '30',
        'albumCount': '50',
        'songCount': '200',
      }))['searchResult3'],
    );
    return [
      ..._subsonicList(result['artist']).map(_artist),
      ..._subsonicList(result['album']).map(_album),
      ..._subsonicList(result['song'])
          .where((song) => song['isVideo'] != true)
          .map((song) => SubsonicSong(song).entry),
    ];
  }

  Future<SubsonicSong> song(String path) async {
    _subsonicMediaTarget(connection, path);
    if (!path.startsWith('subsonic/song/')) {
      throw const FormatException('Expected a Subsonic song');
    }
    final id = _decodeSubsonicId(path.split('/').last.split('.').first);
    return SubsonicSong(
      _subsonicMap((await request('getSong', {'id': id}))['song']),
    );
  }

  /// The lyrics of [song] from the OpenSubsonic songLyrics extension, as
  /// LRC or plain text; empty when the server has none. A Mornye desktop
  /// also sends the stored text (`mornyeRaw`), which keeps word timing.
  /// Throws when the server lacks the extension.
  Future<String> lyrics(SubsonicSong song) async {
    final result = await request('getLyricsBySongId', {'id': song.id});
    final entries = _subsonicList(
      _subsonicMap(result['lyricsList'])['structuredLyrics'],
    );
    for (final entry in entries) {
      if (entry['mornyeRaw'] case final String raw when raw.trim().isNotEmpty) {
        return raw;
      }
    }
    final main = entries.where((entry) => (entry['kind'] ?? 'main') == 'main');
    final entry =
        main.where((entry) => entry['synced'] == true).firstOrNull ??
        main.firstOrNull;
    if (entry == null) return '';
    final lines = _subsonicList(entry['line']);
    if (entry['synced'] != true) {
      return lines.map((line) => _subsonicText(line, 'value')).join('\n');
    }
    // A positive offset shows the lines sooner.
    final offset = (entry['offset'] as num?)?.toInt() ?? 0;
    return [
      for (final line in lines)
        if (line['start'] case final num start)
          '[${_lrcTime(start.toInt() - offset)}]${_subsonicText(line, 'value')}',
    ].join('\n');
  }

  static String _lrcTime(int milliseconds) {
    final time = milliseconds < 0 ? 0 : milliseconds;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time ~/ 60000)}:${two(time ~/ 1000 % 60)}.${two(time % 1000 ~/ 10)}';
  }

  Stream<SubsonicSong> catalog({
    required Future<void> Function() checkpoint,
  }) async* {
    final albums = <String>{};
    final songs = <String>{};
    for (var offset = 0; offset <= 1000000; offset += 200) {
      await checkpoint();
      final page = await _albums(offset);
      await checkpoint();
      var newAlbums = 0;
      for (final album in page) {
        await checkpoint();
        final id = _subsonicText(album, 'id');
        if (id.isEmpty) throw const HttpException('Invalid Subsonic album');
        if (!albums.add(id)) continue;
        newAlbums++;
        for (final song in await _songs(id)) {
          await checkpoint();
          if (songs.add(song.id)) yield song;
          if (songs.length > 500000) {
            throw const HttpException('Subsonic library is too large');
          }
        }
      }
      if (page.length < 200) return;
      if (newAlbums == 0) {
        throw const HttpException('Subsonic pagination did not advance');
      }
    }
    throw const HttpException('Subsonic library is too large');
  }

  Future<String?> cachedCover(
    SubsonicSong song,
    Directory directory, {
    bool refresh = false,
  }) async {
    if (song.coverId.isEmpty) return null;
    await directory.create(recursive: true);
    final hash = sha256.convert(
      utf8.encode('${connection.id}/${song.coverId}'),
    );
    final base = File('${directory.path}/subsonic_$hash.image');
    final current = File('${base.path}.current');
    var target = base;
    try {
      final name = await current.readAsString();
      final prefix = 'subsonic_${hash}_';
      if (name.startsWith(prefix) &&
          name.endsWith('.image') &&
          RegExp(
            r'^[a-f0-9]{48}$',
          ).hasMatch(name.substring(prefix.length, name.length - 6))) {
        target = File('${directory.path}/$name');
      }
    } on FileSystemException {
      // Older caches have only the original image path.
    }
    final stat = await target.stat();
    if (!refresh &&
        stat.type == FileSystemEntityType.file &&
        stat.size > 0 &&
        DateTime.now().difference(stat.modified) < const Duration(days: 1)) {
      return target.path;
    }
    final staged = File('${base.path}.${NetworkStorageService.newId()}.tmp');
    File? pointer;
    try {
      await saveCover(song, staged);
      if (refresh || target.path != base.path) {
        // A new path invalidates every decoded size of the old artwork.
        // Existing Library rows keep their old image until the scan commits.
        final name = 'subsonic_${hash}_${NetworkStorageService.newId()}.image';
        target = File('${directory.path}/$name');
        await staged.rename(target.path);
        pointer = File('${current.path}.${NetworkStorageService.newId()}.tmp');
        await pointer.writeAsString(name, flush: true);
        await pointer.rename(current.path);
      } else {
        await staged.rename(target.path);
      }
      return target.path;
    } finally {
      if (await staged.exists()) await staged.delete();
      if (pointer != null && await pointer.exists()) await pointer.delete();
    }
  }

  /// Saves the original file of the song [id] (the `download` method) to
  /// [output]. [progress] receives the bytes written and the size the server
  /// announced; [checkpoint] may throw between chunks to cancel.
  Future<void> download(
    String id,
    File output, {
    void Function()? checkpoint,
    void Function(int received, int? total)? progress,
  }) => _protectTransport(
    () => _download(id, output, checkpoint: checkpoint, progress: progress),
  );

  Future<void> _download(
    String id,
    File output, {
    void Function()? checkpoint,
    void Function(int received, int? total)? progress,
  }) async {
    if (_closed) throw StateError('Subsonic request cancelled');
    final response = await _storage._request(
      _http,
      connection,
      'GET',
      _subsonicTarget(connection, 'download', {'id': id}),
    );
    if (response.statusCode != 200 ||
        const {
          'application/json',
          'application/xml',
          'text/xml',
        }.contains(response.headers.contentType?.mimeType)) {
      await _storage._discardResponse(response);
      throw HttpException(
        response.statusCode == 200
            ? 'Subsonic media unavailable'
            : 'Server returned ${response.statusCode}',
      );
    }
    final total = response.contentLength >= 0 ? response.contentLength : null;
    final writer = output.openWrite();
    var received = 0;
    try {
      // Let file writes pause the HTTP stream instead of queueing the entire
      // download in the sink when storage is slower than the connection.
      await writer.addStream(
        response.timeout(NetworkStorageService.timeout).map((chunk) {
          if (_closed) throw StateError('Subsonic request cancelled');
          checkpoint?.call();
          received += chunk.length;
          progress?.call(received, total);
          return chunk;
        }),
      );
      if (total != null && received != total) {
        throw const HttpException('Subsonic download ended early');
      }
    } finally {
      await writer.close();
    }
  }

  Future<void> saveCover(SubsonicSong song, File output) =>
      _protectTransport(() => _saveCover(song, output));

  Future<void> _saveCover(SubsonicSong song, File output) async {
    if (song.coverPath == null) return;
    final response = await _storage._request(
      _http,
      connection,
      'GET',
      _subsonicMediaTarget(connection, song.coverPath!),
    );
    if (response.statusCode != 200 ||
        !(response.headers.contentType?.mimeType.startsWith('image/') ??
            false)) {
      await _storage._discardResponse(response);
      throw const HttpException('Subsonic artwork unavailable');
    }
    final writer = output.openWrite();
    var size = 0;
    try {
      await for (final chunk in response.timeout(
        NetworkStorageService.timeout,
      )) {
        size += chunk.length;
        if (size > 16 * 1024 * 1024) {
          throw const HttpException('Subsonic artwork is too large');
        }
        writer.add(chunk);
        await writer.flush();
      }
      if (size == 0) throw const HttpException('Subsonic artwork is empty');
    } finally {
      await writer.close();
    }
  }
}
