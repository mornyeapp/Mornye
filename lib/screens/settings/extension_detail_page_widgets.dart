part of 'extension_detail_page.dart';

class _ExtensionOverviewSurface extends StatelessWidget {
  const _ExtensionOverviewSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: const EdgeInsets.all(20), child: child);
    if (context.isMornye) {
      // The card scrolls over the plain page background, so a backdrop pass
      // would only filter a flat color.
      return MornyeGlassPanel(samplesBackdrop: false, child: content);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: content,
    );
  }
}

class _ExtensionDivider extends StatelessWidget {
  const _ExtensionDivider({this.indent = 56});

  final double indent;

  @override
  Widget build(BuildContext context) => settingsRowsConnected(context)
      ? const SizedBox.shrink()
      : Divider(
          height: 1,
          indent: indent,
          endIndent: 16,
          color: context.isMornye
              ? MornyeTheme.metadataDividerColor(context)
              : Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.3),
        );
}

/// Long OAuth URLs: selectable text so users can copy without relying on snackbars.
class _OauthLoginLinkPreview extends StatelessWidget {
  final String? value;
  final ColorScheme colorScheme;

  const _OauthLoginLinkPreview({
    required this.value,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return Text(
        context.l10n.extensionOauthConnectHint,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return SelectionArea(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.primary,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isError;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isError ? colorScheme.error : colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool enabled;
  final bool showDivider;
  final String? subtitle;

  const _CapabilityItem({
    required this.icon,
    required this.title,
    required this.enabled,
    this.showDivider = true,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              AppIcon(
                context.adaptiveIcon(icon),
                color: context.isMornye || enabled
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    if (subtitle != null && enabled) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AppIcon(
                context.isMornye
                    ? (enabled
                          ? CupertinoIcons.check_mark_circled_solid
                          : CupertinoIcons.xmark_circle)
                    : (enabled ? Icons.check_circle : Icons.cancel_outlined),
                color: context.isMornye || enabled
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(),
      ],
    );
  }
}

String _healthStatusLabel(BuildContext context, String status) {
  switch (status) {
    case 'online':
      return context.l10n.extensionHealthOnline;
    case 'degraded':
      return context.l10n.extensionHealthDegraded;
    case 'offline':
      return context.l10n.extensionHealthOffline;
    case 'unsupported':
      return context.l10n.extensionHealthNotConfigured;
    default:
      return context.l10n.extensionHealthUnknown;
  }
}

class _HealthSummaryItem extends StatelessWidget {
  final ExtensionHealthStatus? status;
  final bool isRefreshing;
  final VoidCallback onRefresh;

  const _HealthSummaryItem({
    required this.status,
    required this.isRefreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusValue = status?.status ?? 'unknown';
    final color = extensionHealthColor(context, statusValue);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              AppIcon(extensionHealthIcon(context, statusValue), color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _healthStatusLabel(context, statusValue),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (status?.checkedAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.extensionLastChecked(
                          TimeOfDay.fromDateTime(
                            status!.checkedAt!.toLocal(),
                          ).format(context),
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AppIconButton(
                tooltip: context.l10n.extensionRefreshStatus,
                onPressed: isRefreshing ? null : onRefresh,
                icon: isRefreshing
                    ? AppLoadingIndicator(
                        size: 20,
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      )
                    : AppIcon(
                        context.isMornye
                            ? CupertinoIcons.refresh
                            : Icons.refresh,
                      ),
              ),
            ],
          ),
        ),
        const _ExtensionDivider(),
      ],
    );
  }
}

class _HealthCheckItem extends StatelessWidget {
  final ExtensionHealthCheckStatus check;
  final bool showDivider;

  const _HealthCheckItem({required this.check, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = extensionHealthColor(context, check.status);
    final detailParts = <String>[
      _healthStatusLabel(context, check.status),
      if (check.httpStatus != null) 'HTTP ${check.httpStatus}',
      if (check.serviceKey?.isNotEmpty == true) check.serviceKey!,
      if (check.latencyMs > 0) '${check.latencyMs} ms',
      if (check.required) context.l10n.extensionHealthRequired,
    ];
    final message = check.error?.trim().isNotEmpty == true
        ? context.friendlyError(
            check.error,
            fallback: context.l10n.extensionHealthServiceUnknown,
          )
        : check.message;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(extensionHealthIcon(context, check.status), color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      check.displayLabel,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detailParts.join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (message != null && message.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: check.error != null
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(),
      ],
    );
  }
}

class _PermissionItem extends StatelessWidget {
  final String permission;
  final bool showDivider;

  const _PermissionItem({required this.permission, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    IconData icon = Icons.security;
    String description = permission;

    if (permission == 'network:*') {
      icon = Icons.language;
      description = 'Network access to: all domains';
    } else if (permission == 'network:http') {
      icon = Icons.warning_amber_outlined;
      description = 'Unencrypted HTTP connections allowed';
    } else if (permission.startsWith('network:')) {
      icon = Icons.language;
      description = 'Network access to: ${permission.substring(8)}';
    } else if (permission.startsWith('storage:')) {
      icon = Icons.folder;
      description = 'Storage access: ${permission.substring(8)}';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              AppIcon(
                context.adaptiveIcon(icon),
                color: context.isMornye
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(),
      ],
    );
  }
}

class _SettingItem extends StatefulWidget {
  final ExtensionSetting setting;
  final dynamic value;
  final bool showDivider;
  final ValueChanged<dynamic> onChanged;
  final String extensionId;
  final bool countryOptions;
  final Future<void> Function(Map<String, dynamic> payload)? onActionPayload;

  const _SettingItem({
    super.key,
    required this.setting,
    required this.value,
    required this.onChanged,
    required this.extensionId,
    this.countryOptions = false,
    this.onActionPayload,
    this.showDivider = true,
  });

  @override
  State<_SettingItem> createState() => _SettingItemState();
}

class _SettingItemState extends State<_SettingItem> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget? trailing;
    Widget? footer;
    VoidCallback? onTap;
    switch (widget.setting.type) {
      case 'boolean':
        trailing = AppSwitch(
          value: widget.value as bool? ?? false,
          semanticLabel: widget.setting.label,
          onChanged: widget.onChanged,
        );
        onTap = () => widget.onChanged(!(widget.value as bool? ?? false));
        break;
      case 'select':
        onTap = widget.setting.options?.isNotEmpty == true
            ? _showOptions
            : null;
        footer = Text(
          widget.countryOptions
              ? extensionCountryName(context, widget.value?.toString() ?? '')
              : widget.value?.toString() ?? context.l10n.extensionSettingNotSet,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
        );
        break;
      case 'button':
        onTap = _isLoading ? null : () => _invokeAction(context);
        if (_isLoading) {
          trailing = const SizedBox(
            width: 24,
            height: 24,
            child: AppLoadingIndicator(size: 24, strokeWidth: 2),
          );
        }
        break;
      case 'string':
      case 'number':
        onTap = () => _showEditDialog(context);
        footer = widget.setting.key == 'oauth_login_url'
            ? _OauthLoginLinkPreview(
                value: widget.value?.toString(),
                colorScheme: colorScheme,
              )
            : Text(
                widget.countryOptions
                    ? extensionCountryName(
                        context,
                        widget.value?.toString() ?? '',
                      )
                    : widget.value?.toString() ??
                          context.l10n.extensionSettingNotSet,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
              );
        break;
    }
    return SettingsItem(
      title: widget.setting.label,
      subtitle: widget.setting.description?.isNotEmpty == true
          ? widget.setting.description
          : null,
      footer: footer,
      trailing: trailing,
      onTap: onTap,
      showDivider: widget.showDivider,
    );
  }

  Future<void> _showOptions() async {
    final value = await showAppScrollableBottomSheet<String>(
      context: context,
      title: widget.setting.label,
      builder: (sheetContext, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in widget.setting.options ?? <String>[])
              AppSheetOption.choice(
                title: Text(
                  widget.countryOptions
                      ? extensionCountryName(sheetContext, option)
                      : option,
                ),
                selected: option == widget.value,
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        ),
      ),
    );
    if (mounted && value != null) widget.onChanged(value);
  }

  Future<void> _invokeAction(BuildContext context) async {
    if (widget.setting.action == null) {
      showAppSnackBar(
        context,
        content: Text(context.l10n.snackbarNoActionDefined),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final result = await runExtensionActionWithForms(
        context,
        widget.extensionId,
        widget.setting.action!,
      );
      if (result == null) return;

      if (context.mounted) {
        // Go may return either a flat map or { success, result: { ... } }.
        Map<String, dynamic> payload = result;
        final nested = result['result'];
        if (nested is Map) {
          payload = Map<String, dynamic>.from(nested);
        }

        final success = payload['success'] as bool? ?? false;
        if (!success) {
          final error =
              payload['error'] as String? ??
              result['error'] as String? ??
              context.l10n.extensionActionFailed;
          showAppSnackBar(
            context,
            content: Text(
              context.friendlyError(
                error,
                fallback: context.l10n.extensionActionFailed,
              ),
            ),
          );
        } else {
          if (widget.onActionPayload != null) {
            await widget.onActionPayload!(payload);
          }
          final openAuth = payload['open_auth_url'] as String?;
          if (openAuth != null && openAuth.isNotEmpty) {
            final uri = Uri.parse(openAuth);
            final launched = await launchExtensionAuthUrl(
              uri,
              browserMode: 'external_first',
            );
            if (!launched && context.mounted) {
              showAppSnackBar(
                context,
                content: Text(
                  context.l10n.snackbarError('Could not open browser'),
                ),
              );
            }
          }
          final message = payload['message'] as String?;
          if (message != null && message.isNotEmpty && context.mounted) {
            showAppSnackBar(context, content: Text(message));
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarError(context.friendlyError(e))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showEditDialog(BuildContext context) {
    final controller = TextEditingController(
      text: widget.value?.toString() ?? '',
    );
    final colorScheme = Theme.of(context).colorScheme;

    showAppDialog<void>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(widget.setting.label),
        content: context.isMornye
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CupertinoTextField(
                  controller: controller,
                  keyboardType: widget.setting.type == 'number'
                      ? TextInputType.number
                      : TextInputType.text,
                  placeholder:
                      widget.setting.description ??
                      context.l10n.extensionEnterValue,
                  padding: const EdgeInsets.all(12),
                ),
              )
            : AppTextField(
                controller: controller,
                keyboardType: widget.setting.type == 'number'
                    ? TextInputType.number
                    : TextInputType.text,
                hint:
                    widget.setting.description ??
                    context.l10n.extensionEnterValue,
                decoration: InputDecoration(
                  hintText:
                      widget.setting.description ??
                      context.l10n.extensionEnterValue,
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDefault: true,
            onPressed: () {
              final newValue = widget.setting.type == 'number'
                  ? num.tryParse(controller.text)
                  : controller.text;
              widget.onChanged(newValue);
              Navigator.pop(context);
            },
            child: Text(context.l10n.dialogSave),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }
}

class _PostProcessingHookItem extends StatelessWidget {
  final PostProcessingHook hook;
  final bool showDivider;

  const _PostProcessingHookItem({required this.hook, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _ExtensionFeatureRow(
      cupertinoIcon: CupertinoIcons.wand_stars,
      materialIcon: Icons.auto_fix_high,
      title: hook.name,
      description: hook.description,
      extra: hook.supportedFormats.isEmpty
          ? null
          : Wrap(
              spacing: 4,
              children: hook.supportedFormats.map((format) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    format.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }).toList(),
            ),
      pill: hook.defaultEnabled ? context.l10n.extensionsHomeFeedAuto : null,
      pillColor: colorScheme.primaryContainer,
      pillTextColor: colorScheme.onPrimaryContainer,
      showDivider: showDivider,
    );
  }
}

class _ExtensionFeatureRow extends StatelessWidget {
  const _ExtensionFeatureRow({
    required this.cupertinoIcon,
    required this.materialIcon,
    required this.title,
    this.description,
    this.extra,
    this.pill,
    required this.pillColor,
    required this.pillTextColor,
    required this.showDivider,
  });

  final IconData cupertinoIcon;
  final IconData materialIcon;
  final String title;
  final String? description;
  final Widget? extra;
  final String? pill;
  final Color pillColor;
  final Color pillTextColor;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: context.isMornye
                      ? Colors.transparent
                      : colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: AppIcon(
                  context.isMornye ? cupertinoIcon : materialIcon,
                  color: context.isMornye
                      ? colorScheme.primary
                      : colorScheme.onSecondaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        description!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (extra != null) ...[const SizedBox(height: 4), extra!],
                  ],
                ),
              ),
              if (pill != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: pillColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    pill!,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: pillTextColor),
                  ),
                ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(indent: 72),
      ],
    );
  }
}

class _URLHandlerInfo extends StatelessWidget {
  final List<String> patterns;

  const _URLHandlerInfo({required this.patterns});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: context.isMornye
                      ? Colors.transparent
                      : colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppIcon(
                  context.isMornye ? CupertinoIcons.link : Icons.link,
                  color: context.isMornye
                      ? colorScheme.primary
                      : colorScheme.onSecondaryContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.extensionCustomUrlHandling,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.extensionCustomUrlHandlingSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: patterns.map((pattern) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(
                      Icons.language,
                      size: 16,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      pattern,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                AppIcon(
                  Icons.info_outline,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.l10n.extensionCustomUrlHandlingShareHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityOptionItem extends StatelessWidget {
  final QualityOption quality;
  final bool showDivider;

  const _QualityOptionItem({required this.quality, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final description = quality.description;
    return _ExtensionFeatureRow(
      cupertinoIcon: CupertinoIcons.waveform,
      materialIcon: Icons.high_quality,
      title: quality.label,
      description: description?.isNotEmpty == true ? description : null,
      extra: context.isMornye
          ? null
          : Text(
              quality.id,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.primary,
                fontFamily: 'monospace',
              ),
            ),
      pill: quality.settingsCount > 0
          ? context.l10n.extensionSettingsCount(quality.settingsCount)
          : null,
      pillColor: colorScheme.surfaceContainerHighest,
      pillTextColor: colorScheme.onSurfaceVariant,
      showDivider: showDivider,
    );
  }
}
