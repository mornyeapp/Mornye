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

  /// The most shortcuts Home shows: two rows of two on phones and the four
  /// rows beside Continue listening on desktop.
  static const slotCount = 4;

  /// Stands in the saved names for a slot the person emptied. Older
  /// versions read it as an unknown name and fill the slot.
  static const removedName = 'none';

  static const defaults = [shuffle, equalizer, listeningStats, networkStorage];

  /// Shortcuts that only work with the built-in player.
  static const playerOnly = {shuffle, equalizer, listeningStats};

  /// The shortcuts Home can offer: all of them, or without [playerOnly]
  /// while another app plays the music.
  static List<HomeShortcut> available({required bool player}) => [
    for (final shortcut in values)
      if (player || !playerOnly.contains(shortcut)) shortcut,
  ];

  /// The shortcuts named in [names], in order: [slotCount] of them, less one
  /// for each [removedName]. Unknown names and repeats give way to the first
  /// defaults not chosen yet, so Home keeps its set after an update drops a
  /// shortcut or a backup holds too few. Without [player] the [playerOnly]
  /// ones give way the same way.
  static List<HomeShortcut> resolve(List<String> names, {bool player = true}) {
    final offered = available(player: player);
    final chosen = <HomeShortcut>[];
    var slots = slotCount;
    for (final name in names) {
      if (chosen.length == slots) break;
      if (name == removedName) {
        slots--;
        continue;
      }
      final shortcut = values.asNameMap()[name];
      if (shortcut != null &&
          offered.contains(shortcut) &&
          !chosen.contains(shortcut)) {
        chosen.add(shortcut);
      }
    }
    for (final shortcut in [...defaults, ...values]) {
      if (chosen.length == slots) break;
      if (offered.contains(shortcut) && !chosen.contains(shortcut)) {
        chosen.add(shortcut);
      }
    }
    return chosen;
  }

  /// [shortcuts] as settings store them: their names, then [removedName]
  /// for each slot left empty.
  static List<String> names(List<HomeShortcut> shortcuts) => [
    for (final shortcut in shortcuts.take(slotCount)) shortcut.name,
    for (var slot = shortcuts.length; slot < slotCount; slot++) removedName,
  ];

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
