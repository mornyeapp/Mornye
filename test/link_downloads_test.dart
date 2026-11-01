import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/link/features/link_downloads.dart';
import 'package:mornye/services/link/link_protocol.dart';

import 'support/link_fakes.dart';

void main() {
  const track = Track(
    id: 'provider:1',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 200,
    isrc: 'USABC2400001',
  );

  test('a tracks body carries Track JSON and the optional choices', () {
    final body = linkDownloadTracksBody(
      [track],
      service: 'example-service',
      playlistName: 'Road Trip',
    );
    expect(body['tracks'], [track.toJson()]);
    expect(body['service'], 'example-service');
    expect(body['playlistName'], 'Road Trip');
    expect(body.containsKey('quality'), isFalse);

    final bare = linkDownloadTracksBody([track], service: '', quality: null);
    expect(bare.keys, ['tracks']);
  });

  test('a link body carries the trimmed URL', () {
    expect(linkDownloadUrlBody(' https://music.example.com/a/1 '), {
      'url': 'https://music.example.com/a/1',
    });
  });

  test('queueing reports what the desktop queued', () async {
    final client = FakeLinkClient(onPost: (op, body) => {'queued': 12});
    final queued = await linkQueueDesktopDownloads(
      client,
      linkDownloadTracksBody([track]),
    );
    expect(queued, 12);
    expect(client.posts.single.op, LinkOps.downloads);

    client.onPost = (op, body) => {'ok': true};
    expect(
      await linkQueueDesktopDownloads(client, linkDownloadUrlBody('x')),
      0,
    );
  });

  test('opening a link posts it to the desktop', () async {
    final client = FakeLinkClient();
    await linkOpenOnDesktop(client, ' https://music.example.com/t/2');
    expect(client.posts.single.op, LinkOps.open);
    expect(client.posts.single.body, {'url': 'https://music.example.com/t/2'});
  });

  test('download items accept fractions and percentages', () {
    final items = linkParseDownloads({
      'items': [
        {'id': 1, 'title': 'A', 'status': 'QUEUED'},
        {'id': 'b', 'title': 'B', 'status': 'downloading', 'progress': 0.25},
        {'id': 'c', 'title': 'C', 'status': 'downloading', 'progress': 75},
        {'title': 'no id'},
        'junk',
      ],
    });
    expect(items.map((item) => item.id), ['1', 'b', 'c']);
    expect(items.first.status, 'queued');
    expect(items.first.progress, isNull);
    expect(items[1].progress, 0.25);
    expect(items[2].progress, 0.75);
    expect(linkParseDownloads(null), isEmpty);
    expect(linkParseDownloads({'items': 'none'}), isEmpty);
  });
}
