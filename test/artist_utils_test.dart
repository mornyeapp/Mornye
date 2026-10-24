import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  test('artist credits deduplicate names without dropping a final X', () {
    expect(splitArtistTagValues('One, Two; one & Three feat. TWO'), [
      'One',
      'Two',
      'Three',
    ]);
    expect(splitArtistTagValues('One x Two'), ['One', 'Two']);
    expect(splitArtistTagValues('Malcolm X'), ['Malcolm X']);
    expect(splitArtistTagValues('X'), ['X']);
    expect(splitArtistTagValues('  '), isEmpty);
  });

  test('featured variants and confirmed conjunction credits are clickable', () {
    expect(splitArtistNames('One featured Two'), ['One', 'Two']);
    expect(splitArtistNames('One feature Two'), ['One', 'Two']);
    expect(primaryArtistTagValue('One featured Two'), 'One');
    expect(primaryArtistTagValue('One feature Two'), 'One');
    expect(splitArtistNames('One and Two', creditedArtistCount: 2), [
      'One',
      'Two',
    ]);
    expect(splitArtistNames('Florence and the Machine'), [
      'Florence and the Machine',
    ]);
    expect(
      splitArtistNames('Florence and the Machine', creditedArtistCount: 1),
      ['Florence and the Machine'],
    );
  });
  test('primary artist prefers the first album artist', () {
    expect(
      primaryArtistName(
        'Track Artist, Guest Artist',
        albumArtist: 'Album Artist & Collaborator',
      ),
      'Album Artist',
    );
  });

  test('primary artist handles provider separator variants', () {
    expect(primaryArtistName('One; Two & Three'), 'One');
    expect(primaryArtistName('One feat. Two'), 'One');
    expect(primaryArtistName('AC/DC'), 'AC/DC');
    expect(
      primaryArtistName('Actual Artist, Guest', albumArtist: 'Various Artists'),
      'Actual Artist',
    );
  });
}
