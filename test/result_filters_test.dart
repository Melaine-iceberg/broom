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
}
