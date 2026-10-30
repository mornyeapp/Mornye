import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mornye/services/network_storage_service.dart';

class SubsonicFixture {
  SubsonicFixture._(this.server, this.secure) {
    server.listen(_handle, onError: (Object _) {});
  }

  static Future<SubsonicFixture> start({SecurityContext? context}) async =>
      SubsonicFixture._(
        context == null
            ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
            : await HttpServer.bindSecure(
                InternetAddress.loopbackIPv4,
                0,
                context,
              ),
        context != null,
      );

  final HttpServer server;
  final bool secure;
  final requests = <Uri>[];
  final methods = <String>[];
  final authorizations = <String?>[];
  final ranges = <String?>[];
  final salts = <String>[];
  final held = Completer<void>();
  final release = Completer<void>();
  String? blockMethod;
  int? errorCode;
  String? failMethod;
  String? failAlbum;
  bool mediaError = false;
  bool disconnect = false;
  int albumCount = 1;
  bool repeatPage = false;
  String? redirect;
  List<int>? audio;
  List<int>? cover;

  /// The `lyricsList` answered by getLyricsBySongId; without one the server
  /// lacks the songLyrics extension.
  Map<String, dynamic>? lyricsList;
  final song = <String, dynamic>{
    'id': 'song / 日本語?&',
    'title': 'A song',
    'artist': 'An artist',
    'album': 'An album',
    'displayAlbumArtist': 'Album artist',
    'suffix': 'flac',
    'contentType': 'audio/flac',
    'duration': 243,
    'size': 100,
    'coverArt': 'cover /?&',
    'bitDepth': 24,
    'samplingRate': 96000,
    'bitRate': 1600,
    'bpm': 120,
    'moods': ['Calm'],
    'replayGain': {'trackGain': -4.2, 'albumGain': -3.5},
    'isrc': ['XXABC2600001'],
  };

  NetworkConnection connection({
    SubsonicAuth auth = SubsonicAuth.saltedToken,
    String? fingerprint,
    String path = '/music-server/',
  }) => NetworkConnection(
    id: 'fixture',
    name: 'Music server',
    protocol: NetworkProtocol.subsonic,
    address: '${secure ? 'https' : 'http'}://127.0.0.1:${server.port}$path',
    subsonicAuth: auth,
    username: 'listener',
    password: 'private-秘密',
    apiKey: 'private-api-key',
    trustedCertificateSha256: fingerprint,
  );

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri);
    methods.add(request.method);
    authorizations.add(request.headers.value('authorization'));
    ranges.add(request.headers.value('range'));
    final salt = request.uri.queryParameters['s'];
    if (salt != null) salts.add(salt);
    final method = request.uri.pathSegments.last.replaceFirst('.view', '');
    if (blockMethod == method) {
      if (!held.isCompleted) held.complete();
      await release.future;
    }
    final response = request.response;
    try {
      if (disconnect) {
        (await response.detachSocket()).destroy();
        return;
      }
      if (redirect != null) {
        response.statusCode = 302;
        response.headers.set('location', redirect!);
      } else if (errorCode != null &&
          (failMethod == null || failMethod == method) &&
          (failAlbum == null ||
              request.uri.queryParameters['id'] == failAlbum)) {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'subsonic-response': {
              'status': 'failed',
              'error': {
                'code': errorCode,
                'message': 'private-api-key private-秘密',
              },
            },
          }),
        );
      } else if ((method == 'stream' ||
              method == 'download' ||
              method == 'getCoverArt') &&
          !mediaError) {
        final isAudio = method != 'getCoverArt';
        response.headers.contentType = ContentType.parse(
          isAudio ? song['contentType'] as String : 'image/png',
        );
        final range = request.headers.value('range');
        response.statusCode = range == null ? 200 : 206;
        final media = (isAudio ? audio : cover) ?? [0, 1, 2, 3];
        final part = networkByteRange(range, media.length);
        if (range != null) {
          response.headers.set(
            'content-range',
            'bytes ${part.start}-${part.end}/${media.length}',
          );
        }
        response.headers.set('accept-ranges', 'bytes');
        final bytes = media.sublist(part.start, part.end + 1);
        response.contentLength = bytes.length;
        response.add(bytes);
      } else {
        final payload = switch (method) {
          'ping' => <String, dynamic>{},
          'getArtists' => {
            'artists': {
              'index': [
                {
                  'artist': [
                    {'id': 'artist/1', 'name': 'An artist'},
                  ],
                },
              ],
            },
          },
          'getArtist' => {
            'artist': {
              'album': [
                {'id': 'album/1', 'name': 'An album'},
              ],
            },
          },
          'getAlbumList2' => {
            'albumList2': {
              'album': [
                for (
                  var i = repeatPage
                      ? 0
                      : int.parse(request.uri.queryParameters['offset']!);
                  i < albumCount &&
                      i <
                          (repeatPage
                                  ? 0
                                  : int.parse(
                                      request.uri.queryParameters['offset']!,
                                    )) +
                              200;
                  i++
                )
                  {'id': 'album/$i', 'name': 'Album $i'},
              ],
            },
          },
          'getAlbum' => {
            'album': {
              'song': [
                song,
                song,
                {...song, 'id': 'video', 'isVideo': true},
              ],
            },
          },
          'getSong' => {'song': song},
          'getLyricsBySongId' when lyricsList != null => {
            'lyricsList': lyricsList,
          },
          'search3' => {
            'searchResult3': {
              'song': [song],
            },
          },
          _ => {
            'error': {'code': 40, 'message': 'private-api-key'},
          },
        };
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'subsonic-response': {
              'status': payload.containsKey('error') ? 'failed' : 'ok',
              ...payload,
            },
          }),
        );
      }
      await response.close();
    } on IOException {
      // Cancellation intentionally closes the client before a held response.
    }
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}
