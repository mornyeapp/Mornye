import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/playback_notification.dart';

/// Kept alive by the app shell so notification favorites share the exact
/// Library identity and refresh when the same track is starred inside the app.
final playbackNotificationProvider = Provider.autoDispose
    .family<
      void,
      ({
        String favorite,
        String unfavorite,
        String shuffleOn,
        String shuffleOff,
      })
    >((ref, labels) {
      final mornye = ref.watch(
        themeProvider.select((theme) => theme.style == AppThemeStyle.mornye),
      );
      final item = ref.watch(localMediaItemProvider).value;
      final track = item == null
          ? null
          : ref.watch(playerCollectionTrackProvider(item)).value;
      final loved = ref.watch(
        libraryCollectionsProvider.select(
          (state) => track != null && state.isLoved(track),
        ),
      );
      // Publishing playback state inside a provider build would synchronously
      // modify the stream provider this binding is observing.
      var active = true;
      ref.onDispose(() => active = false);
      scheduleMicrotask(() {
        if (!active) return;
        final runtime = ref.read(musicPlayerRuntimeProvider);
        runtime.configureNotification(
          presentation: PlaybackNotification(
            mornye: mornye,
            mediaId: item?.id,
            source: item?.extras?['source']?.toString(),
            loved: loved,
            favoriteLabel: labels.favorite,
            unfavoriteLabel: labels.unfavorite,
            shuffleOnLabel: labels.shuffleOn,
            shuffleOffLabel: labels.shuffleOff,
          ),
          toggleFavorite: (selected) async {
            final collections = ref.read(libraryCollectionsProvider.notifier);
            final selectedTrack = await ref.read(
              playerCollectionTrackProvider(selected).future,
            );
            return collections.toggleLoved(selectedTrack);
          },
        );
      });
    });
