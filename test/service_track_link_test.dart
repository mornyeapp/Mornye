import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/utils/service_track_link.dart';

// Service names here are the app's fixed link formats, not extension ids.
Track _track(String id, {String? source, String? deezerId}) => Track(
  id: id,
  name: 'Example track',
  artistName: 'Example artist',
  albumName: 'Example album',
  duration: 180,
  source: source,
  deezerId: deezerId,
);

void main() {
  test('a prefixed id links to its own service', () {
    expect(
      serviceTrackLinkFor(_track('deezer:3135556'))?.webUrl,
      'https://www.deezer.com/track/3135556',
    );
    expect(
      serviceTrackLinkFor(_track('tidal:77640617'))?.webUrl,
      'https://listen.tidal.com/track/77640617',
    );
    expect(
      serviceTrackLinkFor(_track('qobuz:12345678'))?.webUrl,
      'https://play.qobuz.com/track/12345678',
    );
    final spotify = serviceTrackLinkFor(
      _track('spotify:track:4uLU6hMCjMI75M1A2tKUQC'),
    );
    expect(spotify?.serviceName, 'Spotify');
    expect(
      spotify?.webUrl,
      'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
    );
  });

  test('a bare id needs a source that names the service', () {
    expect(
      serviceTrackLinkFor(_track('3135556', source: 'deezer'))?.webUrl,
      'https://www.deezer.com/track/3135556',
    );
    expect(serviceTrackLinkFor(_track('3135556')), isNull);
    expect(
      serviceTrackLinkFor(_track('3135556', source: 'example-extension')),
      isNull,
    );
  });

  test('a known Deezer id is the fallback for unknown ids', () {
    final link = serviceTrackLinkFor(
      _track('example-track', source: 'example-extension', deezerId: '42'),
    );
    expect(link?.webUrl, 'https://www.deezer.com/track/42');
    expect(link?.serviceName, 'Deezer');
  });

  test('local and malformed ids have no link', () {
    expect(serviceTrackLinkFor(_track('/music/song.flac')), isNull);
    expect(serviceTrackLinkFor(_track('content://media/12')), isNull);
    expect(serviceTrackLinkFor(_track('')), isNull);
    expect(
      serviceTrackLinkFor(_track('example-track', deezerId: 'abc')),
      isNull,
    );
  });

  test('service URLs keep the id the metadata screen showed', () {
    expect(
      displayServiceTrackId(
        'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
      ),
      '4uLU6hMCjMI75M1A2tKUQC',
    );
    expect(
      serviceForTrackId(
        'https://listen.tidal.com/track/1',
        fallbackService: '',
      ),
      'tidal',
    );
    expect(serviceForTrackId('abc', fallbackService: 'local'), 'local');
  });
}
