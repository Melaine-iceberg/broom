import 'dart:math';

import 'package:broom/core/models/scan_models.dart';
import 'package:broom/ui/result_filters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

JunkItem _item(
  String name, {
  int size = 10,
  DateTime? modified,
  bool locked = false,
  String root = r'C:\cache',
}) {
  return JunkItem(
    ruleId: 'test.cache',
    rootPath: root,
    path: p.windows.join(root, name),
    size: size,
    modified: modified ?? DateTime(2026, 1, 1),
    possiblyLocked: locked,
  );
}

void main() {
  final items = [
    _item('alpha.tmp', size: 300, modified: DateTime(2026, 1, 1), locked: true),
    _item('beta.log', size: 100, modified: DateTime(2026, 6, 1)),
    _item('gamma.tmp', size: 200, modified: DateTime(2026, 3, 1)),
  ];

  test('filters by path query and extension', () {
    expect(
      filterResultItems(
        items,
        const ResultItemFilter(query: 'alpha'),
      ).map((item) => p.windows.basename(item.path)),
      ['alpha.tmp'],
    );
    expect(
      filterResultItems(items, const ResultItemFilter(extension: 'tmp')).length,
      2,
    );
    expect(
      filterResultItems(items, const ResultItemFilter(query: 'CACHE')).length,
      3,
    );
    expect(
      filterResultItems(
        items,
        const ResultItemFilter(query: 'cache/alpha'),
      ).map((item) => p.windows.basename(item.path)),
      ['alpha.tmp'],
    );
  });

  test('filters by size, age and lock state', () {
    final now = DateTime(2026, 10, 1);
    expect(
      filterResultItems(
        items,
        const ResultItemFilter(minimumSize: 150),
      ).map((item) => p.windows.basename(item.path)),
      ['alpha.tmp', 'gamma.tmp'],
    );
    expect(
      filterResultItems(
        items,
        const ResultItemFilter(olderThan: Duration(days: 200)),
        now: now,
      ).map((item) => p.windows.basename(item.path)),
      ['alpha.tmp', 'gamma.tmp'],
    );
    expect(
      filterResultItems(
        items,
        const ResultItemFilter(lockedOnly: true),
      ).map((item) => p.windows.basename(item.path)),
      ['alpha.tmp'],
    );
  });

  test('sorts by size, age, path and extension', () {
    List<String> names(ResultItemSort sort) => sortResultItems(
      items,
      sort,
    ).map((item) => p.windows.basename(item.path)).toList();

    expect(names(ResultItemSort.sizeDesc), [
      'alpha.tmp',
      'gamma.tmp',
      'beta.log',
    ]);
    expect(names(ResultItemSort.sizeAsc), [
      'beta.log',
      'gamma.tmp',
      'alpha.tmp',
    ]);
    expect(names(ResultItemSort.modifiedDesc), [
      'beta.log',
      'gamma.tmp',
      'alpha.tmp',
    ]);
    expect(names(ResultItemSort.pathAsc), [
      'alpha.tmp',
      'beta.log',
      'gamma.tmp',
    ]);
    expect(names(ResultItemSort.extensionAsc), [
      'beta.log',
      'alpha.tmp',
      'gamma.tmp',
    ]);
  });

  test('reports extensions and filter counts', () {
    expect(availableExtensions(items), ['log', 'tmp']);
    expect(extensionOfPath(r'C:\cache\archive.tar.gz'), 'gz');
    expect(extensionOfPath(r'C:\cache\no-extension'), isEmpty);

    const filter = ResultItemFilter(
      query: 'x',
      extension: 'tmp',
      minimumSize: 1,
      olderThan: Duration(days: 1),
      lockedOnly: true,
    );
    expect(filter.activeFilterCount, 4);
    expect(filter.hasAdvancedFilters, isTrue);
    expect(filter.copyWith(clearExtension: true).extension, isNull);
  });

  test('compares filters by value', () {
    const base = ResultItemFilter(query: 'x', minimumSize: 2);
    const same = ResultItemFilter(query: 'x', minimumSize: 2);

    expect(base, same);
    expect(base.hashCode, same.hashCode);
    expect(base, isNot(const ResultItemFilter(query: 'y', minimumSize: 2)));
    expect(base, isNot(base.copyWith(minimumSize: 3)));
    expect(
      const ResultItemFilter(olderThan: Duration(days: 3)),
      const ResultItemFilter(olderThan: Duration(days: 3)),
    );
    expect(
      const ResultItemFilter(olderThan: Duration(days: 3)),
      isNot(const ResultItemFilter(olderThan: Duration(days: 4))),
    );
    expect(
      const ResultItemFilter(lockedOnly: true),
      isNot(const ResultItemFilter()),
    );
  });

  test('decorated sort matches a comparator-based sort', () {
    // Duplicate sizes, timestamps and extensions force the tie-breaker path.
    final random = Random(7);
    final generated = [
      for (var index = 0; index < 300; index++)
        _item(
          'dir${index % 11}/file$index.${['tmp', 'log', 'bin'][index % 3]}',
          size: random.nextInt(6),
          modified: DateTime(2026, 1 + random.nextInt(5), 1),
        ),
    ];

    for (final sort in ResultItemSort.values) {
      expect(
        sortResultItems(generated, sort).map((item) => item.path),
        _referenceSort(generated, sort),
        reason: 'sort order $sort must be unchanged by the decoration',
      );
    }
    // The input list is never reordered in place.
    expect(generated.first.path, endsWith('file0.tmp'));
  });

  test('reuses the visible list until filter, sort or content changes', () {
    final cache = VisibleItemsCache();
    const filter = ResultItemFilter();

    final first = cache.resolve(
      items,
      filter,
      ResultItemSort.sizeDesc,
      version: 3,
    );
    expect(first, hasLength(3));
    expect(cache.recomputeCount, 1);

    // A rebuild with an equal but freshly constructed filter is a cache hit.
    final second = cache.resolve(
      items,
      const ResultItemFilter(),
      ResultItemSort.sizeDesc,
      version: 3,
    );
    expect(identical(first, second), isTrue);
    expect(cache.recomputeCount, 1);

    // The lock probe replaced an item: the cached view must be dropped.
    cache.resolve(items, filter, ResultItemSort.sizeDesc, version: 4);
    expect(cache.recomputeCount, 2);
    cache.resolve(items, filter, ResultItemSort.sizeDesc, version: 4);
    expect(cache.recomputeCount, 2);

    cache.resolve(
      items,
      const ResultItemFilter(query: 'alpha'),
      ResultItemSort.sizeDesc,
      version: 4,
    );
    expect(cache.recomputeCount, 3);

    cache.resolve(
      items,
      const ResultItemFilter(query: 'alpha'),
      ResultItemSort.pathAsc,
      version: 4,
    );
    expect(cache.recomputeCount, 4);

    // A different source list (new result set) is a miss even at the same
    // version, so a page handed new results never shows the old ones.
    cache.resolve(
      List<JunkItem>.of(items),
      const ResultItemFilter(query: 'alpha'),
      ResultItemSort.pathAsc,
      version: 4,
    );
    expect(cache.recomputeCount, 5);

    cache.invalidate();
    cache.resolve(items, filter, ResultItemSort.sizeDesc, version: 4);
    expect(cache.recomputeCount, 6);
  });
}

/// The pre-optimisation implementation: lowercase paths and extensions are
/// derived inside the comparator. Kept as an oracle for [sortResultItems].
List<String> _referenceSort(List<JunkItem> items, ResultItemSort sort) {
  final copy = List<JunkItem>.of(items);
  int comparison(JunkItem a, JunkItem b) {
    switch (sort) {
      case ResultItemSort.sizeDesc:
        return b.size.compareTo(a.size);
      case ResultItemSort.sizeAsc:
        return a.size.compareTo(b.size);
      case ResultItemSort.modifiedDesc:
        return b.modified.compareTo(a.modified);
      case ResultItemSort.modifiedAsc:
        return a.modified.compareTo(b.modified);
      case ResultItemSort.pathAsc:
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      case ResultItemSort.extensionAsc:
        return extensionOfPath(a.path).compareTo(extensionOfPath(b.path));
    }
  }

  copy.sort((a, b) {
    final result = comparison(a, b);
    if (result != 0) return result;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return copy.map((item) => item.path).toList();
}
