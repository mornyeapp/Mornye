import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/settings_group.dart';

class ProfileSettingsPage extends ConsumerStatefulWidget {
  const ProfileSettingsPage({super.key, required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<ProfileSettingsPage> createState() =>
      _ProfileSettingsPageState();
}

class _ProfileSettingsPageState extends ConsumerState<ProfileSettingsPage> {
  late final _name = TextEditingController(text: widget.profile.name);
  Uint8List? _photo;
  bool _removePhoto = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.image,
        darwinOptions: const DarwinOptions(
          assetRepresentationMode: DarwinAssetRepresentationMode.compatible,
        ),
      );
      if (picked == null) return;
      if ((await picked.length() ?? 0) > 20 * 1024 * 1024) {
        throw const FormatException('Photo too large');
      }
      final bytes = await picked.readAsBytes();
      final photo = await prepareProfilePhoto(bytes);
      if (!mounted) return;
      setState(() {
        _photo = photo;
        _removePhoto = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.profilePhotoError)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      await ref
          .read(userProfileProvider.notifier)
          .save(name: _name.text, photo: _photo, removePhoto: _removePhoto);
      // In the desktop Settings detail pane the page is the pane's only
      // route and stays open.
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.profileSaveError)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = wideListInset(context);
    final hasPhoto =
        _photo != null || (!_removePhoto && widget.profile.photoPath != null);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.profileTitle),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(24 + inset, 16, 24 + inset, 32),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _name,
                        builder: (context, value, _) => ProfileAvatar(
                          name: value.text,
                          photo: _photo,
                          photoPath: _removePhoto
                              ? null
                              : widget.profile.photoPath,
                          size: 128,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: AppActionButton(
                        onPressed: _busy ? null : _pickPhoto,
                        icon: const AppIcon(Icons.photo_library_outlined),
                        label: Text(context.l10n.profileChangePhoto),
                        outlined: true,
                        tonal: true,
                      ),
                    ),
                    if (hasPhoto)
                      Center(
                        child: ExpressiveButton(
                          text: true,
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _photo = null;
                                  _removePhoto = true;
                                }),
                          child: Text(context.l10n.profileRemovePhoto),
                        ),
                      ),
                    const SizedBox(height: 24),
                    SettingsGroup(
                      margin: EdgeInsets.zero,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: TextField(
                            controller: _name,
                            enabled: !_busy,
                            maxLength: 50,
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _busy ? null : _save(),
                            decoration: InputDecoration(
                              labelText: context.l10n.profileName,
                              hintText: context.l10n.profileNameHint,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              counterText: '',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    AppActionButton(
                      onPressed: _busy ? null : _save,
                      icon: _busy
                          ? const AppLoadingIndicator(size: 20, strokeWidth: 2)
                          : const AppIcon(Icons.check),
                      label: Text(context.l10n.dialogSave),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
            ),
          ],
        ),
      ),
    );
  }
}
