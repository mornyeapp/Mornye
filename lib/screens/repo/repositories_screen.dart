import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoIcons, CupertinoTextField;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/repo_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/settings_group.dart';

/// The store's repositories in order: each row names the repository, its
/// link, and its extension count or why it did not load, with a remove
/// button. A last group adds another repository.
class RepositoriesScreen extends ConsumerWidget {
  const RepositoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urls = ref.watch(repoProvider.select((s) => s.registryUrls));
    final sources = ref.watch(repoProvider.select((s) => s.sources));
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    RepoSource? sourceFor(String url) {
      for (final source in sources) {
        if (source.registryUrl == url) return source;
      }
      return null;
    }

    return MornyeSettingsTheme(
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: l10n.storeRepositoriesTitle),
            if (urls.isNotEmpty)
              SliverToBoxAdapter(
                child: SettingsGroup(
                  children: [
                    for (final (index, url) in urls.indexed)
                      Builder(
                        builder: (context) {
                          final source = sourceFor(url);
                          final name = source?.name ?? url;
                          return SettingsItem(
                            key: ValueKey('repository-$url'),
                            title: name,
                            subtitle: url,
                            showDivider: index < urls.length - 1,
                            footer: source == null
                                ? null
                                : Text(
                                    source.hasError
                                        ? context.friendlyError(source.error)
                                        : l10n.storeExtensionsCount(
                                            source.extensionCount,
                                          ),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: source.hasError
                                              ? colorScheme.error
                                              : colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                            trailing: AppIconButton(
                              tooltip: l10n.storeRemoveRepoTooltip,
                              icon: Icon(
                                context.isMornye
                                    ? CupertinoIcons.minus_circle
                                    : Icons.remove_circle_outline,
                                color: colorScheme.error,
                              ),
                              onPressed: () =>
                                  _confirmRemove(context, ref, url, name),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    key: const ValueKey('repository-add'),
                    icon: Icons.add,
                    showIconInMornye: true,
                    iconColor: colorScheme.primary,
                    title: l10n.storeAddRepoButton,
                    trailing: const SizedBox.shrink(),
                    showDivider: false,
                    onTap: () => showAddRepositoryDialog(context),
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

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    String url,
    String name,
  ) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.storeRemoveRepoTooltip,
      message: context.l10n.storeRemoveRepoMessage(name),
      confirmLabel: context.l10n.dialogRemove,
      destructive: true,
      filled: false,
      cancelIsDefault: true,
      errorConfirm: true,
    );
    if (confirmed) {
      await ref.read(repoProvider.notifier).removeRegistryUrl(url);
    }
  }
}

/// Asks for a repository link and adds it. The dialog stays open while the
/// repository loads and shows why it could not be added.
Future<void> showAddRepositoryDialog(BuildContext context) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => const _AddRepositoryDialog(),
    );

class _AddRepositoryDialog extends ConsumerStatefulWidget {
  const _AddRepositoryDialog();

  @override
  ConsumerState<_AddRepositoryDialog> createState() =>
      _AddRepositoryDialogState();
}

class _AddRepositoryDialogState extends ConsumerState<_AddRepositoryDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _controller.text.trim();
    if (url.isEmpty || ref.read(repoProvider).isAddingRepository) return;
    setState(() => _error = null);
    final result = await ref.read(repoProvider.notifier).addRegistryUrl(url);
    if (!mounted) return;
    switch (result.status) {
      case RepoAddStatus.added:
        Navigator.of(context).pop();
      case RepoAddStatus.duplicate:
        setState(() => _error = context.l10n.storeRepoAlreadyAdded);
      case RepoAddStatus.failed:
        setState(() => _error = context.friendlyError(result.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final adding = ref.watch(repoProvider.select((s) => s.isAddingRepository));
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return AppAlertDialog(
      title: Text(l10n.storeAddRepoTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (context.isMornye) ...[
            CupertinoTextField(
              key: const ValueKey('repository-url-field'),
              controller: _controller,
              placeholder: l10n.storeRepoUrlHint,
              keyboardType: TextInputType.url,
              autocorrect: false,
              autofocus: true,
              enabled: !adding,
              padding: const EdgeInsets.all(12),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
              ),
            ],
          ] else
            AppTextField(
              key: const ValueKey('repository-url-field'),
              controller: _controller,
              outlined: true,
              autofocus: true,
              label: l10n.storeRepoUrlLabel,
              hint: l10n.storeRepoUrlHint,
              leading: const Icon(Icons.link),
              errorText: _error,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onSubmitted: (_) => _submit(),
            ),
        ],
      ),
      actions: [
        AppDialogAction(
          onPressed: adding ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          isDefault: true,
          onPressed: adding ? null : _submit,
          child: adding
              ? const AppLoadingIndicator(size: 20)
              : Text(l10n.storeAddRepoButton),
        ),
      ],
    );
  }
}
