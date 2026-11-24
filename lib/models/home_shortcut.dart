/// An action the Material Home can offer under Shortcuts. Settings store the
/// value's name, so renaming one drops it from saved choices.
enum HomeShortcut {
  shuffle,
  equalizer,
  listeningStats,
  networkStorage,
  loved,
  wishlist,
  favoriteArtists,
  newReleases,
  link;

  /// How many shortcuts Home shows: two rows of two on phones and the four
  /// rows beside Continue listening on desktop.
  static const slotCount = 4;

  static const defaults = [shuffle, equalizer, listeningStats, networkStorage];

  /// The [slotCount] shortcuts named in [names], in order. Unknown names and
  /// repeats give way to the first defaults not chosen yet, so Home keeps a
  /// full set after an update drops a shortcut or a backup holds too few.
  static List<HomeShortcut> resolve(List<String> names) {
    final chosen = <HomeShortcut>[];
    for (final name in names) {
      if (chosen.length == slotCount) break;
      final shortcut = values.asNameMap()[name];
      if (shortcut != null && !chosen.contains(shortcut)) chosen.add(shortcut);
    }
    for (final shortcut in [...defaults, ...values]) {
      if (chosen.length == slotCount) break;
      if (!chosen.contains(shortcut)) chosen.add(shortcut);
    }
    return chosen;
  }

  /// [current] with [picked] in [slot]. A shortcut already on Home trades
  /// places with the one it replaces, so picking also reorders.
  static List<HomeShortcut> place(
    List<HomeShortcut> current,
    int slot,
    HomeShortcut picked,
  ) {
    final next = [...current];
    final previous = next.indexOf(picked);
    if (previous >= 0) next[previous] = next[slot];
    next[slot] = picked;
    return next;
  }
}
