import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/m3u_playlist_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M3U8 Export & Import', () {
    test('buildM3u8Content formats standard EXTINF lines correctly', () {
      final entries = [
        const M3uExportEntry(
          track: Track(
            id: '1',
            name: 'Song One',
            artistName: 'Artist One',
            albumName: 'Album One',
            duration: 180,
          ),
          path: '/music/song1.flac',
        ),
        const M3uExportEntry(
          track: Track(
            id: '2',
            name: 'Song Two',
            artistName: 'Artist Two',
            albumName: 'Album Two',
            duration: 240,
          ),
          path: '/music/song2.mp3',
        ),
      ];

      final content = M3uPlaylistService.buildM3u8Content(entries);
      expect(content, startsWith('#EXTM3U\n'));
      expect(
        content,
        contains('#EXTINF:180,Artist One - Song One\n/music/song1.flac'),
      );
      expect(
        content,
        contains('#EXTINF:240,Artist Two - Song Two\n/music/song2.mp3'),
      );

      final parsed = M3uPlaylistService.parseM3u(content);
      expect(parsed.length, 2);
      expect(parsed[0].name, 'Song One');
      expect(parsed[0].artistName, 'Artist One');
      expect(parsed[1].name, 'Song Two');
      expect(parsed[1].artistName, 'Artist Two');
    });

    test('exportPathFor normalizes SAF URIs to relative folder paths', () {
      final plain = M3uPlaylistService.exportPathFor(
        '/storage/emulated/0/Music/track.flac',
      );
      expect(plain, '/storage/emulated/0/Music/track.flac');

      final safTree = M3uPlaylistService.exportPathFor(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2FRock%2Ftrack.flac',
      );
      expect(safTree, contains('track.flac'));
    });
  });
}
