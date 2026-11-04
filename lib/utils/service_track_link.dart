import 'package:mornye/constants/music_services.dart';
import 'package:mornye/models/track.dart';

final _spotifyTrackIdPattern = RegExp(r'^[A-Za-z0-9]{22}$');

/// A track's page on the streaming service its id came from.
class ServiceTrackLink {
  const ServiceTrackLink(this.service, this.id);

  /// One of the [MusicServices] streaming services.
  final String service;

  /// The service's own track id, without a `service:` prefix.
  final String id;

  String get serviceName => switch (service) {
    MusicServices.deezer => 'Deezer',
    MusicServices.amazon => 'Amazon Music',
    MusicServices.tidal => 'Tidal',
    MusicServices.qobuz => 'Qobuz',
    _ => 'Spotify',
  };

  String get webUrl => switch (service) {
    MusicServices.deezer => 'https://www.deezer.com/track/$id',
    MusicServices.amazon => 'https://music.amazon.com/search/$id',
    MusicServices.tidal => 'https://listen.tidal.com/track/$id',
    MusicServices.qobuz => 'https://play.qobuz.com/track/$id',
    _ => 'https://open.spotify.com/track/$id',
  };

  /// The service app's own link, tried before [webUrl].
  Uri get appUri => switch (service) {
    MusicServices.deezer => Uri.parse('deezer://www.deezer.com/track/$id'),
    MusicServices.amazon => Uri.parse('amznm://search/$id'),
    MusicServices.tidal => Uri.parse('tidal://track/$id'),
    MusicServices.qobuz => Uri.parse('qobuz://track/$id'),
    _ => Uri.parse('spotify:track:$id'),
  };
}

const _streamingServices = {
  MusicServices.spotify,
  MusicServices.deezer,
  MusicServices.tidal,
  MusicServices.qobuz,
  MusicServices.amazon,
};

/// The service [value] names through a prefix, a service URL or a Spotify
/// id, or [fallbackService] when it names none.
String serviceForTrackId(String value, {required String fallbackService}) {
  final raw = value.trim();
  if (raw.isEmpty) return fallbackService;
  if (raw.startsWith('deezer:')) return MusicServices.deezer;
  if (raw.startsWith('tidal:')) return MusicServices.tidal;
  if (raw.startsWith('qobuz:')) return MusicServices.qobuz;
  if (raw.startsWith('spotify:')) return MusicServices.spotify;
  if (_spotifyTrackIdPattern.hasMatch(raw)) return MusicServices.spotify;

  final uri = Uri.tryParse(raw);
  if (uri != null) {
    final host = uri.host.toLowerCase();
    if (host.contains('spotify.com')) return MusicServices.spotify;
    if (host.contains('deezer.com')) return MusicServices.deezer;
    if (host.contains('tidal.com')) return MusicServices.tidal;
    if (host.contains('qobuz.com')) return MusicServices.qobuz;
  }
  return fallbackService;
}

/// [value] without its `service:` prefix or Spotify URL wrapping.
String displayServiceTrackId(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return raw;

  if (raw.startsWith('deezer:')) return raw.substring('deezer:'.length);
  if (raw.startsWith('tidal:')) return raw.substring('tidal:'.length);
  if (raw.startsWith('qobuz:')) return raw.substring('qobuz:'.length);
  if (_spotifyTrackIdPattern.hasMatch(raw)) return raw;

  if (raw.startsWith('spotify:')) {
    final last = raw.split(':').last.trim();
    if (_spotifyTrackIdPattern.hasMatch(last)) return last;
    return raw;
  }

  final uri = Uri.tryParse(raw);
  if (uri != null &&
      uri.host.contains('spotify.com') &&
      uri.pathSegments.length >= 2 &&
      uri.pathSegments.first == 'track') {
    final candidate = uri.pathSegments[1].trim();
    if (_spotifyTrackIdPattern.hasMatch(candidate)) return candidate;
  }
  return raw;
}

/// The service page of [track], or null when its id does not say which
/// streaming service it belongs to. A source counts only when it is itself a
/// service name, since extension ids say nothing about their catalog.
ServiceTrackLink? serviceTrackLinkFor(Track track) {
  final source = track.source?.trim().toLowerCase() ?? '';
  final fallback = _streamingServices.contains(source) ? source : '';
  final service = serviceForTrackId(track.id, fallbackService: fallback);
  if (service.isNotEmpty) {
    final id = displayServiceTrackId(track.id);
    if (id.isNotEmpty && !id.contains('/') && !id.contains(':')) {
      return ServiceTrackLink(service, id);
    }
  }
  final deezerId = track.deezerId?.trim() ?? '';
  if (RegExp(r'^\d+$').hasMatch(deezerId)) {
    return ServiceTrackLink(MusicServices.deezer, deezerId);
  }
  return null;
}
