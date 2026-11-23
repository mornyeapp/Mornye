import 'package:flutter/foundation.dart';

/// A part of Home the person can move or hide, in the order Home ships.
/// Settings store the names, so renaming a value drops it from saved layouts.
enum HomeSection {
  /// The download queue at a glance, while another app is the player.
  downloads,

  /// Mornye's banner shelf of the day's mixes and playlists.
  topPicks,

  /// Mornye's shelf of albums played lately.
  recentlyPlayed,
  continueListening,
  shortcuts,

  /// Nine Library songs as a grid of covers, each one tap from playing.
  quickPlay,

  /// What the person pinned, where it does not sit among [shortcuts].
  pins,

  /// The attached Link device, while there is one.
  link,

  /// The person's Hi-Res albums, while a DAC or exclusive output plays.
  hiRes,

  /// The Material mixes shelf; Mornye shows the mixes in [topPicks].
  mixes,
  recentlyAdded,

  /// Loose ends of the collection: wishlist, albums with gaps and the like.
  unfinished,
  recommended,
  newReleases,

  /// The most played songs, or Library albums without a listening record.
  onRepeat;

  /// Whether the section exists at all in the style, with the built-in
  /// [player] or with another app playing.
  bool availableIn({
    required bool mornye,
    bool player = true,
    bool desktop = false,
  }) => switch (this) {
    downloads => !player,
    topPicks => mornye,
    recentlyPlayed => mornye && player,
    continueListening || quickPlay => player,
    shortcuts => !mornye,
    // Material phones and tablets show the pins among the Shortcuts.
    pins => mornye || desktop,
    mixes => !mornye && player,
    _ => true,
  };
}

/// How the person arranged Home. The default value is Home as it ships.
@immutable
class HomeLayout {
  const HomeLayout({
    this.order = const [],
    this.hidden = const {},
    this.shown = const {},
  });

  /// Sections that ship turned off; Edit Home turns them on.
  static const offByDefault = {HomeSection.unfinished, HomeSection.onRepeat};

  /// Section names in the person's order. Sections missing from it keep
  /// their shipped place; see [sections].
  final List<String> order;

  /// Names of the sections the person turned off.
  final Set<String> hidden;

  /// Names of the [offByDefault] sections the person turned on.
  final Set<String> shown;

  bool get isDefault => order.isEmpty && hidden.isEmpty && shown.isEmpty;

  /// Every section in the person's order. A section the saved order does
  /// not name (a new one, or one a backup lacks) goes after the section it
  /// follows in the shipped order, so it lands where it ships.
  List<HomeSection> get sections {
    final byName = HomeSection.values.asNameMap();
    final ordered = <HomeSection>[];
    for (final name in order) {
      final section = byName[name];
      if (section != null && !ordered.contains(section)) ordered.add(section);
    }
    for (final (index, section) in HomeSection.values.indexed) {
      if (ordered.contains(section)) continue;
      var at = 0;
      for (var before = index - 1; before >= 0; before--) {
        final found = ordered.indexOf(HomeSection.values[before]);
        if (found >= 0) {
          at = found + 1;
          break;
        }
      }
      ordered.insert(at, section);
    }
    return ordered;
  }

  bool shows(HomeSection section) => offByDefault.contains(section)
      ? shown.contains(section.name)
      : !hidden.contains(section.name);

  HomeLayout withOrder(List<HomeSection> sections) => HomeLayout(
    order: [for (final section in sections) section.name],
    hidden: hidden,
    shown: shown,
  );

  HomeLayout withVisible(HomeSection section, bool visible) {
    Set<String> having(Set<String> names, bool has) =>
        has ? {...names, section.name} : ({...names}..remove(section.name));
    return offByDefault.contains(section)
        ? HomeLayout(
            order: order,
            hidden: hidden,
            shown: having(shown, visible),
          )
        : HomeLayout(
            order: order,
            hidden: having(hidden, !visible),
            shown: shown,
          );
  }

  /// Reads a saved layout. Anything unreadable is left out, so a damaged or
  /// newer backup still gives a usable Home.
  factory HomeLayout.fromJson(Map<String, dynamic> json) {
    List<String> names(Object? value) => [
      if (value is List)
        for (final name in value)
          if (name is String) name,
    ];
    return HomeLayout(
      order: names(json['order']),
      hidden: names(json['hidden']).toSet(),
      shown: names(json['shown']).toSet(),
    );
  }

  Map<String, dynamic> toJson() => {
    'order': order,
    'hidden': hidden.toList()..sort(),
    'shown': shown.toList()..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is HomeLayout &&
      listEquals(order, other.order) &&
      setEquals(hidden, other.hidden) &&
      setEquals(shown, other.shown);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(order),
    Object.hashAllUnordered(hidden),
    Object.hashAllUnordered(shown),
  );
}
