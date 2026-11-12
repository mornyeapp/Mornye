import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/controllers/online_stream_settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';

const onlineStreamScheme = 'mornye-online';

/// Raised only for the signed-session grant required by the extension.
/// The stock Mornye grant flow opens the provider's actual auth URL.
class OnlineStreamVerificationRequired implements Exception {
  const OnlineStreamVerificationRequired();
  @override
  String toString() => 'VERIFY_REQUIRED';
}


Map<String, dynamic> onlineStreamRequest(Track track, String quality) => {
  'id': track.id,
  'source': track.source ?? '',
  'title': track.name,
  'artist': track.artistName,
  'album': track.albumName,
  'isrc': track.isrc ?? '',
  'duration_ms': track.duration * 1000,
  'quality': quality,
};

/// Prefer the service the track was retrieved from, not the first extension
/// in an arbitrary provider list. Other enabled sources remain fallbacks.
String? preferredOnlineProvider(String? source) {
  switch (source?.trim().toLowerCase()) {
    case 'jellyfin':
      return 'jellyfin';
    case 'soundcloud':
      return 'soundcloud';
    case 'qobuz':
    case 'qobuz-web':
      return 'qobuz-web';
    default:
      return null;
  }
}

bool isFullOnlineStream(Map<String, dynamic> result) {
  final uri = Uri.tryParse(result['url']?.toString().trim() ?? '');
  return result['success'] != false &&
      result['full_track'] == true &&
      result['encrypted'] != true &&
      result['requires_headers'] != true &&
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty;
}

PlayableMedia _item(
  Track track,
  String provider,
  String quality,
  int index, {
  Map<String, dynamic>? resolved,
}) {
  // A self-hosted Jellyfin URL may contain an access token.
  // Keep ONLY a resolver descriptor in persistent queues and media metadata.
  final source = resolved == null || resolved['url_contains_credentials'] == true
      ? Uri(
          scheme: onlineStreamScheme,
          host: provider,
          pathSegments: [track.id],
          queryParameters: {
            'title': track.name,
            'source': track.source ?? '',
            'artist': track.artistName,
            'album': track.albumName,
            'isrc': track.isrc ?? '',
            'duration_ms': '${track.duration * 1000}',
            'quality': quality,
          },
        ).toString()
      : resolved['url'].toString();
  int? positive(Object? value) {
    final number = value is num ? value.toInt() : int.tryParse('$value');
    return number != null && number > 0 ? number : null;
  }

  return PlayableMedia(
    id: 'online:$provider:$index:${track.id}',
    source: source,
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    artUri: normalizeArtUri(track.coverUrl ?? ''),
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    explicit: track.isExplicit,
    // Do not claim FLAC when the provider actually serves AAC/MP3/Opus.
    format: resolved?['format']?.toString().toUpperCase(),
    bitDepth: positive(resolved?['bit_depth']),
    sampleRate: positive(resolved?['sample_rate']),
    bitrate: positive(resolved?['bitrate']),
    displayMetadata: {
      'online_stream': true,
      'online_provider': provider,
      'online_quality': quality,
      'online_request': onlineStreamRequest(track, quality),
    },
  );
}

/// Play an album/playlist in original order. Later URLs resolve only on play.
Future<void> playOnlineQueue(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  int startIndex = 0,
  String? qualityOverride,
}) async {
  if (tracks.isEmpty || startIndex < 0 || startIndex >= tracks.length) return;
  final container = ProviderScope.containerOf(context, listen: false);
  void notify(String message) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 7)),
    );
  }

  try {
    await container.read(extensionProvider.notifier).ensureInitialized();
  } catch (error) {
    notify('Online provider initialization failed: $error');
    return;
  }
  final extensions = container
      .read(extensionProvider)
      .extensions
      .where(
        (extension) =>
            extension.enabled &&
            extension.capabilities['fullTrackStreaming'] == true,
      )
      .toList();
  final preferred = preferredOnlineProvider(tracks[startIndex].source);
  extensions.sort((a, b) {
    final aRank = a.id == preferred ? 0 : 1;
    final bRank = b.id == preferred ? 0 : 1;
    return aRank.compareTo(bRank);
  });
  if (extensions.isEmpty) {
    notify('No streaming provider enabled. Enable a streaming extension.');
    return;
  }

  final quality = qualityOverride ?? await OnlineStreamSettings.current();
  final track = tracks[startIndex];
  final failures = <String>[];
  for (final extension in extensions) {
    try {
      // The Qobuz extension may return {success:false,error:'VERIFY_REQUIRED'}
      // instead of throwing. Convert that *specific* result into a verification
      // request so the existing signed-session browser grant flow can complete.
      // The helper retries exactly once after a successful grant.
      final result = await runExtensionOperationWithVerificationRetry<
        Map<String, dynamic>
      >(
        extensionId: extension.id,
        browserMode: 'external_first',
        operation: () async {
          final response = await PlatformBridge.invokeExtensionAction(
            extension.id,
            'resolvePlaybackStream',
            input: onlineStreamRequest(track, quality),
          );
          if (isExtensionVerificationRequired(
            response['error']?.toString() ?? '',
          )) {
            throw const OnlineStreamVerificationRequired();
          }
          return response;
        },
      );
      if (!isFullOnlineStream(result)) {
        failures.add(
          '${extension.displayName}: ${result['error'] ?? 'No full-track HTTPS URL'}',
        );
        continue;
      }
      final enabledProviderIds = extensions.map((e) => e.id).toSet();
      final queue = [
        for (var i = 0; i < tracks.length; i++)
          _item(
            tracks[i],
            i == startIndex
                ? extension.id
                : (enabledProviderIds.contains(
                      preferredOnlineProvider(tracks[i].source),
                    )
                    ? preferredOnlineProvider(tracks[i].source)!
                    : extension.id),
            quality,
            i,
            resolved: i == startIndex ? result : null,
          ),
      ];
      final player = container.read(musicPlayerControllerProvider);
      if (await player.ensureInitialized() == null) {
        notify('Internal audio player unavailable.');
        return;
      }
      await player.playAll(queue, initialIndex: startIndex);
      return;
    } catch (error) {
      if (isExtensionVerificationRequired(error)) {
        notify(
          'Provider verification is required. Complete the browser '
          'verification and try Play again.',
        );
        return;
      }
      failures.add('${extension.displayName}: $error');
    }
  }
  notify('Online playback failed: ${failures.join('; ')}');
}

Future<void> playOnline(BuildContext context, WidgetRef ref, Track track) =>
    playOnlineQueue(context, ref, [track]);

Future<void> chooseOnlineQuality(
  BuildContext context,
  WidgetRef ref,
  List<Track> queue, {
  int startIndex = 0,
}) async {
  final quality = await OnlineStreamSettings.choose(context);
  if (quality == null) return;
  await OnlineStreamSettings.save(quality);
  if (!context.mounted) return;
  await playOnlineQueue(
    context,
    ref,
    queue,
    startIndex: startIndex,
    qualityOverride: quality,
  );
}
