import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/listening_statistics.dart';

/// A fresh directory removed after the test.
Future<Directory> linkSyncTempDirectory() async {
  final directory = await Directory.systemTemp.createTemp('link-sync-test-');
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

/// A collections database with the app schema, opened through FFI.
Future<Database> openLinkCollectionsDatabase(
  Directory directory,
  String name,
) async {
  sqfliteFfiInit();
  final db = await LibraryCollectionsDatabase.openWithFactory(
    databaseFactoryFfi,
    '${directory.path}/$name.db',
  );
  addTearDown(db.close);
  return db;
}

/// A listening statistics database with the app schema, opened through FFI.
Future<Database> openLinkListeningDatabase(
  Directory directory,
  String name,
) async {
  sqfliteFfiInit();
  final db = await ListeningStatisticsStore.openWithFactory(
    databaseFactoryFfi,
    '${directory.path}/$name-listening.db',
  );
  addTearDown(db.close);
  return db;
}

Track linkTestTrack(String id, {String? isrc, String artist = 'Artist'}) =>
    Track(
      id: id,
      name: 'Song $id',
      artistName: artist,
      albumName: 'Album',
      isrc: isrc,
      duration: 200,
      source: 'example',
    );

String linkTestTrackJson(String id) => jsonEncode(linkTestTrack(id).toJson());

/// A catalog index that matches tracks by ISRC, then by title and artist.
class FakeLinkCatalogIndex implements LinkCatalogIndex {
  FakeLinkCatalogIndex(List<LinkCatalogSong> songs)
    : _songs = {for (final song in songs) song.id: song};

  final Map<String, LinkCatalogSong> _songs;

  @override
  int get length => _songs.length;

  @override
  LinkCatalogSong? songById(String id) => _songs[id];

  @override
  String? songIdForRef(TrackRef ref) {
    for (final song in _songs.values) {
      if (ref.isrc != null && song.isrc == ref.isrc) return song.id;
      if (song.title == ref.title && song.artist == ref.artist) return song.id;
    }
    return null;
  }

  @override
  String? songIdForTrack(Track track) => songIdForRef(
    TrackRef(title: track.name, artist: track.artistName, isrc: track.isrc),
  );
}

/// The forwarded `SongInfo` of a catalog song.
Map<String, dynamic> linkSongInfo(LinkCatalogSong song) => {
  'id': song.id,
  'title': song.title,
  'artist': song.artist,
  'album': song.album,
  'albumArtist': song.albumArtist,
  'durationMs': song.durationMs,
  'isrc': song.isrc,
  'matchKey': song.matchKey,
  'path': song.path,
};

LinkCatalogSong linkCatalogSong(String id, String title, {String? isrc}) =>
    LinkCatalogSong(
      id: id,
      title: title,
      artist: 'Desk Artist',
      album: 'Desk Album',
      path: '/music/$title.flac',
      durationMs: 180000,
      isrc: isrc,
    );

/// Simulates the wire: JSON in and out.
Object? linkJsonRoundTrip(Object? value) => jsonDecode(jsonEncode(value));
