import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/smart_playlists_service.dart';

final smartPlaylistsServiceProvider = Provider<SmartPlaylistsService>((ref) {
  return SmartPlaylistsService.instance;
});

final smartPlaylistTracksProvider =
    FutureProvider.family<List<Track>, SmartPlaylistType>((ref, type) async {
      final service = ref.watch(smartPlaylistsServiceProvider);
      return service.getPlaylistTracks(type);
    });
