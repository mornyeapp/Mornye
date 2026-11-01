import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Retains visited tabs without scrolling their pages out of the viewport.
/// Give children stable keys so adding/removing a destination preserves state.
class LazyTabView extends StatefulWidget {
  const LazyTabView({
    super.key,
    required this.index,
    required this.children,
    this.preloadKeys = const {},
  });

  final int index;
  final List<Widget> children;
  final Set<Key> preloadKeys;

  @override
  State<LazyTabView> createState() => _LazyTabViewState();
}

class _LazyTabViewState extends State<LazyTabView> {
  final _mountedTabs = <Key>{};
  bool _preloadScheduled = false;

  Key _tabKey(int index) => widget.children[index].key ?? ValueKey(index);

  Set<Key> get _tabKeys => {
    for (var index = 0; index < widget.children.length; index++) _tabKey(index),
  };

  @override
  void initState() {
    super.initState();
    _mountedTabs.add(_tabKey(widget.index));
    _schedulePreload();
  }

  @override
  void didUpdateWidget(covariant LazyTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _mountedTabs.retainAll(_tabKeys);
    _mountedTabs.add(_tabKey(widget.index));
    _schedulePreload();
  }

  void _schedulePreload() {
    if (_preloadScheduled ||
        widget.preloadKeys
            .intersection(_tabKeys)
            .difference(_mountedTabs)
            .isEmpty) {
      return;
    }
    _preloadScheduled = true;
    // Mount Search between animations rather than during its first tab switch.
    SchedulerBinding.instance.scheduleTask<void>(
      () {
        _preloadScheduled = false;
        if (!mounted) return;
        final pending = widget.preloadKeys
            .intersection(_tabKeys)
            .difference(_mountedTabs);
        if (pending.isNotEmpty) setState(() => _mountedTabs.addAll(pending));
      },
      Priority.idle,
      debugLabel: 'Preload navigation tab',
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (var index = 0; index < widget.children.length; index++)
        Visibility(
          key: _tabKey(index),
          visible: index == widget.index,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: ExcludeFocus(
            excluding: index != widget.index,
            child: TickerMode(
              enabled: index == widget.index,
              child: _TabInsets(
                hidden: index != widget.index,
                child: _mountedTabs.contains(_tabKey(index))
                    ? widget.children[index]
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Keeps the keyboard inset from hidden tabs, so their scaffolds do not
/// relayout on every keyboard frame while they are not painted.
class _TabInsets extends StatelessWidget {
  const _TabInsets({required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).removeViewInsets(removeBottom: hidden),
    child: child,
  );
}
