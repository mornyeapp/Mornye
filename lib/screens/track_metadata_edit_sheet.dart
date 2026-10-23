import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/controllers/metadata_editor_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_autofill_service.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/lyrics_provider_picker.dart';
import 'package:mornye/widgets/metadata_candidate_tile.dart';
import 'package:mornye/widgets/metadata_editor_fields.dart';
import 'package:mornye/widgets/metadata_text_field.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

part 'track_metadata_edit_autofill.dart';
part 'track_metadata_edit_cover.dart';

final _log = AppLogger('MetadataEditor');

class EditMetadataSheet extends StatefulWidget {
  static const _onlineCoverSentinel = '__online_cover__';
  final ColorScheme colorScheme;
  final Map<String, String> initialValues;
  final String filePath;
  final String? sourceTrackId;
  final int durationMs;
  final String artistTagMode;

  const EditMetadataSheet({
    super.key,
    required this.colorScheme,
    required this.initialValues,
    required this.filePath,
    this.sourceTrackId,
    required this.durationMs,
    required this.artistTagMode,
  });

  @override
  State<EditMetadataSheet> createState() => _EditMetadataSheetState();
}

class _EditMetadataSheetState extends State<EditMetadataSheet> {
  static const _coverResizeDimensions = <int>[500, 1000, 1500, 2000, 3000];

  bool _saving = false;
  final _covers = MetadataCoverResources();
  late final _persistence = MetadataPersistenceService(covers: _covers);
  final _autofill = MetadataAutofillService();
  bool _showAdvanced = false;
  bool _showAutoFill = false;
  bool _fetching = false;
  String? _selectedCoverPath;
  String? _selectedCoverTempDir;
  String? _selectedCoverName;
  String? _currentCoverPath;
  String? _currentCoverTempDir;
  bool _loadingCurrentCover = false;
  int? _coverMaxDimension;
  final Map<String, ({int width, int height, int bytes})> _coverDetails = {};
  final Set<String> _coverDetailLoads = {};
  String? _selectedMetadataProviderId;
  _AutoFillPreview? _autoFillPreview;
  final GlobalKey<ScaffoldMessengerState> _sheetMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// setState is @protected, so the extension part files route rebuilds
  /// through this forwarder.
  void _setState(VoidCallback fn) => setState(fn);

  Future<T?> _showEditorOptionPicker<T>({
    required String Function(BuildContext sheetContext) title,
    required List<T> Function(BuildContext sheetContext) options,
    required bool Function(T option) isSelected,
    required String Function(BuildContext sheetContext, T option) label,
    required IconData Function(BuildContext sheetContext, T option) icon,
    bool ellipsizeLabels = false,
    bool checkInSheetTheme = false,
  }) {
    FocusScope.of(context).unfocus();
    return showAppModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: !context.isMornye,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        final items = options(sheetContext);

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The glass carries the handle that Material's sheet draws.
                if (sheetContext.isMornye) const AppSheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    title(sheetContext),
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: MetadataEditorOptions(
                      children: [
                        for (var index = 0; index < items.length; index++)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 4,
                                ),
                                leading: Icon(
                                  icon(sheetContext, items[index]),
                                  color: isSelected(items[index])
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                                title: Text(
                                  label(sheetContext, items[index]),
                                  maxLines: ellipsizeLabels ? 2 : null,
                                  overflow: ellipsizeLabels
                                      ? TextOverflow.ellipsis
                                      : null,
                                ),
                                selected: isSelected(items[index]),
                                selectedColor: cs.primary,
                                trailing: isSelected(items[index])
                                    ? Icon(
                                        (checkInSheetTheme
                                                    ? sheetContext
                                                    : context)
                                                .isMornye
                                            ? CupertinoIcons.checkmark
                                            : Icons.check_rounded,
                                      )
                                    : null,
                                onTap: () =>
                                    Navigator.pop(sheetContext, items[index]),
                              ),
                              if (index != items.length - 1)
                                Divider(
                                  height: 1,
                                  indent: 60,
                                  endIndent: 20,
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.3,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSheetSnackBar(String message) {
    final snackBar = SnackBar(content: Text(message));
    final messenger = _sheetMessengerKey.currentState;
    if (messenger != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(snackBar);
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(snackBar);
  }

  late final MetadataEditorController _form;
  bool _fetchingMusicBrainz = false;

  /// Lets the user compare every enabled lyrics provider's result and puts
  /// the chosen lyrics in the field (saved with the other edits).
  Future<void> _findLyricsOnline() async {
    final title = _form['title']!.text.trim();
    final artist = primaryArtistName(
      _form['artist']!.text.trim(),
      albumArtist: _form['album_artist']!.text.trim(),
    );
    if (title.isEmpty || artist.isEmpty) {
      _showSheetSnackBar(context.l10n.lyricsPickerNeedsTitle);
      return;
    }
    // The backend's provider list follows the lyrics settings.
    await ProviderScope.containerOf(
      context,
      listen: false,
    ).read(settingsProvider.notifier).syncLyricsSettingsToBackend();
    if (!mounted) return;
    final lyrics = await showLyricsProviderPicker(
      context,
      title: title,
      artist: artist,
      spotifyId: widget.sourceTrackId ?? '',
      durationMs: widget.durationMs,
    );
    if (!mounted || lyrics == null) return;
    setState(() => _form['lyrics']!.text = lyrics);
  }

  bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

  String _fieldLabel(String key) {
    final l10n = context.l10n;
    return switch (key) {
      'title' => l10n.editMetadataFieldTitle,
      'artist' => l10n.editMetadataFieldArtist,
      'album' => l10n.editMetadataFieldAlbum,
      'album_artist' => l10n.editMetadataFieldAlbumArtist,
      'date' => l10n.editMetadataFieldDate,
      'track_number' => l10n.editMetadataFieldTrackNum,
      'total_tracks' => l10n.editMetadataFieldTrackTotal,
      'disc_number' => l10n.editMetadataFieldDiscNum,
      'total_discs' => l10n.editMetadataFieldDiscTotal,
      'genre' => l10n.editMetadataFieldGenre,
      'isrc' => l10n.editMetadataFieldIsrc,
      'lyrics' => l10n.trackLyrics,
      'label' => l10n.editMetadataFieldLabel,
      'copyright' => l10n.editMetadataFieldCopyright,
      'composer' => l10n.editMetadataFieldComposer,
      'comment' => l10n.editMetadataFieldComment,
      'album_type' => l10n.trackAlbumType,
      'explicit' => l10n.editMetadataFieldExplicit,
      'upc' => l10n.editMetadataFieldUpc,
      'cover' => l10n.editMetadataFieldCover,
      _ => key,
    };
  }

  @override
  void initState() {
    super.initState();
    _form = MetadataEditorController(widget.initialValues);
    unawaited(_loadCurrentCoverPreview());
  }

  @override
  void dispose() {
    unawaited(_covers.dispose());
    _form.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _fetching || _fetchingMusicBrainz) return;
    setState(() => _saving = true);
    try {
      final result = await _persistence.save(
        MetadataSaveRequest(
          filePath: widget.filePath,
          metadata: _form.saveMetadata(artistTagMode: widget.artistTagMode),
          artistTagMode: widget.artistTagMode,
          selectedCoverPath: _selectedCoverPath,
          currentCoverPath: _currentCoverPath,
          coverMaxDimension: _coverMaxDimension,
        ),
      );
      if (!mounted) return;
      if (result.failure == null) {
        Navigator.pop(context, true);
        return;
      }
      final l10n = context.l10n;
      _showSheetSnackBar(switch (result.failure!) {
        MetadataSaveFailure.backend => context.friendlyError(
          result.error,
          fallback: l10n.metadataSaveFailedFfmpeg,
        ),
        MetadataSaveFailure.ffmpeg => l10n.metadataSaveFailedFfmpeg,
        MetadataSaveFailure.storage => l10n.metadataSaveFailedStorage,
        MetadataSaveFailure.noCover => l10n.snackbarError(
          l10n.trackCoverNoEmbeddedArt,
        ),
        MetadataSaveFailure.resize => l10n.snackbarError(
          l10n.trackCoverResizeFailed,
        ),
        MetadataSaveFailure.unexpected => l10n.snackbarError(
          context.friendlyError(result.error),
        ),
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => AppScaffoldMessenger(
          key: _sheetMessengerKey,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: const AppSheetHandle(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.trackEditMetadata,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (_saving)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: context.isMornye
                                ? const CupertinoActivityIndicator()
                                : const AppLoadingIndicator(
                                    size: 22,
                                    strokeWidth: 2,
                                  ),
                          ),
                        )
                      else
                        AppActionButton(
                          onPressed: _fetching || _fetchingMusicBrainz
                              ? null
                              : _save,
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(context.l10n.dialogSave),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                    children: [
                      _buildCoverEditor(cs),
                      _buildAutoFillSection(cs),
                      MetadataEditorSectionCard(
                        colorScheme: widget.colorScheme,
                        icon: Icons.info_outline,
                        title: context.l10n.trackMetadata,
                        children: [
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldTitle,
                            _form['title']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldArtist,
                            _form['artist']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldAlbum,
                            _form['album']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldAlbumArtist,
                            _form['album_artist']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldDate,
                            _form['date']!,
                            hint: context.l10n.editMetadataFieldDateHint,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldTrackNum,
                                  _form['track_number']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldTrackTotal,
                                  _form['total_tracks']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldDiscNum,
                                  _form['disc_number']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldDiscTotal,
                                  _form['total_discs']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldGenre,
                            _form['genre']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldIsrc,
                            _form['isrc']!,
                          ),
                        ],
                      ),
                      MetadataEditorSectionCard(
                        colorScheme: widget.colorScheme,
                        icon: Icons.lyrics_outlined,
                        title: context.l10n.trackLyrics,
                        children: [
                          MetadataTextField(
                            cs,
                            context.l10n.trackLyrics,
                            _form['lyrics']!,
                            maxLines: 8,
                            keyboard: TextInputType.multiline,
                          ),
                          SizedBox(
                            width: double.infinity,
                            child: AppActionButton(
                              key: const ValueKey('find-lyrics-online'),
                              outlined: true,
                              glass: false,
                              tonal: true,
                              onPressed: _fetching || _saving
                                  ? null
                                  : _findLyricsOnline,
                              style: OutlinedButton.styleFrom(
                                backgroundColor: cs.surfaceContainerHigh,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(Icons.manage_search),
                              label: Text(
                                context.l10n.editMetadataLyricsSearch,
                              ),
                            ),
                          ),
                        ],
                      ),
                      MetadataEditorSectionCard(
                        colorScheme: widget.colorScheme,
                        icon: Icons.tune,
                        title: context.l10n.editMetadataAdvanced,
                        onHeaderTap: () =>
                            setState(() => _showAdvanced = !_showAdvanced),
                        expanded: _showAdvanced,
                        children: [
                          if (_showAdvanced) ...[
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldLabel,
                              _form['label']!,
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldCopyright,
                              _form['copyright']!,
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldComposer,
                              _form['composer']!,
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.trackAlbumType,
                              _form['album_type']!,
                              hint: context.l10n.editMetadataFieldAlbumTypeHint,
                            ),
                            MetadataEditorSwitchField(
                              colorScheme: widget.colorScheme,
                              label: context.l10n.editMetadataFieldExplicit,
                              subtitle:
                                  context.l10n.editMetadataFieldExplicitHint,
                              value: _form.explicit,
                              onChanged: (value) =>
                                  setState(() => _form.explicit = value),
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldUpc,
                              _form['upc']!,
                              hint: context.l10n.editMetadataFieldUpcHint,
                              keyboard: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(18),
                              ],
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldComment,
                              _form['comment']!,
                              maxLines: 3,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
