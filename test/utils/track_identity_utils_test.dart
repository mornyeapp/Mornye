import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/track_identity_utils.dart';

void main() {
  group('TrackIdentityUtils', () {
    test('simplifyTrackTitle strips remaster and edition suffixes', () {
      expect(
        TrackIdentityUtils.simplifyTrackTitle(
          'Bohemian Rhapsody - 2011 Remaster',
        ),
        'bohemian rhapsody',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle('Hotel California (Remastered)'),
        'hotel california',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle('Easy On Me - Single Version'),
        'easy on me',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle('Starboy (Deluxe Edition)'),
        'starboy',
      );
    });

    test('simplifyTrackTitle strictly preserves performance versions', () {
      expect(
        TrackIdentityUtils.simplifyTrackTitle(
          'Hotel California (Live at the Forum)',
        ),
        'hotel california (live at the forum)',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle('Solace (Slowed)'),
        'solace (slowed)',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle('Bad Guy (Acoustic)'),
        'bad guy (acoustic)',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle(
          'Levitating (The Blessed Madonna Remix)',
        ),
        'levitating (the blessed madonna remix)',
      );
      expect(
        TrackIdentityUtils.simplifyTrackTitle(
          'Comfortably Numb (Instrumental)',
        ),
        'comfortably numb (instrumental)',
      );
    });

    test(
      'simplifyTrackTitle and extractPrimaryArtist align collaborations',
      () {
        final keyA = TrackIdentityUtils.canonicalKey(
          title: 'Wait For U (feat. Drake & Tems)',
          artist: 'Future',
        );
        final keyB = TrackIdentityUtils.canonicalKey(
          title: 'Wait For U',
          artist: 'Future, Drake, Tems',
        );
        expect(keyA, 'wait for u|future');
        expect(keyB, 'wait for u|future');
        expect(keyA, equals(keyB));
      },
    );

    test('canonicalKey generates isolated orphan keys for untagged tracks', () {
      final orphanA = TrackIdentityUtils.canonicalKey(
        title: 'Track 01',
        artist: '',
        source: 'file:///path/to/track1.flac',
      );
      final orphanB = TrackIdentityUtils.canonicalKey(
        title: 'Track 01',
        artist: '',
        source: 'file:///path/to/track2.flac',
      );
      expect(orphanA.startsWith('local_orphan:'), isTrue);
      expect(orphanB.startsWith('local_orphan:'), isTrue);
      expect(orphanA, isNot(equals(orphanB)));
    });

    test('matchesDuration handles tolerance and duration guards', () {
      // Within 15s or 8% tolerance (e.g. 210s vs 214s)
      expect(TrackIdentityUtils.matchesDuration(210000, 214000), isTrue);
      // Radio edit (180s) vs 7-minute extended live cut (420s)
      expect(TrackIdentityUtils.matchesDuration(180000, 420000), isFalse);
      // Unknown duration (<= 0) always matches
      expect(TrackIdentityUtils.matchesDuration(0, 210000), isTrue);
    });
  });
}
