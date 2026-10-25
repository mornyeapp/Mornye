import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Provider, key, model and behavior of AI lyrics translation.
class LyricsAiTranslationPage extends ConsumerStatefulWidget {
  const LyricsAiTranslationPage({super.key});

  @override
  ConsumerState<LyricsAiTranslationPage> createState() =>
      _LyricsAiTranslationPageState();
}

class _LyricsAiTranslationPageState
    extends ConsumerState<LyricsAiTranslationPage> {
  bool _testing = false;
  int? _cachedCount;

  @override
  void initState() {
    super.initState();
    _loadCachedCount();
  }

  Future<void> _loadCachedCount() async {
    final count = await ref
        .read(lyricsTranslationProvider.notifier)
        .cachedCount();
    if (mounted) setState(() => _cachedCount = count);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showAppSnackBar(context, content: Text(message));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final provider = LyricsAiProvider.fromId(settings.lyricsAiProvider);
    final apiKey =
        ref.watch(lyricsAiKeyProvider(provider.id)).value?.trim() ?? '';
    final defaultModel = provider.defaultModel;
    final target = lyricsTranslationLanguageFor(
      settings.lyricsTranslationLanguage,
    );
    final appLanguage = lyricsTranslationTargetFor(
      settings.copyWith(lyricsTranslationLanguage: ''),
    );
    final ready = lyricsAiReady(settings, apiKey);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.lyricsAiTranslation),
          SliverToBoxAdapter(
            child: SettingsInfoCard(
              icon: Icons.privacy_tip_outlined,
              message: l10n.lyricsAiTranslationNotice,
            ),
          ),
          ...settingsSectionSlivers(
            title: l10n.lyricsAiSectionProvider,
            children: [
              SettingsItem(
                icon: Icons.auto_awesome_outlined,
                title: l10n.lyricsAiProvider,
                subtitle: lyricsAiProviderName(l10n, provider),
                onTap: () => _pickProvider(provider),
              ),
              if (provider == LyricsAiProvider.custom)
                SettingsItem(
                  icon: Icons.dns_outlined,
                  title: l10n.lyricsAiBaseUrl,
                  subtitle: settings.lyricsAiBaseUrl.isEmpty
                      ? l10n.lyricsAiNotSet
                      : settings.lyricsAiBaseUrl,
                  onTap: () => _editBaseUrl(settings.lyricsAiBaseUrl),
                ),
              SettingsItem(
                key: const ValueKey('lyrics-ai-api-key'),
                icon: Icons.key_outlined,
                title: l10n.lyricsAiApiKey,
                subtitle: apiKey.isNotEmpty
                    ? l10n.lyricsAiApiKeySaved(_keySuffix(apiKey))
                    : provider.requiresKey
                    ? l10n.lyricsAiNotSet
                    : l10n.lyricsAiApiKeyOptional,
                onTap: () => _editKey(provider, apiKey),
              ),
              SettingsItem(
                icon: Icons.memory_outlined,
                title: l10n.lyricsAiModel,
                subtitle: settings.lyricsAiModel.isNotEmpty
                    ? settings.lyricsAiModel
                    : defaultModel != null
                    ? l10n.lyricsAiModelDefault(defaultModel)
                    : l10n.lyricsAiNotSet,
                onTap: () => _editModel(provider, apiKey),
              ),
              SettingsItem(
                key: const ValueKey('lyrics-ai-test'),
                icon: Icons.network_check_outlined,
                title: l10n.lyricsAiTestConnection,
                subtitle: l10n.lyricsAiTestConnectionSubtitle,
                trailing: _testing ? const AppLoadingIndicator(size: 24) : null,
                onTap: ready && !_testing
                    ? () => _testConnection(apiKey)
                    : null,
                showDivider: false,
              ),
            ],
          ),
          ...settingsSectionSlivers(
            title: l10n.lyricsAiSectionTranslation,
            children: [
              SettingsItem(
                icon: Icons.language_outlined,
                title: l10n.lyricsAiTargetLanguage,
                subtitle: target == null
                    ? l10n.lyricsAiTargetLanguageApp(appLanguage.nativeName)
                    : target.nativeName,
                onTap: () async {
                  final code = await showLyricsLanguagePicker(
                    context,
                    title: l10n.lyricsAiTargetLanguage,
                    selected: target?.code ?? '',
                    appDefaultLabel: l10n.lyricsAiTargetLanguageApp(
                      appLanguage.nativeName,
                    ),
                  );
                  if (code != null) notifier.setLyricsTranslationLanguage(code);
                },
              ),
              SettingsItem(
                icon: Icons.edit_note_outlined,
                title: l10n.lyricsAiInstruction,
                subtitle: settings.lyricsAiInstruction.isEmpty
                    ? l10n.lyricsAiInstructionNone
                    : settings.lyricsAiInstruction,
                onTap: () => _editInstruction(settings.lyricsAiInstruction),
              ),
              SettingsSwitchItem(
                icon: Icons.bolt_outlined,
                title: l10n.lyricsAiAutoTranslate,
                subtitle: l10n.lyricsAiAutoTranslateSubtitle,
                value: settings.lyricsAutoTranslate,
                onChanged: notifier.setLyricsAutoTranslate,
              ),
              SettingsItem(
                icon: Icons.delete_outline,
                title: l10n.lyricsAiClearCache,
                subtitle: _cachedCount == null
                    ? null
                    : l10n.lyricsAiClearCacheSubtitle(_cachedCount!),
                onTap: (_cachedCount ?? 0) > 0 ? _clearCache : null,
                showDivider: false,
              ),
            ],
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }

  static String _keySuffix(String key) =>
      key.length > 8 ? key.substring(key.length - 4) : '••••';

  void _pickProvider(LyricsAiProvider current) {
    final l10n = context.l10n;
    showAppChoiceSheet<LyricsAiProvider>(
      context: context,
      title: l10n.lyricsAiProvider,
      selected: current,
      choices: [
        for (final provider in LyricsAiProvider.values)
          AppChoice(
            provider,
            switch (provider) {
              LyricsAiProvider.openAi => Icons.chat_bubble_outline,
              LyricsAiProvider.openRouter => Icons.alt_route_outlined,
              LyricsAiProvider.gemini => Icons.diamond_outlined,
              LyricsAiProvider.anthropic => Icons.psychology_outlined,
              LyricsAiProvider.custom => Icons.dns_outlined,
            },
            lyricsAiProviderName(l10n, provider),
            subtitle: provider == LyricsAiProvider.custom
                ? l10n.lyricsAiProviderCustomSubtitle
                : null,
          ),
      ],
      onSelected: (provider) =>
          ref.read(settingsProvider.notifier).setLyricsAiProvider(provider.id),
    );
  }

  Future<void> _editBaseUrl(String current) async {
    final l10n = context.l10n;
    final value = await _showTextSheet(
      context,
      title: l10n.lyricsAiBaseUrl,
      initial: current,
      hint: 'http://localhost:11434/v1',
      keyboardType: TextInputType.url,
      validate: (value) => value.isEmpty || isValidLyricsAiBaseUrl(value)
          ? null
          : l10n.lyricsAiBaseUrlInvalid,
    );
    if (value != null) {
      ref
          .read(settingsProvider.notifier)
          .setLyricsAiBaseUrl(
            value.isEmpty ? '' : normalizeLyricsAiBaseUrl(value),
          );
    }
  }

  Future<void> _editKey(LyricsAiProvider provider, String current) async {
    final l10n = context.l10n;
    final value = await _showTextSheet(
      context,
      title: l10n.lyricsAiApiKey,
      subtitle: l10n.lyricsAiApiKeyDescription(
        lyricsAiProviderName(l10n, provider),
      ),
      initial: current,
      secret: true,
      clearable: true,
    );
    if (value == null || !mounted) return;
    final store = ref.read(lyricsAiKeyStoreProvider);
    try {
      if (value.isEmpty) {
        await store.delete(provider.id);
      } else {
        await store.write(provider.id, value);
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(l10n.snackbarError(context.friendlyError(error)));
    }
    if (mounted) ref.invalidate(lyricsAiKeyProvider(provider.id));
  }

  Future<void> _editInstruction(String current) async {
    final l10n = context.l10n;
    final value = await _showTextSheet(
      context,
      title: l10n.lyricsAiInstruction,
      initial: current,
      hint: l10n.lyricsAiInstructionHint,
      multiline: true,
      clearable: true,
    );
    if (value != null) {
      ref.read(settingsProvider.notifier).setLyricsAiInstruction(value);
    }
  }

  Future<void> _editModel(LyricsAiProvider provider, String apiKey) async {
    final settings = ref.read(settingsProvider);
    final value = await showAppScrollableBottomSheet<String>(
      context: context,
      title: context.l10n.lyricsAiModel,
      builder: (sheetContext, controller) => _ModelSheet(
        scrollController: controller,
        initial: settings.lyricsAiModel,
        defaultModel: provider.defaultModel,
        loadModels:
            (provider == LyricsAiProvider.custom &&
                    !isValidLyricsAiBaseUrl(settings.lyricsAiBaseUrl)) ||
                (provider.requiresKey && apiKey.isEmpty)
            ? null
            : () => ref
                  .read(lyricsTranslationProvider.notifier)
                  .listModels(lyricsAiConfigFor(settings, apiKey: apiKey)),
      ),
    );
    if (value != null) {
      ref.read(settingsProvider.notifier).setLyricsAiModel(value);
    }
  }

  Future<void> _testConnection(String apiKey) async {
    setState(() => _testing = true);
    final l10n = context.l10n;
    try {
      await ref
          .read(lyricsTranslationProvider.notifier)
          .testConnection(
            lyricsAiConfigFor(ref.read(settingsProvider), apiKey: apiKey),
          );
      _showMessage(l10n.lyricsAiTestSuccess);
    } on LyricsAiException catch (error) {
      _showMessage(lyricsAiErrorMessage(l10n, error.kind));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _clearCache() async {
    final l10n = context.l10n;
    final confirmed = await showAppConfirmDialog(
      context,
      title: l10n.lyricsAiClearCacheConfirm,
      message: l10n.lyricsAiClearCacheMessage,
      confirmLabel: l10n.dialogClear,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await ref.read(lyricsTranslationProvider.notifier).clearCache();
    _showMessage(l10n.lyricsAiClearCacheDone);
    await _loadCachedCount();
  }
}

/// A sheet with one text field. Returns the trimmed text, an empty string
/// when cleared, or null when cancelled.
Future<String?> _showTextSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required String initial,
  String? hint,
  bool secret = false,
  bool multiline = false,
  bool clearable = false,
  TextInputType? keyboardType,
  String? Function(String value)? validate,
}) => showAppScrollableBottomSheet<String>(
  context: context,
  title: title,
  subtitle: subtitle,
  dialogSize: AppDialogSize.compact,
  builder: (sheetContext, scrollController) => _TextSheetBody(
    scrollController: scrollController,
    initial: initial,
    hint: hint,
    secret: secret,
    multiline: multiline,
    clearable: clearable,
    keyboardType: keyboardType,
    validate: validate,
  ),
);

class _TextSheetBody extends StatefulWidget {
  const _TextSheetBody({
    required this.scrollController,
    required this.initial,
    this.hint,
    this.secret = false,
    this.multiline = false,
    this.clearable = false,
    this.keyboardType,
    this.validate,
  });

  final ScrollController scrollController;
  final String initial;
  final String? hint;
  final bool secret;
  final bool multiline;
  final bool clearable;
  final TextInputType? keyboardType;
  final String? Function(String value)? validate;

  @override
  State<_TextSheetBody> createState() => _TextSheetBodyState();
}

class _TextSheetBodyState extends State<_TextSheetBody> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    final error = widget.validate?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, value);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final paste = widget.secret
        ? IconButton(
            tooltip: l10n.actionPaste,
            icon: const AppIcon(Icons.content_paste_outlined),
            onPressed: _paste,
          )
        : null;
    final field = context.isMornye
        ? CupertinoTextField(
            controller: _controller,
            autofocus: true,
            obscureText: widget.secret,
            autocorrect: !widget.secret,
            enableSuggestions: !widget.secret,
            enableIMEPersonalizedLearning: !widget.secret,
            keyboardType: widget.multiline
                ? TextInputType.multiline
                : widget.keyboardType,
            maxLines: widget.multiline ? 4 : 1,
            maxLength: widget.multiline ? 500 : null,
            placeholder: widget.hint,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: MornyeTheme.controlFill(context),
              borderRadius: BorderRadius.circular(12),
            ),
            style: theme.textTheme.bodyLarge,
            suffix: paste,
            onSubmitted: widget.multiline ? null : (_) => _save(),
          )
        // A key keeps its dedicated field, as other credentials do.
        : widget.secret
        ? TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: widget.keyboardType,
            decoration: InputDecoration(
              hintText: widget.hint,
              errorText: _error,
              suffixIcon: paste,
            ),
            onSubmitted: (_) => _save(),
          )
        : AppTextField(
            controller: _controller,
            autofocus: true,
            hint: widget.hint,
            errorText: _error,
            keyboardType: widget.multiline
                ? TextInputType.multiline
                : widget.keyboardType,
            textInputAction: widget.multiline ? null : TextInputAction.done,
            maxLines: widget.multiline ? 4 : 1,
            maxLength: widget.multiline ? 500 : null,
            onSubmitted: widget.multiline ? null : (_) => _save(),
          );
    final actions = [
      if (widget.clearable)
        AppDialogAction(
          isDestructive: true,
          onPressed: () => Navigator.pop(context, ''),
          child: Text(l10n.dialogClear),
        ),
      AppDialogAction(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        onPressed: _save,
        child: Text(l10n.dialogSave),
      ),
    ];
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          // Material fields show the error themselves.
          if (_error != null && context.isMornye)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 4, top: 6),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          ),
        ],
      ),
    );
  }
}

/// Model id entry with an optional list from the provider's catalog.
/// Returns the chosen id, an empty string for the default, or null.
class _ModelSheet extends StatefulWidget {
  const _ModelSheet({
    required this.scrollController,
    required this.initial,
    required this.defaultModel,
    required this.loadModels,
  });

  final ScrollController scrollController;
  final String initial;
  final String? defaultModel;

  /// Null while the provider is missing its key or server.
  final Future<List<String>> Function()? loadModels;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  late final _controller = TextEditingController(text: widget.initial);
  List<String>? _models;
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final load = widget.loadModels;
    if (load == null || _loading) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    final l10n = context.l10n;
    try {
      final models = await load();
      if (!mounted) return;
      setState(() {
        _models = models;
        if (models.isEmpty) _message = l10n.lyricsAiModelsEmpty;
      });
    } on LyricsAiException catch (error) {
      if (mounted) {
        setState(() => _message = lyricsAiErrorMessage(l10n, error.kind));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty && widget.defaultModel == null) {
      setState(() => _message = context.l10n.lyricsAiNotSet);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final current = _controller.text.trim().isEmpty
        ? widget.defaultModel
        : _controller.text.trim();
    final actions = [
      if (widget.defaultModel != null)
        AppDialogAction(
          onPressed: () => Navigator.pop(context, ''),
          child: Text(l10n.lyricsAiModelUseDefault),
        ),
      AppDialogAction(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        onPressed: _save,
        child: Text(l10n.dialogSave),
      ),
    ];
    // Sized to its content, like the other settings sheets; a loaded
    // model list grows it up to the sheet's limit and scrolls.
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: context.isMornye
                ? CupertinoTextField(
                    controller: _controller,
                    autocorrect: false,
                    enableSuggestions: false,
                    placeholder: widget.defaultModel ?? l10n.lyricsAiModelHint,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: MornyeTheme.controlFill(context),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    style: theme.textTheme.bodyLarge,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                  )
                // Model ids keep keyboard correction off.
                : AppTextField(
                    controller: _controller,
                    autocorrect: false,
                    label: l10n.lyricsAiModelHint,
                    hint: widget.defaultModel,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ),
          if (widget.loadModels != null && _models == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ExpressiveButton(
                  tonal: true,
                  onPressed: _loading ? null : _load,
                  icon: _loading
                      ? const AppLoadingIndicator(size: 18)
                      : const Icon(Icons.list_alt_outlined),
                  child: Text(l10n.lyricsAiModelLoad),
                ),
              ),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                _message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final model in _models ?? const <String>[])
            AppSheetOption.choice(
              title: Text(model),
              selected: model == current,
              onTap: () => Navigator.pop(context, model),
            ),
        ],
      ),
    );
  }
}
