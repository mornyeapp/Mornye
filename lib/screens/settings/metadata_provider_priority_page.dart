import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/settings/provider_priority_list_page.dart';

class MetadataProviderPriorityPage extends StatelessWidget {
  const MetadataProviderPriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderPriorityListPage(
      loadAllProviders: (ref) =>
          ref.read(extensionProvider.notifier).getAllMetadataProviders(),
      currentPriority: (ref) =>
          ref.read(extensionProvider).metadataProviderPriority,
      save: (ref, priority) => ref
          .read(extensionProvider.notifier)
          .setMetadataProviderPriority(priority),
      title: (c) => c.l10n.metadataProviderPriorityTitle,
      description: (c) => c.l10n.metadataProviderPriorityDescription,
      infoText: (c) => c.l10n.metadataProviderPriorityInfo,
      savedSnackbar: (c) => c.l10n.snackbarMetadataProviderSaved,
    );
  }
}
