import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/service_track_link.dart';
import 'package:mornye/widgets/open_on_platform_sheet.dart';
import 'package:url_launcher/url_launcher.dart';

/// Online playback NEVER enters the download queue or saves a media file.
///
/// An extension that offers genuine, full-length streaming can implement the
/// optional action "resolvePlaybackStream" and return
/// { "url": "https://...", "full_track": true }. URLs must be directly
/// playable without additional request headers or client-side decryption.
/// Preview clips are expressly excluded.
///
/// Existing download-only extensions do not implement this contract. For them,
/// a streaming-service link opens in the provider's official app, subject to
/// that provider's normal account and subscription permissions.
Future<void> playOnline(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  // Keep the container for the whole request: a context menu may unmount when
  // the user taps its action.
  final container = ProviderScope.containerOf(context, listen: false);
  final extensions = container.read(extensionProvider).extensions;
  // Don't call arbitrary actions on legacy download providers. Only
  // extensions that opt into the full-stream contract are queried.
  final candidates = <String>{
    for (final extension in extensions)
      if (extension.enabled &&
          extension.capabilities['fullTrackStreaming'] == true)
        extension.id,
  };

  for (final extensionId in candidates) {
    try {
      final response = await PlatformBridge.invokeExtensionAction(
        extensionId,
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
      // Guard against accidentally playing a short preview or an encrypted
      // download URL. Only an explicit full-track playable URL is accepted.
      final url = response['url']?.toString().trim() ?? '';
      final uri = Uri.tryParse(url);
      if (response['full_track'] != true ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          response['requires_headers'] == true ||
          response['encrypted'] == true) {
        continue;
      }
      await container.read(musicPlayerControllerProvider).playSingle(
        PlayableMedia(
          id: 'online:${track.source ?? extensionId}:${track.id}',
          source: url,
          title: track.name,
          artist: track.artistName,
          album: track.albumName,
          artUri: normalizeArtUri(track.coverUrl ?? ''),
          duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
          explicit: track.isExplicit,
        ),
      );
      return;
    } catch (_) {
      // Download-only extensions have no streaming action. Continue looking
      // for another capable provider; never enqueue a download as fallback.
    }
  }

  // Full online listening through an authorized provider's app. Multiple
  // platforms are offered when a reliable ISRC or Spotify id is available.
  final isrc = track.isrc?.trim() ?? '';
  final spotifyId = RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(track.id)
      ? track.id
      : track.id.startsWith('spotify:')
          ? track.id.substring('spotify:'.length)
          : '';

  if (!context.mounted) return;
  if (isrc.isNotEmpty || RegExp(r'^[A-Za-z0-9]{22}
  if (link != null) {
    try {
      if (await launchUrl(link.appUri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // The native provider app may not be installed.
    }
    try {
      if (await launchUrl(
        Uri.parse(link.webUrl),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Fall through to a visible error.
    }
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No full-length online playback source is available for this track.',
        ),
      ),
    );
  }
}
).hasMatch(spotifyId)) {
    try {
      final links = await PlatformBridge.getTrackPlatformLinks(
        spotifyId: spotifyId,
        isrc: isrc,
      );
      if (links.isNotEmpty && context.mounted) {
        await OpenOnPlatformSheet.show(
          context,
          spotifyId: spotifyId,
          isrc: isrc,
        );
        return;
      }
    } catch (_) {
      // Use the original service link when cross-service lookup is offline.
    }
  }

  final link = serviceTrackLinkFor(track);
  if (link != null) {
    try {
      if (await launchUrl(link.appUri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // The native provider app may not be installed.
    }
    try {
      if (await launchUrl(
        Uri.parse(link.webUrl),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Fall through to a visible error.
    }
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No full-length online playback source is available for this track.',
        ),
      ),
    );
  }
}
