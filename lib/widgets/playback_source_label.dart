import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:material_ui/material_ui.dart';
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

/// Describes the file actually opened, including an offline copy preferred
/// over a network source already in the queue.
class PlaybackSourceLabel extends ConsumerWidget {
  const PlaybackSourceLabel({
    super.key,
    required this.item,
    this.color,
    this.style,
    this.padding = const EdgeInsets.only(top: 4),
  });
  final MediaItem item;
  final Color? color;

  /// The text style, drawn in [color]; `labelSmall` by default.
  final TextStyle? style;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = item.extras?['source']?.toString() ?? '';
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
      padding: padding,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (style ?? Theme.of(context).textTheme.labelSmall)?.copyWith(
          color: color,
        ),
      ),
    );
  }
}
