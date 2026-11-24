import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/cross_extension_share_service.dart';
import 'package:mornye/services/share_intent_service.dart';

class CrossExtensionShareSheet extends ConsumerStatefulWidget {
  final String name;
  final String artists;
  final String type;
  final String sourceExtensionId;

  const CrossExtensionShareSheet({
    super.key,
    required this.name,
    required this.artists,
    required this.type,
    required this.sourceExtensionId,
  });

  static Future<void> show(
    BuildContext context, {
    required String name,
    required String artists,
    required String type,
    required String sourceExtensionId,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showAppBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: context.l10n.openInOtherServices,
      subtitle: artists.isNotEmpty ? '$name - $artists' : name,
      maxHeightFactor: 0.82,
      builder: (_) => CrossExtensionShareSheet(
        name: name,
        artists: artists,
        type: type,
        sourceExtensionId: sourceExtensionId,
      ),
    );
  }

  @override
  ConsumerState<CrossExtensionShareSheet> createState() =>
      _CrossExtensionShareSheetState();
}

class _CrossExtensionShareSheetState
    extends ConsumerState<CrossExtensionShareSheet> {
  late final Future<List<CrossExtensionShareResult>> _future;

  @override
  void initState() {
    super.initState();
    _future = const CrossExtensionShareService()
        .findAcrossExtensions(
          name: widget.name,
          artists: widget.artists,
          type: widget.type,
          sourceExtensionId: widget.sourceExtensionId,
        )
        .then((results) {
          final sorted = [...results];
          sorted.sort((a, b) {
            if (a.found != b.found) return a.found ? -1 : 1;
            return a.displayName.compareTo(b.displayName);
          });
          return sorted;
        });
  }

  String? _iconPathFor(String extensionId) {
    if (extensionId.isEmpty) return null;
    final extensions = ref.read(extensionProvider).extensions;
    for (final ext in extensions) {
      if (ext.id == extensionId) {
        final path = ext.iconPath;
        return (path != null && path.isNotEmpty) ? path : null;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return FutureBuilder<List<CrossExtensionShareResult>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 180,
            child: Center(child: AppLoadingIndicator()),
          );
        }

        final results = snapshot.data ?? const [];
        if (results.isEmpty) {
          return SizedBox(
            height: 180,
            child: Center(
              child: Text(
                context.l10n.shareSheetNoExtensions,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16, top: 4),
          itemBuilder: (context, index) {
            final result = results[index];
            return _CrossExtensionShareTile(
              result: result,
              iconPath: _iconPathFor(result.extensionId),
            );
          },
          itemCount: results.length,
        );
      },
    );
  }
}

class _CrossExtensionShareTile extends StatelessWidget {
  final CrossExtensionShareResult result;
  final String? iconPath;

  const _CrossExtensionShareTile({required this.result, this.iconPath});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final url = result.url;
    final hasUrl = result.found && url != null && url.isNotEmpty;

    final tile = AppSheetOption(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildIcon(context, colorScheme),
      ),
      title: Text(
        result.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        hasUrl
            ? (result.itemName?.isNotEmpty == true ? result.itemName! : url)
            : context.l10n.shareSheetNotFound,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: hasUrl
          ? AppIconButton(
              tooltip: context.l10n.shareSheetCopyLink,
              icon: const Icon(Icons.copy_rounded, size: 20),
              color: colorScheme.onSurfaceVariant,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      context.l10n.shareSheetLinkCopied(result.displayName),
                    ),
                  ),
                );
              },
            )
          : null,
      onTap: hasUrl
          ? () {
              Navigator.pop(context);
              ShareIntentService().injectUrl(url);
            }
          : null,
    );

    if (hasUrl) return tile;
    return Opacity(opacity: 0.5, child: tile);
  }

  Widget _buildIcon(BuildContext context, ColorScheme colorScheme) {
    final fallbackIcon = Icon(
      Icons.extension_rounded,
      color: colorScheme.onSurfaceVariant,
    );

    final path = iconPath;
    if (path == null) return fallbackIcon;

    return Image.file(
      File(path),
      width: 44,
      height: 44,
      fit: BoxFit.cover,
      cacheWidth: (44 * MediaQuery.devicePixelRatioOf(context)).round(),
      cacheHeight: (44 * MediaQuery.devicePixelRatioOf(context)).round(),
      filterQuality: FilterQuality.low,
      errorBuilder: (_, _, _) => fallbackIcon,
    );
  }
}
