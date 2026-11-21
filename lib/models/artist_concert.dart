import 'package:mornye/utils/string_utils.dart';
import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Provider-neutral event metadata. Calendar labels always use the venue's
/// local time, never the listener's device time zone.
class ArtistConcert {
  const ArtistConcert({
    required this.id,
    required this.location,
    required this.venue,
    required this.date,
    required this.hasTime,
    this.url,
    this.detailId,
  });

  final String id;
  final String location;
  final String venue;
  final DateTime date;
  final bool hasTime;
  final String? url;
  final String? detailId;

  static bool _timeZonesReady = false;

  static List<ArtistConcert> parseList(Object? value) {
    if (value is! List) return const [];
    final concerts = <String, ArtistConcert>{};
    for (final item in value.take(500)) {
      if (item is! Map<String, dynamic>) continue;
      String text(String key) =>
          item[key] is String ? (item[key] as String).trim() : '';
      final rawDate = text('start_at');
      final match = RegExp(
        r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$',
      ).firstMatch(rawDate);
      final instant = DateTime.tryParse(rawDate);
      final location = text('location');
      if (match == null || instant == null || location.isEmpty) continue;
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final hour = int.parse(match[4] ?? '0');
      final minute = int.parse(match[5] ?? '0');
      var date = DateTime.utc(year, month, day, hour, minute);
      // DateTime.parse normalizes impossible dates; do not show invented days.
      if (date.year != year ||
          date.month != month ||
          date.day != day ||
          hour > 23 ||
          minute > 59) {
        continue;
      }
      final zone = text('time_zone');
      if (zone.isNotEmpty && match[6] != null) {
        if (!_timeZonesReady) {
          tz_data.initializeTimeZones();
          _timeZonesReady = true;
        }
        try {
          date = tz.TZDateTime.from(instant, tz.getLocation(zone));
        } on tz.LocationNotFoundException {
          // Preserve the supplied wall-clock date if the zone is unknown.
        }
      }
      final id = text('id');
      final venue = text('venue');
      final key = id.isEmpty ? '$rawDate|$location|$venue' : id;
      concerts.putIfAbsent(
        key,
        () => ArtistConcert(
          id: key,
          location: location,
          venue: venue,
          date: date,
          hasTime: match[4] != null,
          url: normalizeRemoteHttpUrl(text('url')),
          detailId: text('detail_id').isEmpty ? null : text('detail_id'),
        ),
      );
    }
    return concerts.values.toList()..sort((a, b) => a.date.compareTo(b.date));
  }
}

class ConcertDetail {
  const ConcertDetail({
    this.artistName,
    this.title,
    this.coverUrl,
    this.venue,
    this.address,
    this.start,
    this.end,
    this.ticketUrl,
    this.mapUrl,
    this.url,
    this.attribution,
    this.setListId,
    this.setListName,
    this.setListCover,
  });

  final String? artistName;
  final String? title;
  final String? coverUrl;
  final String? venue;
  final String? address;
  final DateTime? start;
  final DateTime? end;
  final String? ticketUrl;
  final String? mapUrl;
  final String? url;
  final String? attribution;
  final String? setListId;
  final String? setListName;
  final String? setListCover;

  factory ConcertDetail.fromJson(Map<String, dynamic> json) {
    String? text(Map<String, dynamic> data, String key) {
      final value = data[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    String? link(Map<String, dynamic> data, String key) =>
        normalizeRemoteHttpUrl(text(data, key));
    final setList = json['set_list'] is Map<String, dynamic>
        ? json['set_list'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return ConcertDetail(
      artistName: text(json, 'artist_name'),
      title: text(json, 'title'),
      coverUrl: link(json, 'cover_url'),
      venue: text(json, 'venue'),
      address: text(json, 'address'),
      start: DateTime.tryParse(text(json, 'start_at') ?? ''),
      end: DateTime.tryParse(text(json, 'end_at') ?? ''),
      ticketUrl: link(json, 'ticket_url'),
      mapUrl: link(json, 'map_url'),
      url: link(json, 'url'),
      attribution: text(json, 'attribution'),
      setListId: text(setList, 'id'),
      setListName: text(setList, 'name'),
      setListCover: link(setList, 'cover_url'),
    );
  }
}
