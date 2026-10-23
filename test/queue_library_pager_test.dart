import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/queue_library_pager.dart';

class _Request implements QueueLibraryPageKey<_Request> {
  const _Request(this.offset, {this.scope = 'all'});

  @override
  final int offset;
  @override
  int get limit => 2;
  final String scope;

  @override
  bool hasSamePageScope(_Request other) => other.scope == scope;

  @override
  bool operator ==(Object other) =>
      other is _Request && other.offset == offset && other.scope == scope;

  @override
  int get hashCode => Object.hash(offset, scope);
}

class _Page implements QueueLibraryPageContent {
  const _Page(this.rows);

  final List<String> rows;

  @override
  bool get isEmpty => rows.isEmpty;
}

void main() {
  late int combines;
  late QueueLibraryPager<String, _Request, _Page> pager;

  // The combine every Library page uses: rows of all pages, in order.
  _Page combine(List<_Page> pages) {
    combines++;
    if (pages.length == 1) return pages.first;
    return _Page([for (final page in pages) ...page.rows]);
  }

  setUp(() {
    combines = 0;
    pager = QueueLibraryPager(pageSize: 2, combinePages: combine);
  });

  test('combines the loaded pages once per page change', () {
    const first = _Page(['a', 'b']);
    const second = _Page(['c', 'd']);
    pager.resolvePageData(const AsyncData(first), const _Request(0));
    expect(combines, 1);

    final combined = pager.resolvePageData(
      const AsyncData(second),
      const _Request(2),
    );
    expect(combines, 2);
    expect(combined.rows, ['a', 'b', 'c', 'd']);

    // Rebuilds resolve the same pages again (with or without the live value)
    // and get the very same combined object back.
    for (final value in [const AsyncData(second), null]) {
      expect(pager.resolvePageData(value, const _Request(2)), same(combined));
    }
    expect(combines, 2);

    // A refreshed page is a new object, so the rows are combined again.
    const refreshed = _Page(['c', 'e']);
    final updated = pager.resolvePageData(
      const AsyncData(refreshed),
      const _Request(2),
    );
    expect(combines, 3);
    expect(updated.rows, ['a', 'b', 'c', 'e']);
  });

  test('keeps a combined result per scope and drops them on reset', () {
    const songs = [
      _Page(['a', 'b']),
      _Page(['c', 'd']),
    ];
    const singles = [
      _Page(['x', 'y']),
      _Page(['z']),
    ];
    for (final (scope, pages) in [('all', songs), ('singles', singles)]) {
      pager.resolvePageData(AsyncData(pages[0]), _Request(0, scope: scope));
      pager.resolvePageData(AsyncData(pages[1]), _Request(2, scope: scope));
    }
    final count = combines;

    final all = pager.resolvePageData(null, const _Request(2));
    final single = pager.resolvePageData(
      null,
      const _Request(2, scope: 'singles'),
    );
    expect(all.rows, ['a', 'b', 'c', 'd']);
    expect(single.rows, ['x', 'y', 'z']);
    expect(combines, count);

    pager.resetPaging();
    final reloaded = pager.resolvePageData(
      const AsyncData(_Page(['a', 'b'])),
      const _Request(0),
    );
    expect(reloaded.rows, ['a', 'b']);
    expect(combines, count + 1);
  });

  test('the fallback still covers an empty combined page', () {
    const fallback = _Page(['snapshot']);
    expect(
      pager.resolvePageData(
        const AsyncData(_Page([])),
        const _Request(0),
        nonEmptyFallback: () => fallback,
      ),
      same(fallback),
    );
  });
}
