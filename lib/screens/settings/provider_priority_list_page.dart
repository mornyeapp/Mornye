import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/discard_changes_dialog.dart';
import 'package:mornye/widgets/priority_settings_scaffold.dart';
import 'package:mornye/widgets/reorderable_priority_item.dart';
import 'package:mornye/widgets/scaled_drag_proxy.dart';

/// Reorderable priority list shared by the download- and metadata-provider
/// priority pages; the two differ only in which provider list they read/write
/// and their labels, passed in as callbacks.
class ProviderPriorityListPage extends ConsumerStatefulWidget {
  final List<String> Function(WidgetRef ref) loadAllProviders;
  final List<String> Function(WidgetRef ref) currentPriority;
  final Future<void> Function(WidgetRef ref, List<String> priority) save;
  final String Function(BuildContext context) title;
  final String Function(BuildContext context) description;
  final String Function(BuildContext context) infoText;
  final String Function(BuildContext context) savedSnackbar;

  const ProviderPriorityListPage({
    super.key,
    required this.loadAllProviders,
    required this.currentPriority,
    required this.save,
    required this.title,
    required this.description,
    required this.infoText,
    required this.savedSnackbar,
  });

  @override
  ConsumerState<ProviderPriorityListPage> createState() =>
      _ProviderPriorityListPageState();
}

class _ProviderPriorityListPageState
    extends ConsumerState<ProviderPriorityListPage> {
  late List<String> _providers;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _loadProviders();
  }

  void _loadProviders() {
    final allProviders = widget.loadAllProviders(ref);
    final saved = widget.currentPriority(ref);

    if (saved.isNotEmpty) {
      _providers = List.from(saved);
      for (final provider in allProviders) {
        if (!_providers.contains(provider)) {
          _providers.add(provider);
        }
      }
      _providers.removeWhere((p) => !allProviders.contains(p));
    } else {
      _providers = allProviders;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PrioritySettingsScaffold(
      hasChanges: _hasChanges,
      title: widget.title(context),
      description: widget.description(context),
      descriptionPadding: const EdgeInsets.all(16),
      infoText: widget.infoText(context),
      onSave: _saveChanges,
      onConfirmDiscard: showDiscardChangesDialog,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: 16 + wideListInset(context),
          ),
          sliver: SliverReorderableList(
            proxyDecorator: ScaledDragProxy.plain,
            itemCount: _providers.length,
            itemBuilder: (context, index) {
              final provider = _providers[index];
              final extension = ref
                  .read(extensionProvider)
                  .extensions
                  .where((ext) => ext.id == provider)
                  .firstOrNull;
              return ReorderablePriorityItem(
                key: ValueKey(provider),
                index: index,
                isFirst: index == 0,
                isLast: index == _providers.length - 1,
                icon: Icons.extension,
                iconColor: Theme.of(context).colorScheme.secondary,
                name: extension?.displayName ?? provider,
                subtitle: context.l10n.providerExtension,
              );
            },
            onReorderItem: (oldIndex, newIndex) {
              setState(() {
                final item = _providers.removeAt(oldIndex);
                _providers.insert(newIndex, item);
                _hasChanges = true;
              });
            },
          ),
        ),
      ],
    );
  }

  Future<void> _saveChanges() async {
    await widget.save(ref, _providers);
    if (!mounted) return;
    setState(() {
      _hasChanges = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(widget.savedSnackbar(context))));
  }
}
