import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/error_card.dart' show EmptyState;
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/link/link_transfer_tile.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

/// Opens the Transfers list: a page on phones, a dialog of the list size
/// class on desktop.
Future<void> showLinkTransfers(BuildContext context) {
  if (isDesktopPlatform) {
    return showAppSheetDialog<void>(
      context: context,
      isScrollControlled: true,
      dialogSize: AppDialogSize.medium,
      builder: (_) => const LinkTransfersDialog(),
    );
  }
  return Navigator.of(context).push(
    slidePageRoute<void>(
      page: const MornyeSettingsTheme(child: LinkTransfersPage()),
    ),
  );
}

/// The progress of the active [transfers] together, 0 to 1, each weighted
/// by its songs; null while none is active.
double? linkTransfersProgress(List<LinkTransfer> transfers) {
  var songs = 0;
  var done = 0.0;
  var active = false;
  for (final transfer in transfers) {
    if (!transfer.active) continue;
    active = true;
    final total = transfer.status.total;
    songs += total;
    done += transfer.status.fraction * total;
  }
  if (!active) return null;
  return songs == 0 ? 0 : done / songs;
}

/// The status line of the rows that open the Transfers list: the one
/// active transfer with its progress ("Sending 12 songs to Studio · 45%"),
/// how many run with their progress, how many finished, or none yet.
String linkTransfersSummary(
  AppLocalizations l10n,
  List<LinkTransfer> transfers,
) {
  final active = [
    for (final transfer in transfers)
      if (transfer.active) transfer,
  ];
  if (active.isEmpty) {
    return transfers.isEmpty
        ? l10n.linkTransfersEmptyTitle
        : l10n.linkTransfersFinishedCount(transfers.length);
  }
  final percent = l10n.linkTransfersPercent(
    linkTransferPercent(linkTransfersProgress(active)!, active: true),
  );
  if (active.length > 1) {
    return '${l10n.linkTransfersActiveCount(active.length)} · $percent';
  }
  final transfer = active.single;
  final state = transfer.status.state == LinkTransferState.queued
      ? l10n.linkTransfersWaiting
      : percent;
  return '${linkTransferTitle(l10n, transfer)} · $state';
}

/// The Transfers row of the Link settings pages: live progress while
/// transfers run, else how many finished. Opens [showLinkTransfers].
class LinkTransfersSettingsItem extends ConsumerWidget {
  const LinkTransfersSettingsItem({super.key, this.showDivider = false});

  final bool showDivider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(linkTransfersProvider);
    final progress = linkTransfersProgress(transfers);
    return SettingsItem(
      key: const ValueKey('link-transfers-row'),
      icon: Icons.swap_horiz_rounded,
      showIconInMornye: true,
      title: context.l10n.linkTransfersTitle,
      subtitle: linkTransfersSummary(context.l10n, transfers),
      footer: progress == null
          ? null
          : LinkTransferProgressBar(value: progress),
      onTap: () => showLinkTransfers(context),
      showDivider: showDivider,
    );
  }
}

/// The Transfers page on phones.
class LinkTransfersPage extends StatelessWidget {
  const LinkTransfersPage({super.key});

  @override
  Widget build(BuildContext context) => const _TransfersList(dialog: false);
}

/// The Transfers list in a desktop dialog.
class LinkTransfersDialog extends StatelessWidget {
  const LinkTransfersDialog({super.key});

  @override
  Widget build(BuildContext context) => const _TransfersList(dialog: true);
}

/// The transfers of this app run in two groups, In progress (running ones
/// first, then the queue in the order it runs) and Finished (latest first),
/// updating as the engines report.
class _TransfersList extends ConsumerStatefulWidget {
  const _TransfersList({required this.dialog});

  final bool dialog;

  @override
  ConsumerState<_TransfersList> createState() => _TransfersListState();
}

class _TransfersListState extends ConsumerState<_TransfersList> {
  /// Transfers whose songs show; kept here so a transfer stays open when it
  /// moves from In progress to Finished.
  final _expanded = <String>{};

  void _toggle(String id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  void _clearFinished() {
    final transfers = ref.read(linkTransfersProvider.notifier)..clearFinished();
    setState(() => _expanded.retainWhere((id) => transfers.byId(id) != null));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final transfers = ref.watch(linkTransfersProvider);
    final active = [
      for (final transfer in transfers)
        if (transfer.active) transfer,
    ]..sort(_runOrder);
    final finished = [
      for (final transfer in transfers)
        if (!transfer.active) transfer,
    ]..sort(_finishOrder);
    final dialog = widget.dialog;
    final empty = EmptyState(
      icon: context.adaptiveIcon(Icons.swap_horiz_rounded),
      title: l10n.linkTransfersEmptyTitle,
      message: l10n.linkTransfersEmptyMessage,
    );

    final sections = [
      if (transfers.isEmpty)
        dialog
            ? SliverToBoxAdapter(child: empty)
            : SliverFillRemaining(hasScrollBody: false, child: empty),
      for (final (title, group) in [
        (l10n.linkTransfersInProgress, active),
        (l10n.linkTransfersFinished, finished),
      ])
        if (group.isNotEmpty) ...[
          SliverToBoxAdapter(child: SettingsSectionHeader(title: title)),
          _TransferGroup(
            transfers: group,
            expanded: _expanded,
            onToggle: _toggle,
          ),
        ],
    ];

    if (!dialog) {
      return Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(
              title: l10n.linkTransfersTitle,
              actions: [
                if (finished.isNotEmpty)
                  _ClearFinishedButton(onPressed: _clearFinished),
              ],
            ),
            ...sections,
            const NavBarSliverSpacer(),
          ],
        ),
      );
    }
    // The body scrolls between the fixed header and footer.
    return AppBottomSheet(
      title: l10n.linkTransfersTitle,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: CustomScrollView(
              shrinkWrap: true,
              slivers: [
                ...sections,
                SliverToBoxAdapter(child: SizedBox(height: tokens.gapLg)),
              ],
            ),
          ),
          if (finished.isNotEmpty)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.gapXl,
                0,
                tokens.gapLg,
                tokens.gapLg,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _ClearFinishedButton(
                  onPressed: _clearFinished,
                  text: true,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static int _runOrder(LinkTransfer a, LinkTransfer b) {
    final running =
        (b.status.state == LinkTransferState.running ? 1 : 0) -
        (a.status.state == LinkTransferState.running ? 1 : 0);
    return running != 0 ? running : a.startedAt.compareTo(b.startedAt);
  }

  static int _finishOrder(LinkTransfer a, LinkTransfer b) =>
      (b.finishedAt ?? b.startedAt).compareTo(a.finishedAt ?? a.startedAt);
}

/// A group of transfers drawn like a [SettingsGroup], in its fill as the
/// Devices sheet is: connected surfaces on Material, one inset grouped
/// surface with separators on Mornye.
class _TransferGroup extends StatelessWidget {
  const _TransferGroup({
    required this.transfers,
    required this.expanded,
    required this.onToggle,
  });

  /// The corner of a Mornye group, as [SettingsGroup] draws it.
  static const _mornyeRadius = Radius.circular(28);

  final List<LinkTransfer> transfers;
  final Set<String> expanded;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final tokens = context.tokens;
    final color = settingsGroupColor(context);
    final last = transfers.length - 1;
    final slivers = [
      for (final (index, transfer) in transfers.indexed) ...[
        if (index > 0)
          SliverToBoxAdapter(
            child: mornye
                ? Divider(
                    height: 1,
                    indent:
                        tokens.rowPaddingH +
                        tokens.coverCompact +
                        tokens.rowIconGap,
                    endIndent: tokens.rowPaddingH,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  )
                : const SizedBox(height: 2),
          ),
        LinkTransferSliver(
          key: ValueKey(transfer.id),
          transfer: transfer,
          expanded: expanded.contains(transfer.id),
          onToggle: () => onToggle(transfer.id),
          color: mornye ? null : color,
          borderRadius: mornye
              ? BorderRadius.vertical(
                  top: index == 0 ? _mornyeRadius : Radius.zero,
                  bottom: index == last ? _mornyeRadius : Radius.zero,
                )
              : connectedRowRadius(
                  context,
                  first: index == 0,
                  last: index == last,
                ),
        ),
      ],
    ];
    Widget group = SliverMainAxisGroup(slivers: slivers);
    if (mornye) {
      group = DecoratedSliver(
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.all(_mornyeRadius),
        ),
        sliver: group,
      );
    }
    // The same edges as the settings groups at any width.
    return SliverLayoutInfoBuilder<double>(
      select: (constraints) => constraints.crossAxisExtent,
      builder: (context, width) => SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: settingsHorizontalInset(context, width),
          vertical: 4,
        ),
        sliver: group,
      ),
    );
  }
}

/// Clear finished: an icon in the Material page header, a text button in
/// the desktop dialog's footer ([text]) and in Mornye.
class _ClearFinishedButton extends StatelessWidget {
  const _ClearFinishedButton({required this.onPressed, this.text = false});

  final VoidCallback onPressed;
  final bool text;

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.linkTransfersClearFinished;
    const key = ValueKey('link-transfers-clear');
    if (context.isMornye) {
      return CupertinoButton(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: Size.square(context.tokens.minTouchTarget),
        onPressed: onPressed,
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    if (text) {
      return ExpressiveButton(
        key: key,
        text: true,
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return AppIconButton(
      key: key,
      tooltip: label,
      icon: const AppIcon(Icons.clear_all_rounded),
      onPressed: onPressed,
    );
  }
}
