import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_protocol.dart';

void main() {
  test('a phone song round-trips and names its upload', () {
    final fileId = linkFileIdFor('/music/song.flac', 1234);
    final coverId = linkFileIdFor('/covers/a.jpg', 56);
    final song = LinkPhoneSong(
      fileId: fileId,
      suffix: 'flac',
      title: 'A song',
      artist: 'An artist',
      size: 1234,
      album: 'An album',
      albumArtist: 'Album artist',
      track: 2,
      disc: 1,
      year: 2024,
      genre: 'Pop',
      durationMs: 200000,
      isrc: 'XXABC2600001',
      bitRate: 900,
      sampleRate: 44100,
      bitDepth: 16,
      explicit: true,
      coverId: coverId,
      addedMs: 1000,
    );
    final copy = LinkPhoneSong.fromJson(song.toJson())!;
    expect(copy.toJson(), song.toJson());
    expect(copy.name, '$fileId.flac');
  });

  test('a phone song needs a file id, a known suffix and a title', () {
    final fileId = linkFileIdFor('content://media/1', 0);
    final valid = {'fileId': fileId, 'suffix': 'MP3', 'title': 'Song'};
    final song = LinkPhoneSong.fromJson(valid)!;
    expect(song.suffix, 'mp3');
    expect(song.artist, '');
    expect(song.size, 0);
    expect(song.toJson().containsKey('size'), isFalse);
    expect(LinkPhoneSong.fromJson({...valid, 'fileId': 'nope'}), isNull);
    expect(LinkPhoneSong.fromJson({...valid, 'suffix': 'exe'}), isNull);
    expect(LinkPhoneSong.fromJson({...valid, 'title': ' '}), isNull);
    expect(
      LinkPhoneSong.fromJson({...valid, 'coverId': 'x', 'size': -5}),
      isA<LinkPhoneSong>()
          .having((song) => song.coverId, 'coverId', isNull)
          .having((song) => song.size, 'size', 0),
    );
  });

  test('each phone has its own Library source id', () {
    final first = linkPhoneSourceId('device-1');
    expect(first, matches(RegExp(r'^link-phone-[0-9a-f]{16}$')));
    expect(linkPhoneSourceId('device-1'), first);
    expect(linkPhoneSourceId('device-2'), isNot(first));
    expect(isLinkPhoneSourceId(first), isTrue);
    expect(isLinkPhoneSourceId('link-phone-xyz'), isFalse);
    expect(isLinkPhoneSourceId('fixture'), isFalse);
  });
}
