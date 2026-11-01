import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/lazy_tab_view.dart';

void main() {
  testWidgets(
    'Search preloads at idle without mounting other tabs or taking focus',
    (tester) async {
      final initialized = <String, int>{};
      final animation = AnimationController(vsync: tester)
        ..repeat(period: const Duration(seconds: 1));
      addTearDown(animation.dispose);
      final searchFocus = FocusNode();
      addTearDown(searchFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LazyTabView(
            index: 0,
            preloadKeys: {const ValueKey('search')},
            children: [
              _Tab(
                key: const ValueKey('home'),
                name: 'home',
                initialized: initialized,
              ),
              _Tab(
                key: const ValueKey('library'),
                name: 'library',
                initialized: initialized,
              ),
              _Tab(
                key: const ValueKey('search'),
                name: 'search',
                initialized: initialized,
                focusNode: searchFocus,
              ),
            ],
          ),
        ),
      );
      tester.binding.handleEventLoopCallback();
      expect(initialized, {'home': 1});
      animation.stop();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(initialized, {'home': 1, 'search': 1});
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(searchFocus.canRequestFocus, isFalse);
      searchFocus.requestFocus();
      await tester.pump();
      expect(searchFocus.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'visited Search retains text across switches, resize and Repo changes',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final initialized = <String, int>{};
      final selected = ValueNotifier('home');
      final showRepo = ValueNotifier(false);
      addTearDown(selected.dispose);
      addTearDown(showRepo.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: Listenable.merge([selected, showRepo]),
            builder: (context, _) {
              final names = [
                'home',
                'library',
                if (showRepo.value) 'repo',
                'search',
              ];
              return LazyTabView(
                index: names.indexOf(selected.value),
                children: [
                  for (final name in names)
                    _Tab(
                      key: ValueKey(name),
                      name: name,
                      initialized: initialized,
                    ),
                ],
              );
            },
          ),
        ),
      );
      selected.value = 'search';
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).hitTestable(),
        'A retained query',
      );
      selected.value = 'library';
      await tester.pump();
      showRepo.value = true;
      tester.view.physicalSize = const Size(932, 430);
      await tester.pump();
      selected.value = 'search';
      await tester.pump();
      expect(find.text('A retained query'), findsOneWidget);
      showRepo.value = false;
      await tester.pump();
      expect(find.text('A retained query'), findsOneWidget);
      expect(initialized, {'home': 1, 'search': 1, 'library': 1});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden tab tickers pause and resume without remounting', (
    tester,
  ) async {
    final initialized = <String, int>{};
    final ticks = <String, int>{};
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: selected,
          builder: (context, index, _) => LazyTabView(
            index: index,
            children: [
              for (final name in ['home', 'search'])
                _Tab(
                  key: ValueKey(name),
                  name: name,
                  initialized: initialized,
                  ticks: ticks,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    selected.value = 1;
    await tester.pump();
    final homeTicks = ticks['home'];
    await tester.pump(const Duration(milliseconds: 100));
    expect(ticks['home'], homeTicks);
    expect(ticks['search'], greaterThan(0));
    selected.value = 0;
    await tester.pump();
    final searchTicks = ticks['search'];
    await tester.pump(const Duration(milliseconds: 100));
    expect(ticks['search'], searchTicks);
    expect(ticks['home'], greaterThan(homeTicks!));
    expect(initialized, {'home': 1, 'search': 1});
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden tabs ignore keyboard frames until shown', (tester) async {
    final initialized = <String, int>{};
    final insets = <String, List<double>>{};
    final selected = ValueNotifier(1);
    final keyboard = ValueNotifier(0.0);
    addTearDown(selected.dispose);
    addTearDown(keyboard.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable: keyboard,
          builder: (context, bottom, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: EdgeInsets.only(bottom: bottom)),
            child: child!,
          ),
        ),
        home: ValueListenableBuilder<int>(
          valueListenable: selected,
          builder: (context, index, _) => LazyTabView(
            index: index,
            children: [
              for (final name in ['home', 'search'])
                _Tab(
                  key: ValueKey(name),
                  name: name,
                  initialized: initialized,
                  insets: insets,
                ),
            ],
          ),
        ),
      ),
    );
    selected.value = 0;
    await tester.pump();
    insets.clear();
    for (final bottom in [100.0, 200.0, 300.0]) {
      keyboard.value = bottom;
      await tester.pump();
    }
    expect(insets, {
      'home': [100.0, 200.0, 300.0],
    });
    selected.value = 1;
    await tester.pump();
    expect(insets['search'], [300.0]);
    expect(initialized, {'home': 1, 'search': 1});
  });

  testWidgets('preloading waits on frames without queueing idle tasks', (
    tester,
  ) async {
    final initialized = <String, int>{};
    final animation = AnimationController(vsync: tester)
      ..repeat(period: const Duration(seconds: 1));
    addTearDown(animation.dispose);
    final oldStrategy = tester.binding.schedulingStrategy;
    var idleTasks = 0;
    tester.binding.schedulingStrategy =
        ({required priority, required scheduler}) {
          idleTasks++;
          return true;
        };
    addTearDown(() => tester.binding.schedulingStrategy = oldStrategy);
    await tester.pumpWidget(
      MaterialApp(
        home: LazyTabView(
          index: 0,
          preloadKeys: {const ValueKey('search')},
          children: [
            for (final name in ['home', 'search'])
              _Tab(key: ValueKey(name), name: name, initialized: initialized),
          ],
        ),
      ),
    );
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(idleTasks, 0);
    expect(initialized, {'home': 1});
    animation.stop();
    await tester.pumpAndSettle();
    expect(initialized, {'home': 1, 'search': 1});
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.binding.handleEventLoopCallback(), isFalse);
  });

  testWidgets('pending preload is harmless after removal and disposal', (
    tester,
  ) async {
    final initialized = <String, int>{};
    final animation = AnimationController(vsync: tester)
      ..repeat(period: const Duration(seconds: 1));
    addTearDown(animation.dispose);
    final preload = ValueNotifier(true);
    addTearDown(preload.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: preload,
          builder: (context, enabled, _) => LazyTabView(
            index: 0,
            preloadKeys: enabled ? {const ValueKey('search')} : {},
            children: [
              for (final name in ['home', 'search'])
                _Tab(key: ValueKey(name), name: name, initialized: initialized),
            ],
          ),
        ),
      ),
    );
    preload.value = false;
    await tester.pump();
    animation.stop();
    await tester.pumpAndSettle();
    expect(initialized, {'home': 1});
    animation.repeat(period: const Duration(seconds: 1));
    preload.value = true;
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    animation.stop();
    await tester.pumpAndSettle();
    expect(initialized, {'home': 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden resize freezes size but retains scroll and accessibility',
    (tester) async {
      final selected = ValueNotifier(1);
      final media = ValueNotifier(const MediaQueryData(size: Size(1000, 800)));
      final scroll = ScrollController();
      addTearDown(selected.dispose);
      addTearDown(media.dispose);
      addTearDown(scroll.dispose);
      final samples = <(Size, double)>[];
      final children = [
        const SizedBox(key: ValueKey('home')),
        Builder(
          key: const ValueKey('search'),
          builder: (context) {
            final size = MediaQuery.sizeOf(context);
            final scale = MediaQuery.textScalerOf(context).scale(14);
            samples.add((size, scale));
            return ListView.builder(
              controller: scroll,
              itemCount: 100,
              itemExtent: 50,
              itemBuilder: (_, index) => Text('Song $index'),
            );
          },
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<MediaQueryData>(
            valueListenable: media,
            builder: (context, data, child) =>
                MediaQuery(data: data, child: child!),
            child: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (context, index, _) =>
                  LazyTabView(index: index, children: children),
            ),
          ),
        ),
      );
      scroll.jumpTo(1000);
      await tester.pump();
      selected.value = 0;
      await tester.pump();
      samples.clear();
      for (var frame = 0; frame < 10; frame++) {
        media.value = media.value.copyWith(size: Size(1010 + frame * 10, 800));
        await tester.pump();
      }
      expect(samples, isEmpty);
      expect(scroll.offset, 1000);
      media.value = media.value.copyWith(textScaler: TextScaler.linear(2));
      await tester.pump();
      expect(samples, [(const Size(1000, 800), 28.0)]);
      samples.clear();
      selected.value = 1;
      await tester.pump();
      expect(samples, [(const Size(1100, 800), 28.0)]);
      expect(scroll.offset, 1000);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Tab extends StatefulWidget {
  const _Tab({
    super.key,
    required this.name,
    required this.initialized,
    this.focusNode,
    this.ticks,
    this.insets,
  });

  final String name;
  final Map<String, int> initialized;
  final FocusNode? focusNode;
  final Map<String, int>? ticks;

  /// Keyboard insets this tab's content was built with.
  final Map<String, List<double>>? insets;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with SingleTickerProviderStateMixin {
  final _text = TextEditingController();
  AnimationController? _animation;

  @override
  void initState() {
    super.initState();
    widget.initialized.update(
      widget.name,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    if (widget.ticks != null) {
      _animation = AnimationController(vsync: this)
        ..addListener(
          () => widget.ticks!.update(
            widget.name,
            (count) => count + 1,
            ifAbsent: () => 1,
          ),
        )
        ..repeat(period: const Duration(seconds: 1));
    }
  }

  @override
  void dispose() {
    _animation?.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) {
      final bottom = MediaQuery.viewInsetsOf(context).bottom;
      widget.insets?.putIfAbsent(widget.name, () => []).add(bottom);
      return Scaffold(
        body: TextField(controller: _text, focusNode: widget.focusNode),
      );
    },
  );
}
