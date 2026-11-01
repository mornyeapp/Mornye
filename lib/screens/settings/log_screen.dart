import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_crash_banner.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_menu_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';
import 'package:mornye/utils/ordered_range_selection.dart';

part 'log_screen_widgets.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _selectedLevel = 'ALL';
  String _searchQuery = '';
  bool _autoScroll = true;
  bool _selectionMode = false;
  final Set<LogEntry> _selectedEntries = <LogEntry>{};
  LogEntry? _selectionAnchor;
  int? _logUpdateFrame;
  int _scrollGeneration = 0;

  final List<String> _levels = ['ALL', 'DEBUG', 'INFO', 'WARN', 'ERROR'];

  @override
  void initState() {
    super.initState();
    LogBuffer().addListener(_onLogUpdate);
    LogBuffer().startNativeLogPolling();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    LogBuffer().removeListener(_onLogUpdate);
    LogBuffer().stopNativeLogPolling();
    final frame = _logUpdateFrame;
    if (frame != null) WidgetsBinding.instance.cancelFrameCallbackWithId(frame);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onLogUpdate() {
    if (_logUpdateFrame != null) return;
    // A burst of Dart logs can notify once per entry. Read the final buffer
    // once before the next frame, including selection pruning and tailing.
    _logUpdateFrame = WidgetsBinding.instance.scheduleFrameCallback((_) {
      _logUpdateFrame = null;
      if (!mounted) return;
      if (_selectionMode) {
        final currentEntries = LogBuffer().entries.toSet();
        _selectedEntries.removeWhere(
          (entry) => !currentEntries.contains(entry),
        );
        if (_selectedEntries.isEmpty) {
          _selectionMode = false;
          _selectionAnchor = null;
        } else if (!_selectedEntries.contains(_selectionAnchor)) {
          _selectionAnchor = _selectedEntries.last;
        }
      }
      setState(() {});
      if (_autoScroll && _scrollController.hasClients) {
        _scrollToLatest(++_scrollGeneration);
      }
    });
  }

  void _onScroll() {
    if (_scrollController.position.userScrollDirection !=
        ScrollDirection.idle) {
      _scrollGeneration++;
    }
  }

  Future<void> _scrollToLatest(int generation) async {
    await WidgetsBinding.instance.endOfFrame;
    while (mounted &&
        generation == _scrollGeneration &&
        _autoScroll &&
        !_selectionMode &&
        _scrollController.hasClients) {
      final position = _scrollController.position;
      if (position.extentAfter <= 0.5) return;
      await position.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
      // A lazy list refines its extent as new multiline rows are laid out.
      // Follow that estimate until the final row is actually visible.
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  List<LogEntry> get _filteredLogs {
    return LogBuffer().filter(
      level: _selectedLevel,
      search: _searchQuery.isEmpty ? null : _searchQuery,
    );
  }

  void _copyLogs() async {
    final logs = await LogBuffer().exportWithDeviceInfo();
    Clipboard.setData(ClipboardData(text: logs));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.logCopied),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _enterSelectionMode(LogEntry entry) {
    setState(() {
      _selectionMode = true;
      _autoScroll = false;
      _selectedEntries.add(entry);
      _selectionAnchor = entry;
    });
  }

  void _toggleEntrySelection(LogEntry entry) {
    if (!_selectionMode) return;
    setState(() {
      _selectionAnchor = toggleOrderedSelection(
        selected: _selectedEntries,
        target: entry,
      );
      if (_selectedEntries.isEmpty) _selectionMode = false;
    });
  }

  void _selectRangeTo(LogEntry entry) {
    setState(() {
      _selectionMode = true;
      _autoScroll = false;
      _selectionAnchor = addOrderedSelectionRange(
        selected: _selectedEntries,
        visibleItems: _filteredLogs,
        target: entry,
        anchor: _selectionAnchor,
      );
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedEntries.clear();
      _selectionAnchor = null;
    });
  }

  void _toggleSelectAllVisible() {
    final visibleLogs = _filteredLogs;
    final allVisibleSelected =
        visibleLogs.isNotEmpty && visibleLogs.every(_selectedEntries.contains);
    setState(() {
      if (allVisibleSelected) {
        _selectedEntries.removeAll(visibleLogs);
      } else {
        _selectedEntries.addAll(visibleLogs);
      }
      _selectionMode = _selectedEntries.isNotEmpty;
      _selectionAnchor = _selectedEntries.isEmpty
          ? null
          : allVisibleSelected
          ? _selectedEntries.last
          : visibleLogs.lastOrNull;
    });
  }

  Future<void> _copySelectedLogs() async {
    final selectedInUserOrder = _selectedEntries.toList(growable: false);
    if (selectedInUserOrder.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: formatLogEntries(selectedInUserOrder)),
    );
    if (!mounted) return;
    _exitSelectionMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.logCopied),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _shareLogs() async {
    final subject = '${context.l10n.appName} Logs';
    final logs = await LogBuffer().exportWithDeviceInfo();
    SharePlus.instance.share(ShareParams(text: logs, subject: subject));
  }

  void _shareSelectedLogs() {
    final selectedInUserOrder = _selectedEntries.toList(growable: false);
    if (selectedInUserOrder.isEmpty) return;
    SharePlus.instance.share(
      ShareParams(
        text: formatLogEntries(selectedInUserOrder),
        subject: '${context.l10n.appName} Logs',
      ),
    );
  }

  Future<void> _clearLogs() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.logClearLogsTitle,
      message: context.l10n.logClearLogsMessage,
      confirmLabel: context.l10n.dialogClear,
      cancelIsDefault: true,
      destructive: true,
    );
    if (!confirmed) return;
    _selectionMode = false;
    _selectedEntries.clear();
    _selectionAnchor = null;
    LogBuffer().clear();
  }

  Future<void> _showLevelPicker(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;
    final level = await showAppBottomSheet<String>(
      context: context,
      title: context.l10n.logFilterLevel,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SettingsGroup(
          children: [
            for (final level in _levels)
              SettingsItem(
                title: level,
                selected: level == _selectedLevel,
                trailing: level == _selectedLevel
                    ? AppIcon(Icons.check, color: colorScheme.primary)
                    : null,
                showDivider: level != _levels.last,
                onTap: () => Navigator.pop(sheetContext, level),
              ),
          ],
        ),
      ),
    );
    if (level != null && mounted) setState(() => _selectedLevel = level);
  }

  Color _getLevelColor(String level, ColorScheme colorScheme) {
    switch (level) {
      case 'ERROR':
      case 'FATAL':
        return colorScheme.error;
      case 'WARN':
        return colorScheme.tertiary;
      case 'INFO':
        return colorScheme.primary;
      case 'DEBUG':
      default:
        return colorScheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final logs = _filteredLogs;

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode) _exitSelectionMode();
      },
      child: Scaffold(
        body: CustomScrollView(
          controller: _scrollController,
          slivers: [
            AppSliverHeader.page(
              title: _selectionMode
                  ? context.l10n.selectionSelected(_selectedEntries.length)
                  : context.l10n.logTitle,
              leading: _selectionMode
                  ? AppIconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const AppIcon(Icons.close),
                      onPressed: _exitSelectionMode,
                    )
                  : null,
              actions: _selectionMode
                  ? [
                      AppIconButton(
                        icon: AppIcon(
                          logs.isNotEmpty &&
                                  logs.every(_selectedEntries.contains)
                              ? Icons.deselect
                              : Icons.select_all,
                        ),
                        tooltip:
                            logs.isNotEmpty &&
                                logs.every(_selectedEntries.contains)
                            ? context.l10n.actionDeselect
                            : context.l10n.actionSelectAll,
                        onPressed: _toggleSelectAllVisible,
                      ),
                      AppIconButton(
                        icon: const AppIcon(Icons.copy),
                        tooltip: context.l10n.logCopyLogs,
                        onPressed: _selectedEntries.isEmpty
                            ? null
                            : _copySelectedLogs,
                      ),
                      AppIconButton(
                        icon: const AppIcon(Icons.share),
                        tooltip: context.l10n.logShareLogs,
                        onPressed: _selectedEntries.isEmpty
                            ? null
                            : _shareSelectedLogs,
                      ),
                    ]
                  : [
                      AppIconButton(
                        icon: AppIcon(
                          _autoScroll
                              ? Icons.vertical_align_bottom
                              : Icons.vertical_align_center,
                        ),
                        tooltip: _autoScroll
                            ? context.l10n.logAutoScrollOn
                            : context.l10n.logAutoScrollOff,
                        onPressed: () =>
                            setState(() => _autoScroll = !_autoScroll),
                      ),
                      AppIconButton(
                        icon: const AppIcon(Icons.copy),
                        tooltip: context.l10n.logCopyLogs,
                        onPressed: _copyLogs,
                      ),
                      AppMenuButton<String>(
                        icon: const AppIcon(Icons.more_vert),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).showMenuTooltip,
                        onSelected: (value) {
                          switch (value) {
                            case 'share':
                              _shareLogs();
                              break;
                            case 'clear':
                              _clearLogs();
                              break;
                          }
                        },
                        items: [
                          AppMenuItem(
                            value: 'share',
                            label: context.l10n.logShareLogs,
                            leading: const AppIcon(Icons.share),
                          ),
                          AppMenuItem(
                            value: 'clear',
                            label: context.l10n.logClearLogs,
                            leading: const AppIcon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ],
            ),

            const SliverToBoxAdapter(child: AppCrashBanner(diagnostic: true)),
            ...settingsSectionSlivers(
              title: context.l10n.logFilterSection,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      AppIcon(
                        Icons.filter_list,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.logFilterLevel,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              context.l10n.logFilterBySeverity,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      ExpressiveButton(
                        tonal: true,
                        onPressed: () => _showLevelPicker(context),
                        icon: const Icon(Icons.arrow_drop_down, size: 20),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: Text(
                          _selectedLevel,
                          style: TextStyle(
                            color: _selectedLevel == 'ALL'
                                ? null
                                : _getLevelColor(_selectedLevel, colorScheme),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 56,
                  endIndent: 20,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: AppSearchField(
                    controller: _searchController,
                    hintText: context.l10n.logSearchHint,
                    clearTooltip: context.l10n.logClearSearch,
                    onClear: () => setState(() => _searchQuery = ''),
                    onChanged: (value) => setState(() => _searchQuery = value),
                  ),
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: _selectedLevel != 'ALL' || _searchQuery.isNotEmpty
                    ? context.l10n.logEntriesFiltered(logs.length)
                    : context.l10n.logEntries(logs.length),
              ),
            ),

            SliverToBoxAdapter(
              child: _LogSummaryCard(logs: LogBuffer().entries),
            ),

            logs.isEmpty
                ? SliverToBoxAdapter(
                    child: SettingsGroup(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppIcon(
                                Icons.article_outlined,
                                size: 48,
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                context.l10n.logNoLogsYet,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                context.l10n.logNoLogsYetSubtitle,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant
                                          .withValues(alpha: 0.7),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : SliverLayoutInfoBuilder<double>(
                    select: (constraints) => constraints.crossAxisExtent,
                    builder: (context, width) => SliverSettingsGroup(
                      margin: EdgeInsets.symmetric(
                        horizontal: settingsHorizontalInset(context, width),
                        vertical: 4,
                      ),
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        final log = logs[index];
                        return _LogEntryTile(
                          entry: log,
                          levelColor: _getLevelColor(log.level, colorScheme),
                          showDivider: index < logs.length - 1,
                          selectionMode: _selectionMode,
                          selected: _selectedEntries.contains(log),
                          onTap: () => _toggleEntrySelection(log),
                          onLongPress: () => _selectionMode
                              ? _selectRangeTo(log)
                              : _enterSelectionMode(log),
                        );
                      },
                    ),
                  ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}
