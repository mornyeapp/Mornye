import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/together/link_together_controller.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/download_state_switcher.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

/// The Play together choice of the Devices sheet, a [SettingsItem] so it
/// joins the device choices' group: [check]ed while it runs, a spinner while
/// it starts, and its trailing control switches like a download row's.
SettingsItem linkPlayTogetherItem(
  BuildContext context, {
  required LinkTogetherState together,
  required String name,
  required Widget check,
  required VoidCallback? onTap,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  final (state, trailing) = switch (together.phase) {
    LinkTogetherPhase.active => ('on', check),
    LinkTogetherPhase.starting => (
      'starting',
      const SizedBox.square(
        dimension: 20,
        child: AppProgressIndicator.circular(strokeWidth: 2, wavy: false),
      ),
    ),
    // The chevron a tappable row draws by itself, here so it can switch.
    LinkTogetherPhase.idle when onTap != null => (
      'off',
      AppIcon(
        context.isMornye ? CupertinoIcons.forward : Icons.chevron_right,
        size: context.tokens.rowChevronSize,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    LinkTogetherPhase.idle => ('unavailable', const SizedBox.shrink()),
  };
  return SettingsItem(
    key: const ValueKey('link-play-together'),
    icon: Icons.devices,
    title: context.l10n.linkPlayTogether,
    titleTrailing: const BetaBadge(),
    subtitle: context.l10n.linkPlayTogetherSubtitle(name),
    trailing: DownloadStateSwitcher(state: state, child: trailing),
    selected: together.phase == LinkTogetherPhase.active,
    onTap: together.active ? null : onTap,
    showDivider: false,
  );
}

/// Starts Play together from the Devices sheet at [context]. The sheet
/// stays open for the timing slider; when the start fails it closes, so
/// the reason shows.
Future<void> linkStartPlayTogether(BuildContext context, WidgetRef ref) async {
  final client = ref.read(linkPhoneClientProvider);
  if (client == null) return;
  final together = ref.read(linkPlayTogetherProvider.notifier);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  final name = linkDesktopName(client);
  final outcome = await together.start();
  final message = switch (outcome) {
    LinkTogetherStart.started => null,
    LinkTogetherStart.nothingPlaying => l10n.linkHandoffNothingPlaying,
    LinkTogetherStart.needsUpdate => l10n.linkPlayTogetherNeedsUpdate(name),
    LinkTogetherStart.failed => l10n.linkPlayTogetherFailed(name),
  };
  if (message == null) return;
  if (context.mounted) Navigator.pop(context);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}

/// The phone timing as the slider shows it: signed with a real minus sign,
/// in milliseconds.
String linkPlayTogetherTimingLabel(AppLocalizations l10n, int shiftMs) {
  final digits = NumberFormat.decimalPattern(
    l10n.localeName,
  ).format(shiftMs.abs());
  final sign = shiftMs > 0
      ? '+'
      : shiftMs < 0
      ? '−'
      : '';
  return l10n.linkPlayTogetherTimingValue('$sign$digits');
}

/// The phone timing slider of the Devices sheet, in its own group under the
/// device choices while Play together runs.
class LinkPlayTogetherTiming extends ConsumerWidget {
  const LinkPlayTogetherTiming({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(
      linkPlayTogetherProvider.select(
        (state) => state.phase == LinkTogetherPhase.active,
      ),
    );
    return LinkTogetherReveal(
      child: visible
          ? const _TimingGroup(key: ValueKey('link-together-timing'))
          : null,
    );
  }
}

/// What a computer's Devices sheet shows while it plays together with the
/// phone [name]: a checked Play together row in its own group under the
/// device choices. The phone starts and times it, so the row is not a
/// button; choosing a device above ends it.
class LinkDesktopPlayTogether extends StatelessWidget {
  const LinkDesktopPlayTogether({super.key, required this.name});

  /// The phone's name, or null while this computer plays alone.
  final String? name;

  @override
  Widget build(BuildContext context) {
    final name = this.name;
    return LinkTogetherReveal(
      child: name == null
          ? null
          : SettingsGroup(
              key: const ValueKey('desktop-link-together'),
              children: [
                SettingsItem(
                  icon: Icons.devices,
                  title: context.l10n.linkPlayTogether,
                  titleTrailing: const BetaBadge(),
                  subtitle: context.l10n.linkDesktopPlayTogetherSubtitle(name),
                  trailing: AppIcon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  selected: true,
                  showDivider: false,
                ),
              ],
            ),
    );
  }
}

/// Opens and closes a group of the Devices sheet that only shows while Play
/// together runs; [child] is null while it is closed. It slides open on the
/// slow spatial spring, which stops at its size because the rows below move
/// with it, and fades in on the effects spring; closing is shorter.
class LinkTogetherReveal extends StatelessWidget {
  const LinkTogetherReveal({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final visible = child != null;
    final tokens = context.tokens;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final entrance = AppMotionSpec(
      reduced ? Duration.zero : tokens.motionMedium,
      Curves.easeInOut,
    );
    final exit = AppMotionSpec(
      reduced ? Duration.zero : tokens.motionFast,
      Curves.easeInOut,
    );
    final size = visible
        ? AppMotion.spatialSlow(context, entrance)
        : AppMotion.spatial(context, exit);
    final fadeIn = AppMotion.effects(context, entrance);
    final fadeOut = AppMotion.effectsFast(context, exit);
    final switcher = AnimatedSwitcher(
      duration: fadeIn.duration,
      reverseDuration: fadeOut.duration,
      switchInCurve: fadeIn.curve,
      switchOutCurve: fadeOut.leaving,
      // Only the shown child sizes the switcher, so the group closes while
      // the leaving one fades.
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [
          for (final child in previous)
            PositionedDirectional(top: 0, start: 0, end: 0, child: child),
          ?current,
        ],
      ),
      child: child ?? const SizedBox(width: double.infinity),
    );
    // With reduced motion the size changes at once. A size animation of no
    // length would finish inside its own layout, which the framework
    // rejects.
    if (size.duration == Duration.zero) return switcher;
    return AnimatedSize(
      duration: size.duration,
      curve: size.curve,
      alignment: AlignmentDirectional.topStart,
      child: switcher,
    );
  }
}

class _TimingGroup extends ConsumerStatefulWidget {
  const _TimingGroup({super.key});

  @override
  ConsumerState<_TimingGroup> createState() => _TimingGroupState();
}

class _TimingGroupState extends ConsumerState<_TimingGroup> {
  int? _draft;

  static int _rounded(double value) => (value / 10).round() * 10;

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(
      linkPlayTogetherProvider.select((state) => state.shiftMs),
    );
    final shift = _draft ?? saved;
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    final label = linkPlayTogetherTimingLabel(l10n, shift);
    final small = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    const max = LinkPlayTogether.maxShiftMs;
    return SettingsGroup(
      connected: true,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.rowPaddingH,
            vertical: tokens.rowPaddingV,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SliderValueHeader(
                title: l10n.linkPlayTogetherTiming,
                value: label,
              ),
              AppSlider(
                key: const ValueKey('link-together-timing-slider'),
                value: shift.toDouble(),
                min: -max.toDouble(),
                max: max.toDouble(),
                centered: true,
                label: label,
                semanticLabel: l10n.linkPlayTogetherTiming,
                semanticFormatterCallback: (value) =>
                    linkPlayTogetherTimingLabel(l10n, _rounded(value)),
                onChanged: (value) => setState(() => _draft = _rounded(value)),
                // The expressive slider ends with the value it last built
                // with, which a quick release can leave behind the drag.
                onChangeEnd: (value) {
                  unawaited(
                    ref
                        .read(linkPlayTogetherProvider.notifier)
                        .setShift(_draft ?? _rounded(value)),
                  );
                  setState(() => _draft = null);
                },
              ),
              DefaultTextStyle(
                style: small,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(l10n.linkPlayTogetherEarlier)),
                    SizedBox(width: tokens.gapMd),
                    Expanded(
                      child: Text(
                        l10n.linkPlayTogetherLater,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: tokens.gapSm),
              Text(l10n.linkPlayTogetherTimingHint, style: small),
            ],
          ),
        ),
      ],
    );
  }
}
