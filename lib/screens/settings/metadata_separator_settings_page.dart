import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/settings_group.dart';

class MetadataSeparatorSettingsPage extends ConsumerWidget {
  const MetadataSeparatorSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final separators = ref.watch(
      settingsProvider.select((s) => s.metadataSeparators),
    );
    final labels = {
      'artist': context.l10n.trackArtist,
      'album_artist': context.l10n.trackAlbumArtist,
      'composer': context.l10n.editMetadataFieldComposer,
      'genre': context.l10n.trackGenre,
    };
    return MornyeSettingsTheme(
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.metadataSeparators),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                child: Text(context.l10n.metadataSeparatorsDescription),
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  for (final (i, field) in MetadataSeparators.fields.indexed)
                    SettingsItem(
                      icon: field == 'genre'
                          ? Icons.category_outlined
                          : Icons.people_alt_outlined,
                      title: labels[field]!,
                      subtitle: separators.toJson()[field]!.isEmpty
                          ? context.l10n.metadataSeparatorSource
                          : formatMetadataTagValue(
                              '${labels[field]} A, ${labels[field]} B',
                              separators.toJson()[field]!,
                            ),
                      showDivider: i < MetadataSeparators.fields.length - 1,
                      onTap: () async {
                        final value =
                            await showAppScrollableBottomSheet<String>(
                              context: context,
                              title: labels[field]!,
                              builder: (_, controller) => _SeparatorPicker(
                                label: labels[field]!,
                                current: separators.toJson()[field]!,
                                scrollController: controller,
                              ),
                            );
                        if (value != null && context.mounted) {
                          ref
                              .read(settingsProvider.notifier)
                              .setMetadataSeparator(field, value);
                        }
                      },
                    ),
                ],
              ),
            ),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }
}

class _SeparatorPicker extends StatefulWidget {
  const _SeparatorPicker({
    required this.label,
    required this.current,
    required this.scrollController,
  });
  final String label;
  final String current;
  final ScrollController scrollController;

  @override
  State<_SeparatorPicker> createState() => _SeparatorPickerState();
}

class _SeparatorPickerState extends State<_SeparatorPicker> {
  static const _presets = ['', ', ', '; ', ' / '];
  late String? _selected = _presets.contains(widget.current)
      ? widget.current
      : null;
  late final _custom = TextEditingController(
    text: _selected == null ? widget.current : '',
  );

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = [
      context.l10n.metadataSeparatorSource,
      context.l10n.metadataSeparatorComma,
      context.l10n.metadataSeparatorSemicolon,
      context.l10n.metadataSeparatorSlash,
      context.l10n.metadataSeparatorCustom,
    ];
    final separator = _selected ?? _custom.text;
    final valid =
        _selected != null ||
        (separator.isNotEmpty &&
            MetadataSeparators.validSeparator(separator) == separator);
    final example = '${widget.label} A, ${widget.label} B';
    return SingleChildScrollView(
      controller: widget.scrollController,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsGroup(
              children: [
                for (var i = 0; i < labels.length; i++)
                  SettingsItem(
                    title: labels[i],
                    trailing:
                        (_selected ==
                            (i < _presets.length ? _presets[i] : null))
                        ? AppIcon(
                            Icons.check,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : const SizedBox.shrink(),
                    showDivider: i != labels.length - 1,
                    onTap: () => setState(() {
                      _selected = i < _presets.length ? _presets[i] : null;
                    }),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selected == null)
                    AppTextField(
                      controller: _custom,
                      maxLength: 16,
                      label: context.l10n.metadataSeparatorCustom,
                      errorText: valid || separator.isEmpty
                          ? null
                          : context.l10n.metadataSeparatorInvalid,
                      onChanged: (_) => setState(() {}),
                    ),
                  const SizedBox(height: 16),
                  AppContentCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.metadataSeparatorPreview,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            formatMetadataTagValue(
                              example,
                              valid ? separator : '',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ExpressiveButton(
                    onPressed: valid
                        ? () => Navigator.of(context).pop(separator)
                        : null,
                    child: Text(context.l10n.dialogSave),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
