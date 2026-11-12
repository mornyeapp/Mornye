import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';

/// Play a full-length online stream *inside Mornye*, never through the
/// download queue, local media storage, or another streaming-service app.
///
/// The installed extension must advertise fullTrackStreaming and implement
/// resolvePlaybackStream. Legacy download-only providers are not suitable.
Future<void> playOnline(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final container = ProviderScope.containerOf(context, listen: false);

  void notify(String message, {bool busy = false}) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: busy ? 3 : 9),
      ),
    );
  }

  notify('Connecting to online audio stream…', busy: true);
  try {
    await container.read(extensionProvider.notifier).ensureInitialized();
  } catch (error) {
    notify('Extension initialization failed: $error');
    return;
  }

  final candidates = container
      .read(extensionProvider)
      .extensions
      .where(
        (extension) =>
            extension.enabled &&
            extension.capabilities['fullTrackStreaming'] == true,
      )
      .toList();

  if (candidates.isEmpty) {
    notify(
      'No online audio provider installed. Install and enable the '
      'experimental Qobuz Online .sflx extension in Mornye. '
      'The original Qobuz download extension cannot stream.',
    );
    return;
  }

  final failures = <String>[];
  for (final extension in candidates) {
    try {
      final result = await PlatformBridge.invokeExtensionAction(
        extension.id,
        'resolvePlaybackStream',
        input: {
          'id': track.id,
          'title': track.name,
          'artist': track.artistName,
          'album': track.albumName,
          'isrc': track.isrc ?? '',
          'duration_ms': track.duration * 1000,
        },
      );

      final url = result['url']?.toString().trim() ?? '';
      final uri = Uri.tryParse(url);
      final playable = result['full_track'] == true &&
          result['success'] != false &&
          result['encrypted'] != true &&
          result['requires_headers'] != true &&
          uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty;

      if (!playable) {
        final message = result['error']?.toString().trim();
        failures.add(
          '${extension.displayName}: '
          '${message != null && message.isNotEmpty ? message : "No playable full-track HTTPS URL"}',
        );
        continue;
      }

      final player = container.read(musicPlayerControllerProvider);
      final handler = await player.ensureInitialized();
      if (handler == null) {
        notify('Mornye internal audio player could not be initialized.');
        return;
      }
      await player.playSingle(
        PlayableMedia(
          id: 'online:${extension.id}:${track.id}',
          source: url,
          title: track.name,
          artist: track.artistName,
          album: track.albumName,
          artUri: normalizeArtUri(track.coverUrl ?? ''),
          duration: track.duration > 0
              ? Duration(seconds: track.duration)
              : null,
          explicit: track.isExplicit,
        ),
      );
      notify('Playing online in Mornye: ${track.name}');
      return;
    } catch (error) {
      // Do not silently open a streaming service or download as a fallback.
      // A failed authorized stream remains an error that the user can act on.
      failures.add('${extension.displayName}: $error');
    }
  }

  final detail = failures.join('; ');
  notify(
    detail.isEmpty
        ? 'No full-length online audio stream is available for this track.'
        : 'Online playback unavailable: '
            '${detail.length <= 300 ? detail : detail.substring(0, 300)}',
  );
}
