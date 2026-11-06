import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = AppLogger('ArtistSnapshots');

/// An artist page as last loaded, so it can open without a connection.
class ArtistSnapshot {
  const ArtistSnapshot({
    required this.artistId,
    required this.artistName,
    required this.albums,
    this.extensionId,
    this.coverUrl,
    this.releases,
    this.topTracks,
    this.headerImageUrl,
    this.headerLogoUrl,
    this.monthlyListeners,
  });

  factory ArtistSnapshot.fromJson(Map<String, dynamic> json) {
    List<ArtistAlbum>? albums(String key) => (json[key] as List?)
        ?.map((album) => ArtistAlbum.fromJson(album as Map<String, dynamic>))
        .toList();
    return ArtistSnapshot(
      artistId: json['artistId'] as String,
      artistName: json['artistName'] as String,
      extensionId: json['extensionId'] as String?,
      coverUrl: json['coverUrl'] as String?,
      albums: albums('albums') ?? const [],
      releases: albums('releases'),
      topTracks: (json['topTracks'] as List?)
          ?.map((track) => Track.fromJson(track as Map<String, dynamic>))
          .toList(),
      headerImageUrl: json['headerImageUrl'] as String?,
      headerLogoUrl: json['headerLogoUrl'] as String?,
      monthlyListeners: json['monthlyListeners'] as int?,
    );
  }

  final String artistId;
  final String artistName;
  final String? extensionId;
  final String? coverUrl;
  final List<ArtistAlbum> albums;
  final List<ArtistAlbum>? releases;
  final List<Track>? topTracks;
  final String? headerImageUrl;
  final String? headerLogoUrl;
  final int? monthlyListeners;

  Map<String, dynamic> toJson() => {
    'artistId': artistId,
    'artistName': artistName,
    'extensionId': extensionId,
    'coverUrl': coverUrl,
    'albums': [for (final album in albums) album.toJson()],
    'releases': releases == null
        ? null
        : [for (final album in releases!) album.toJson()],
    'topTracks': topTracks == null
        ? null
        : [for (final track in topTracks!) track.toJson()],
    'headerImageUrl': headerImageUrl,
    'headerLogoUrl': headerLogoUrl,
    'monthlyListeners': monthlyListeners,
  };
}

/// One file per artist name, since Library rows know an artist only by name.
/// The artists saved longest ago leave first once [maxArtists] are kept.
class ArtistSnapshotStore {
  ArtistSnapshotStore({
    Future<Directory> Function()? directory,
    this.maxArtists = 200,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  static final instance = ArtistSnapshotStore();

  final Future<Directory> Function() _directory;
  final int maxArtists;

  Future<Directory> get _root async =>
      Directory('${(await _directory()).path}/artist_snapshots');

  Future<File> _file(String artistName) async {
    final name = artistName.trim().toLowerCase();
    final digest = sha1.convert(utf8.encode(name));
    return File('${(await _root).path}/$digest.json');
  }

  Future<void> save(ArtistSnapshot snapshot) async {
    try {
      final file = await _file(snapshot.artistName);
      await file.parent.create(recursive: true);
      final draft = File('${file.path}.tmp');
      await draft.writeAsString(jsonEncode(snapshot.toJson()));
      await draft.rename(file.path);
      await _prune(file.parent);
    } catch (error) {
      _log.w('Could not save an artist page: ${error.runtimeType}');
    }
  }

  Future<ArtistSnapshot?> read(String artistName) async {
    try {
      final file = await _file(artistName);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      return ArtistSnapshot.fromJson(json as Map<String, dynamic>);
    } catch (error) {
      _log.w('Ignoring a saved artist page: ${error.runtimeType}');
      return null;
    }
  }

  Future<void> _prune(Directory root) async {
    final files = await root.list().where((entry) => entry is File).toList();
    if (files.length <= maxArtists) return;
    final saved = <(DateTime, FileSystemEntity)>[
      for (final file in files) ((await file.stat()).modified, file),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, file) in saved.take(files.length - maxArtists)) {
      await file.delete();
    }
  }
}
