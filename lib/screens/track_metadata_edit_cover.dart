part of 'track_metadata_edit_sheet.dart';

extension _EditMetadataSheetCover on _EditMetadataSheetState {
  Future<void> _showCoverResolutionPicker() async {
    final currentValue = _coverMaxDimension ?? 0;
    final selectedValue = await _showEditorOptionPicker<int>(
      title: (sheetContext) => sheetContext.l10n.trackCoverResolution,
      options: (sheetContext) => [
        0,
        ..._EditMetadataSheetState._coverResizeDimensions,
      ],
      isSelected: (value) => value == currentValue,
      label: (sheetContext, value) => value == 0
          ? _originalCoverResolutionLabel(
              sheetContext.l10n.trackConvertOriginal,
            )
          : '$value px',
      icon: (sheetContext, value) => context.isMornye
          ? CupertinoIcons.photo
          : value == 0
          ? Icons.photo_size_select_actual_outlined
          : Icons.photo_size_select_large_outlined,
    );

    if (!mounted || selectedValue == null) return;
    _setState(() {
      _coverMaxDimension = selectedValue == 0 ? null : selectedValue;
    });
  }

  String _originalCoverResolutionLabel(String originalLabel) {
    final sourcePath = _selectedCoverPath ?? _currentCoverPath;
    final details = sourcePath == null ? null : _coverDetails[sourcePath];
    if (details == null) return originalLabel;
    return '$originalLabel · ${details.width} × ${details.height} px · '
        '${_formatCoverBytes(details.bytes)}';
  }

  String _formatCoverBytes(int bytes) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  Future<void> _loadCoverDetails(String path) async {
    if (_coverDetails.containsKey(path) || !_coverDetailLoads.add(path)) {
      return;
    }
    final details = await _covers.readDetails(path);
    if (!mounted) return;
    _setState(() {
      _coverDetailLoads.remove(path);
      final isActivePath =
          path == _currentCoverPath || path == _selectedCoverPath;
      if (isActivePath && details != null) {
        _coverDetails[path] = details;
      }
    });
  }

  String _resolveImageExtension(String? ext, Uint8List? bytes) {
    final normalized = (ext ?? '').toLowerCase();
    if (normalized == 'png' ||
        normalized == 'jpg' ||
        normalized == 'jpeg' ||
        normalized == 'webp') {
      return normalized == 'jpeg' ? 'jpg' : normalized;
    }
    if (bytes != null && bytes.length >= 8) {
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return 'png';
      }
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        return 'jpg';
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return 'webp';
      }
    }
    return 'jpg';
  }

  Future<void> _cleanupSelectedCoverTemp() async {
    final directory = _selectedCoverTempDir;
    final path = _selectedCoverPath;
    _selectedCoverPath = null;
    _selectedCoverTempDir = null;
    _selectedCoverName = null;
    _selectedMotionArtworkUrl = null;
    _coverDetails.remove(path);
    _coverDetailLoads.remove(path);
    await _covers.release(directory);
  }

  Future<void> _loadCurrentCoverPreview() async {
    if (_loadingCurrentCover) return;
    _setState(() => _loadingCurrentCover = true);
    final preview = await _covers.extract(widget.filePath);
    if (!mounted) return;
    final oldDirectory = _currentCoverTempDir;
    _coverDetails.remove(_currentCoverPath);
    _coverDetailLoads.remove(_currentCoverPath);
    _setState(() {
      _currentCoverPath = preview?.path;
      _currentCoverTempDir = preview?.tempDir;
      _loadingCurrentCover = false;
      if (preview?.details case final details?) {
        _coverDetails[preview!.path] = details;
      }
    });
    await _covers.release(oldDirectory);
  }

  Future<void> _pickCoverImage() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.image);
      if (picked == null || !mounted) return;
      final sourcePath = picked.path;
      final bytes = _hasValue(sourcePath) ? null : await picked.readAsBytes();
      if (!mounted) return;
      final extension = _resolveImageExtension(
        p.extension(picked.name).replaceFirst('.', ''),
        bytes,
      );
      final preview = await _covers.copyPicked(
        extension: extension,
        sourcePath: sourcePath,
        bytes: bytes,
      );
      if (!mounted) return;
      await _cleanupSelectedCoverTemp();
      if (!mounted) return;
      _setState(() {
        _selectedCoverPath = preview.path;
        _selectedCoverTempDir = preview.tempDir;
        _selectedCoverName = picked.name;
      });
      unawaited(_loadCoverDetails(preview.path));
    } catch (e) {
      if (!mounted) return;
      _showSheetSnackBar(context.l10n.snackbarError(context.friendlyError(e)));
    }
  }

  Widget _buildCoverEditor(ColorScheme cs) {
    final hasSelectedCover = _hasValue(_selectedCoverPath);
    final hasCurrentCover = _hasValue(_currentCoverPath);
    return MetadataEditorSectionCard(
      colorScheme: widget.colorScheme,
      icon: Icons.image_outlined,
      title: context.l10n.editMetadataFieldCover,
      children: [
        if (_loadingCurrentCover)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: AppProgressIndicator.linear(minHeight: 2),
          )
        else if (!hasCurrentCover && !hasSelectedCover)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              context.l10n.trackCoverNoEmbeddedArt,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: AppActionButton(
                outlined: true,
                glass: false,
                onPressed: _saving ? null : _pickCoverImage,
                icon: const Icon(Icons.image_outlined),
                label: Text(
                  hasSelectedCover
                      ? context.l10n.trackCoverReplace
                      : context.l10n.trackCoverPick,
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (hasSelectedCover) ...[
              const SizedBox(width: 8),
              AppIconButton(
                tooltip: context.l10n.trackCoverClearSelected,
                onPressed: _saving
                    ? null
                    : () async {
                        await _cleanupSelectedCoverTemp();
                        if (!mounted) return;
                        _setState(() {});
                      },
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        if (hasCurrentCover || hasSelectedCover) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (hasCurrentCover)
                Expanded(
                  child: _buildCoverPreviewTile(
                    cs: cs,
                    path: _currentCoverPath!,
                    label: context.l10n.trackCoverCurrent,
                  ),
                ),
              if (hasCurrentCover && hasSelectedCover)
                const SizedBox(width: 12),
              if (hasSelectedCover)
                Expanded(
                  child: _buildCoverPreviewTile(
                    cs: cs,
                    path: _selectedCoverPath!,
                    label:
                        _selectedCoverName ==
                            EditMetadataSheet._onlineCoverSentinel
                        ? context.l10n.trackCoverOnline
                        : (_selectedCoverName ??
                              context.l10n.trackCoverSelected),
                  ),
                ),
            ],
          ),
          if (hasSelectedCover) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.trackCoverReplaceNotice,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          MetadataEditorSelectionField(
            colorScheme: widget.colorScheme,
            label: context.l10n.trackCoverResolution,
            value: _coverMaxDimension == null
                ? _originalCoverResolutionLabel(
                    context.l10n.trackConvertOriginal,
                  )
                : '${_coverMaxDimension!} px',
            enabled: !_saving,
            onTap: _showCoverResolutionPicker,
          ),
          Text(
            context.l10n.trackCoverResolutionHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildCoverPreviewTile({
    required ColorScheme cs,
    required String path,
    required String label,
  }) {
    final details = _coverDetails[path];
    final loadingDetails = _coverDetailLoads.contains(path);
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(path),
              height: 160,
              width: 160,
              fit: BoxFit.cover,
              cacheWidth: (160 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              cacheHeight: (160 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) => Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.broken_image,
                  color: cs.onSurfaceVariant,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        if (details != null)
          Text(
            '${details.width} × ${details.height} px · '
            '${_formatCoverBytes(details.bytes)}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else if (loadingDetails)
          AppLoadingIndicator(size: 12, strokeWidth: 1.5, color: cs.primary),
      ],
    );
  }
}
