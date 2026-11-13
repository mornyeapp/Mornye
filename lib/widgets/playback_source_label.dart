import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/link_source_names.dart';
import 'package:mornye/services/network_storage_service.dart';

final _sourceNameProvider = FutureProvider.family<String?, String>((
  ref,
  id,
) async {
  try {
    return (await NetworkStorageService.instance.connection(id)).name;
  } catch (_) {
    return null;
  }
});

/// Average encoded bitrate from the full HTTP Content-Length, not a guessed
/// PCM bitrate. FLAC is variable-bit-rate; this is a file-wide average only.
final _onlineAverageKbpsProvider =
    FutureProvider.family<int?, ({String url, int seconds})>((
      ref,
      request,
    ) async {
      if (request.seconds <= 0) return null;
      final uri = Uri.tryParse(request.url);
      if (uri?.scheme != 'https') return null;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final head = await client
            .openUrl('HEAD', uri!)
            .timeout(const Duration(seconds: 6));
        final response = await head.close().timeout(const Duration(seconds: 6));
        final length = response.contentLength;
        if (response.statusCode != HttpStatus.ok || length < 128 * 1024) {
          return null;
        }
        return (length * 8 / request.seconds / 1000).round();
      } catch (_) {
        return null;
      } finally {
        client.close(force: true);
      }
    });

/// Describes the file actually opened, including an offline copy preferred
/// over a network source already in the queue.
class PlaybackSourceLabel extends ConsumerWidget {
  const PlaybackSourceLabel({super.key, required this.item, this.color});
  final MediaItem item;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = item.extras?['source']?.toString() ?? '';
    if (item.id.startsWith('online:')) {
      final extras = item.extras ?? const <String, dynamic>{};
      final resolved =
          extras['resolvedSource']?.toString() ??
          (source.startsWith('https://') ? source : '');
      int? positive(Object? raw) {
        final number = raw is num ? raw.toInt() : int.tryParse('$raw');
        return number != null && number > 0 ? number : null;
      }

      final bits = positive(extras['bit_depth']);
      final sample = positive(extras['sample_rate']);
      final providerBitrate = positive(extras['bitrate']);
      final average = resolved.isNotEmpty && item.duration != null
          ? ref
                .watch(
                  _onlineAverageKbpsProvider((
                    url: resolved,
                    seconds: item.duration!.inSeconds,
                  )),
                )
                .value
          : null;
      final parts = <String>[
        'Online · ${extras['format'] ?? 'FLAC'}',
        if (bits != null) '$bits-bit',
        if (sample != null) '${sample / 1000} kHz',
        if (average != null)
          '≈$average kbps avg'
        else if (providerBitrate != null)
          '${(providerBitrate / 1000).round()} kbps (provider)'
        else
          'bitrate unavailable',
      ];
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          parts.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      );
    }
    final origin = item.extras?['originSource']?.toString();
    final network = source.startsWith('network://') ? source : origin;
    if (network == null) return const SizedBox.shrink();
    final resolved = item.extras?['resolvedSource']?.toString() ?? source;
    final local = !const {
      'network',
      'http',
      'https',
    }.contains(Uri.tryParse(resolved)?.scheme);
    var label = context.l10n.offlinePlayingLocal;
    if (!local) {
      final host = Uri.tryParse(network)?.host ?? '';
      final name =
          ref.watch(linkSourceNamesProvider)[host] ??
          ref.watch(_sourceNameProvider(host)).value ??
          host;
      label = context.l10n.offlineStreaming(name);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
