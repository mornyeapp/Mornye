import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/smart_playlists_provider.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/services/smart_playlists_service.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

class SmartPlaylistScreen extends ConsumerWidget {
  final SmartPlaylistType type;

  const SmartPlaylistScreen({super.key, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(smartPlaylistTracksProvider(type));

    return tracksAsync.when(
      data: (tracks) =>
          PlaylistScreen(playlistName: type.title, tracks: tracks),
      loading: () => Scaffold(
        appBar: AppBar(title: Text(type.title), elevation: 0),
        body: const Center(child: AppLoadingIndicator()),
      ),
      error: (err, _) => Scaffold(
        appBar: AppBar(title: Text(type.title), elevation: 0),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              'Errore durante il caricamento: $err',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
