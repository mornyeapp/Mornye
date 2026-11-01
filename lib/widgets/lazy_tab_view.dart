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
    SchedulerBinding.instance.addPostFrameCallback(_preloadWhenIdle);
  }

  void _preloadWhenIdle(Duration _) {
    if (!mounted) return;
    final pending = widget.preloadKeys
        .intersection(_tabKeys)
        .difference(_mountedTabs);
    if (pending.isEmpty) {
      _preloadScheduled = false;
      return;
    }
    // Waiting for animation frames avoids the scheduler's busy idle-task loop.
    if (SchedulerBinding.instance.transientCallbackCount > 0) {
      SchedulerBinding.instance.addPostFrameCallback(_preloadWhenIdle);
      return;
    }
    _preloadScheduled = false;
    setState(() => _mountedTabs.addAll(pending));
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

/// Keeps hidden tabs at their last visible window size and without a keyboard.
class _TabInsets extends StatefulWidget {
  const _TabInsets({required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  State<_TabInsets> createState() => _TabInsetsState();
}

class _TabInsetsState extends State<_TabInsets> {
  Size? _visibleSize;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    if (!widget.hidden || _visibleSize == null) _visibleSize = data.size;
    return MediaQuery(
      data: data
          .copyWith(size: _visibleSize)
          .removeViewInsets(removeBottom: widget.hidden),
      child: widget.child,
    );
  }
}
