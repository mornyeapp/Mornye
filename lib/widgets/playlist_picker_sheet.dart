import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

final _log = AppLogger('PlaylistPicker');

Future<void> showAddTrackToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  return showAddTracksToPlaylistSheet(context, ref, [track]);
}

Future<void> showAddTracksToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  String? playlistNamePrefill,
  bool preserveOccurrences = false,
}) async {
  if (tracks.isEmpty) return;

  if (!context.mounted) return;

  await showAppModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: !context.isMornye,
    isScrollControlled: true,
    // The picker keeps its lighter glass tint.
    mornyeGlass: false,
    builder: (sheetContext) {
      final content = _PlaylistPickerSheetContent(
        tracks: tracks,
        playlistNamePrefill: playlistNamePrefill,
        preserveOccurrences: preserveOccurrences,
      );
      return sheetContext.isMornye
          ? MornyeGlassPanel(tintOpacity: 0.78, child: content)
          : content;
    },
  );
}

class _PlaylistPickerSheetContent extends ConsumerStatefulWidget {
  final List<Track> tracks;
  final String? playlistNamePrefill;
  final bool preserveOccurrences;

  const _PlaylistPickerSheetContent({
    required this.tracks,
    this.playlistNamePrefill,
    required this.preserveOccurrences,
  });

  @override
  ConsumerState<_PlaylistPickerSheetContent> createState() =>
      _PlaylistPickerSheetContentState();
}

class _PlaylistPickerSheetContentState
    extends ConsumerState<_PlaylistPickerSheetContent> {
  late final PlaylistPickerSummaryRequest _summaryRequest;
  final Set<String> _selectedPlaylistIds = {};
  final Set<String> _committedPlaylistIds = {};
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _summaryRequest = PlaylistPickerSummaryRequest.fromTracks(
      widget.tracks,
      preserveOccurrences: widget.preserveOccurrences,
    );
  }

  Future<void> _handleDone(List<PlaylistPickerSummary> playlists) async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final effectiveDisabledIds = <String>{
      ..._committedPlaylistIds,
      for (final playlist in playlists)
        if (playlist.containsAllRequestedTracks) playlist.id,
    };
    final idsToAdd = _selectedPlaylistIds.difference(effectiveDisabledIds);
    final playlistNamesById = {
      for (final playlist in playlists) playlist.id: playlist.name,
    };
    final addedNames = <String>[];

    try {
      for (final playlistId in idsToAdd) {
        await notifier.addTracksToPlaylist(
          playlistId,
          widget.tracks,
          preserveOccurrences: widget.preserveOccurrences,
        );
        _committedPlaylistIds.add(playlistId);
        final playlistName = playlistNamesById[playlistId];
        if (playlistName != null && playlistName.isNotEmpty) {
          addedNames.add(playlistName);
        }
      }
    } catch (error, stack) {
      _log.e('Failed to add tracks to selected playlists', error, stack);
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.friendlyError(error))));
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();

    if (addedNames.isNotEmpty) {
      final name = addedNames.length == 1
          ? addedNames.first
          : addedNames.join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.collectionAddedToPlaylist(name))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlistSummariesValue = ref.watch(
      libraryPlaylistPickerSummariesProvider(_summaryRequest),
    );
    final notifier = ref.read(libraryCollectionsProvider.notifier);

    final String subtitle;
    if (widget.tracks.length == 1) {
      final track = widget.tracks.first;
      subtitle = '${track.name} • ${track.artistName}';
    } else {
      subtitle = context.l10n.tracksCount(widget.tracks.length);
    }

    final resolvedPlaylists = playlistSummariesValue.asData?.value ?? const [];
    final effectiveDisabledIds = <String>{
      ..._committedPlaylistIds,
      for (final playlist in resolvedPlaylists)
        if (playlist.containsAllRequestedTracks) playlist.id,
    };
    final idsToAdd = _selectedPlaylistIds.difference(effectiveDisabledIds);
    final hasNewSelections = idsToAdd.isNotEmpty;

    void onDone() {
      if (_isSubmitting) return;
      if (hasNewSelections) {
        _handleDone(resolvedPlaylists);
      } else {
        setState(() => _isSubmitting = true);
        Navigator.of(context).pop();
      }
    }

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (context.isMornye) ...[
            const AppSheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.collectionAddToPlaylist,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: Text(context.l10n.collectionAddToPlaylist),
              subtitle: Text(subtitle),
            ),
          if (context.isMornye) const Divider(height: 1),
          ConnectedGroupRow(
            index: 0,
            count: 1,
            child: _PlaylistPickerRow(
              leading: Icon(
                context.isMornye
                    ? CupertinoIcons.add_circled
                    : Icons.add_circle_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(context.l10n.collectionCreatePlaylist),
              enabled: !_isSubmitting,
              onTap: () async {
                if (_isSubmitting) return;
                final name = await promptPlaylistName(
                  context,
                  title: context.l10n.collectionCreatePlaylist,
                  confirmLabel: context.l10n.actionCreate,
                  initialName: widget.playlistNamePrefill,
                  textInputAction: TextInputAction.done,
                  isDefault: true,
                );
                if (name == null || name.trim().isEmpty || !context.mounted) {
                  return;
                }
                final playlistId = await notifier.createPlaylist(name.trim());
                await notifier.addTracksToPlaylist(
                  playlistId,
                  widget.tracks,
                  preserveOccurrences: widget.preserveOccurrences,
                );
                if (!mounted) return;
                setState(() {
                  _committedPlaylistIds.add(playlistId);
                  _selectedPlaylistIds.remove(playlistId);
                });
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      context.l10n.collectionAddedToPlaylist(name.trim()),
                    ),
                  ),
                );
              },
            ),
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: playlistSummariesValue.when(
                data: (playlists) {
                  if (playlists.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: Text(
                        context.l10n.collectionNoPlaylistsYet,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    // Small lists hug their content; long lists scroll lazily.
                    shrinkWrap: playlists.length <= 8,
                    padding: EdgeInsets.only(top: context.isMornye ? 0 : 8),
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      final isAlreadyIn = effectiveDisabledIds.contains(
                        playlist.id,
                      );
                      final isSelected =
                          _selectedPlaylistIds.contains(playlist.id) ||
                          isAlreadyIn;

                      return ConnectedGroupRow(
                        index: index,
                        count: playlists.length,
                        child: _PlaylistPickerRow(
                          leading: _PlaylistPickerThumbnail(
                            playlist: playlist,
                            isSelected: !context.isMornye && isSelected,
                          ),
                          title: Text(playlist.name),
                          subtitle: Text(
                            context.l10n.collectionPlaylistTracks(
                              playlist.trackCount,
                            ),
                          ),
                          enabled: !isAlreadyIn && !_isSubmitting,
                          selected: isSelected,
                          onTap: !isAlreadyIn && !_isSubmitting
                              ? () {
                                  if (_isSubmitting) return;
                                  setState(() {
                                    if (_selectedPlaylistIds.contains(
                                      playlist.id,
                                    )) {
                                      _selectedPlaylistIds.remove(playlist.id);
                                    } else {
                                      _selectedPlaylistIds.add(playlist.id);
                                    }
                                  });
                                }
                              : null,
                        ),
                      );
                    },
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    heightFactor: 1,
                    child: AppLoadingIndicator(size: 24, strokeWidth: 2),
                  ),
                ),
                error: (_, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Text(
                    context.l10n.collectionNoPlaylistsYet,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: context.isMornye
                  ? AppActionButton(
                      onPressed: _isSubmitting ? null : onDone,
                      icon: const Icon(CupertinoIcons.checkmark),
                      label: Text(context.l10n.dialogDone),
                    )
                  : ExpressiveButton(
                      onPressed: _isSubmitting ? null : onDone,
                      child: Text(context.l10n.dialogDone),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a non-empty playlist name and returns it trimmed, or null when
/// the dialog is cancelled.
Future<String?> promptPlaylistName(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? initialName,
  TextInputAction? textInputAction,
  bool isDefault = false,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _PlaylistNameDialog(
      title: title,
      confirmLabel: confirmLabel,
      initialName: initialName,
      textInputAction: textInputAction,
      isDefault: isDefault,
    ),
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialName,
    required this.textInputAction,
    required this.isDefault,
  });

  final String title;
  final String confirmLabel;
  final String? initialName;
  final TextInputAction? textInputAction;
  final bool isDefault;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AppAlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: AppTextField(
          controller: _controller,
          autofocus: true,
          textInputAction: widget.textInputAction,
          hint: context.l10n.collectionPlaylistNameHint,
          validator: (value) {
            final trimmed = value?.trim() ?? '';
            if (trimmed.isEmpty) {
              return context.l10n.collectionPlaylistNameRequired;
            }
            return null;
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        AppDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          isDefault: widget.isDefault,
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _PlaylistPickerRow extends StatelessWidget {
  const _PlaylistPickerRow({
    required this.leading,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.selected,
    this.onTap,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final bool enabled;
  final bool? selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        enabled: enabled,
        onTap: onTap,
      );
    }
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            onPressed: enabled ? onTap : null,
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle(
                          style: theme.textTheme.bodyLarge!,
                          child: title,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 3),
                          DefaultTextStyle(
                            style: theme.textTheme.bodyMedium!.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            child: subtitle!,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (selected != null) ...[
                    const SizedBox(width: 14),
                    Icon(
                      selected!
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: 24,
                      color: selected!
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 0.5, thickness: 0.5, indent: 20, endIndent: 20),
        ],
      ),
    );
  }
}

class _PlaylistPickerThumbnail extends StatelessWidget {
  final PlaylistPickerSummary playlist;
  final bool isSelected;

  const _PlaylistPickerThumbnail({
    required this.playlist,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const double size = 48;
    final borderRadius = BorderRadius.circular(8);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: borderRadius,
            child: _buildCoverImage(context, colorScheme, size),
          ),
          if (isSelected) ...[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  borderRadius: borderRadius,
                ),
              ),
            ),
            PositionedDirectional(
              end: 2,
              top: 2,
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.primary, width: 1.5),
                ),
                child: Icon(
                  Icons.check,
                  color: colorScheme.onPrimary,
                  size: 14,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverImage(
    BuildContext context,
    ColorScheme colorScheme,
    double size,
  ) {
    final customCoverPath = playlist.coverImagePath;
    if (customCoverPath != null && customCoverPath.isNotEmpty) {
      return Image.file(
        File(customCoverPath),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        cacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => _iconFallback(context, colorScheme, size),
      );
    }

    Widget image(String? cover) => cover == null
        ? _iconFallback(context, colorScheme, size)
        : LocalOrNetworkCoverImage(
            url: cover,
            width: size,
            height: size,
            networkCacheWidth: (size * 2).toInt(),
            placeholder: (_) => _iconFallback(context, colorScheme, size),
          );

    final firstCoverUrl = playlist.previewCover;
    if (collectionCoverIsPortable(firstCoverUrl) || playlist.trackCount == 0) {
      return image(firstCoverUrl);
    }
    // As the Library's playlist tiles: the Library answers a cover this
    // device cannot load from the first song's stored path.
    return Consumer(
      builder: (context, ref, _) => image(
        ref
            .watch(
              playlistCoverProvider((
                id: playlist.id,
                cover: firstCoverUrl,
                updatedAt: null,
              )),
            )
            .maybeWhen(data: (cover) => cover, orElse: () => firstCoverUrl),
      ),
    );
  }

  Widget _iconFallback(
    BuildContext context,
    ColorScheme colorScheme,
    double size,
  ) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        context.isMornye ? CupertinoIcons.music_note_list : Icons.queue_music,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
