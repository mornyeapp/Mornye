import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/settings/provider_priority_list_page.dart';

class ProviderPriorityPage extends StatelessWidget {
  const ProviderPriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderPriorityListPage(
      loadAllProviders: (ref) =>
          ref.read(extensionProvider.notifier).getAllDownloadProviders(),
      currentPriority: (ref) => ref.read(extensionProvider).providerPriority,
      save: (ref, priority) =>
          ref.read(extensionProvider.notifier).setProviderPriority(priority),
      title: (c) => c.l10n.providerPriorityTitle,
      description: (c) => c.l10n.providerPriorityDescription,
      infoText: (c) => c.l10n.providerPriorityInfo,
      savedSnackbar: (c) => c.l10n.snackbarProviderPrioritySaved,
    );
  }
}
