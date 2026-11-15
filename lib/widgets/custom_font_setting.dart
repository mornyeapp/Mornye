import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/custom_font_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

class CustomFontSetting extends ConsumerStatefulWidget {
  const CustomFontSetting({super.key});

  @override
  ConsumerState<CustomFontSetting> createState() => _CustomFontSettingState();
}

class _CustomFontSettingState extends ConsumerState<CustomFontSetting> {
  bool _importing = false;

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['ttf', 'otf'],
      );
      if (file == null || !mounted) return;
      if ((await file.length() ?? 0) > CustomFontService.maxBytes) {
        throw const FormatException('Font exceeds import limit');
      }
      final id = await CustomFontService.instance.import(
        await file.readAsBytes(),
      );
      if (!mounted) return;
      await ref.read(themeProvider.notifier).setCustomFont(id, file.name);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.appearanceCustomFontInvalid)),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    return ListTile(
      leading: context.isMornye ? null : const Icon(Icons.text_fields),
      title: Text(context.l10n.appearanceCustomFont),
      subtitle: Text(
        theme.customFontId.isEmpty
            ? context.l10n.appearanceCustomFontSubtitle
            : theme.customFontName,
      ),
      onTap: _importing ? null : _import,
      trailing: _importing
          ? const AppLoadingIndicator(size: 24, strokeWidth: 2)
          : theme.customFontId.isEmpty
          ? const Icon(Icons.add)
          : AppIconButton(
              tooltip: context.l10n.appearanceCustomFontReset,
              onPressed: () =>
                  ref.read(themeProvider.notifier).setCustomFont('', ''),
              icon: const Icon(Icons.close),
            ),
    );
  }
}
