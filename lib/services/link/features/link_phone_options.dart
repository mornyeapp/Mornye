import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('LinkPhoneOptions');

/// This phone's choices for its paired computer.
@immutable
class LinkPhoneOptions {
  const LinkPhoneOptions({
    this.loaded = false,
    this.shareSongs = true,
    this.followDesktop = true,
  });

  /// The saved choices were read.
  final bool loaded;

  /// This phone's songs show in the computer's Library and play there.
  final bool shareSongs;

  /// The player screens follow the computer when it starts playing.
  final bool followDesktop;

  LinkPhoneOptions copyWith({bool? shareSongs, bool? followDesktop}) =>
      LinkPhoneOptions(
        loaded: true,
        shareSongs: shareSongs ?? this.shareSongs,
        followDesktop: followDesktop ?? this.followDesktop,
      );
}

/// Keeps [LinkPhoneOptions] in shared preferences. Tests pass [initial],
/// which skips reading them.
class LinkPhoneOptionsNotifier extends Notifier<LinkPhoneOptions> {
  LinkPhoneOptionsNotifier({this.initial});

  static const shareSongsKey = 'link_phone_share_songs';
  static const followDesktopKey = 'link_phone_follow_desktop';

  final LinkPhoneOptions? initial;

  @override
  LinkPhoneOptions build() {
    if (initial case final options?) return options;
    unawaited(_restore());
    return const LinkPhoneOptions();
  }

  Future<void> _restore() async {
    var options = const LinkPhoneOptions(loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      options = LinkPhoneOptions(
        loaded: true,
        shareSongs: prefs.getBool(shareSongsKey) ?? true,
        followDesktop: prefs.getBool(followDesktopKey) ?? true,
      );
    } on Object catch (error) {
      _log.w('Could not read the Mornye Link choices: $error');
    }
    // A choice made meanwhile stands.
    if (ref.mounted && !state.loaded) state = options;
  }

  void setShareSongs(bool share) {
    state = state.copyWith(shareSongs: share);
    unawaited(_persist((prefs) => prefs.setBool(shareSongsKey, share)));
  }

  void setFollowDesktop(bool follow) {
    state = state.copyWith(followDesktop: follow);
    unawaited(_persist((prefs) => prefs.setBool(followDesktopKey, follow)));
  }

  Future<void> _persist(Future<void> Function(SharedPreferences) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } on Object catch (error) {
      _log.w('Could not save the Mornye Link choices: $error');
    }
  }
}

final linkPhoneOptionsProvider =
    NotifierProvider<LinkPhoneOptionsNotifier, LinkPhoneOptions>(
      LinkPhoneOptionsNotifier.new,
    );
