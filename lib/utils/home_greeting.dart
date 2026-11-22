import 'dart:math';

import 'package:mornye/l10n/app_localizations.dart';

/// Picked once per launch: the greeting holds still while browsing and
/// changes the next time the app opens.
final int _sessionVariant = Random().nextInt(1 << 16);

/// A time-of-day Home greeting, addressed by the profile's first name when
/// one is set.
String homeGreeting(
  AppLocalizations l10n, {
  String name = '',
  DateTime? now,
  int? variant,
}) {
  final hour = (now ?? DateTime.now()).hour;
  final options = switch (hour) {
    >= 5 && < 12 => [
      l10n.homeGreetingMorning1,
      l10n.homeGreetingMorning2,
      l10n.homeGreetingMorning3,
    ],
    >= 12 && < 17 => [
      l10n.homeGreetingAfternoon1,
      l10n.homeGreetingAfternoon2,
      l10n.homeGreetingAfternoon3,
    ],
    >= 17 && < 21 => [
      l10n.homeGreetingEvening1,
      l10n.homeGreetingEvening2,
      l10n.homeGreetingEvening3,
    ],
    _ => [
      l10n.homeGreetingNight1,
      l10n.homeGreetingNight2,
      l10n.homeGreetingNight3,
    ],
  };
  final phrase = options[(variant ?? _sessionVariant) % options.length];
  final trimmed = name.trim();
  if (trimmed.isEmpty) return phrase;
  // A full name reads stiff in a headline.
  return l10n.homeGreetingNamed(phrase, trimmed.split(RegExp(r'\s+')).first);
}
