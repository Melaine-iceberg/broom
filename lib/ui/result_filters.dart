import '../core/models/scan_models.dart';
import 'format.dart';

/// Sort orders offered by the scan preview and the per-rule file list.
enum ResultItemSort {
  sizeDesc,
  sizeAsc,
  modifiedDesc,
  modifiedAsc,
  pathAsc,
  extensionAsc,
}

/// Filters that are applied to the files of one rule. The query matches the
/// full path, so it covers both folder names and file extensions.
class ResultItemFilter {
  const ResultItemFilter({
    this.query = '',
    this.extension,
    this.minimumSize = 0,
    this.olderThan,
    this.lockedOnly = false,
  });

  final String query;

  /// Extension without a leading dot, or null for every extension.
  final String? extension;
  final int minimumSize;
  final Duration? olderThan;
  final bool lockedOnly;

  bool get hasQuery => query.trim().isNotEmpty;

  /// Number of filters beyond the free-text query, used for the filter badge.
  int get activeFilterCount =>
      (extension == null ? 0 : 1) +
      (minimumSize > 0 ? 1 : 0) +
      (olderThan == null ? 0 : 1) +
      (lockedOnly ? 1 : 0);

  bool get hasAdvancedFilters => activeFilterCount > 0;

  ResultItemFilter copyWith({
    String? query,
    String? extension,
    bool clearExtension = false,
    int? minimumSize,
    Duration? olderThan,
    bool clearOlderThan = false,
    bool? lockedOnly,
  }) {
    return ResultItemFilter(
      query: query ?? this.query,
      extension: clearExtension ? null : (extension ?? this.extension),
      minimumSize: minimumSize ?? this.minimumSize,
      olderThan: clearOlderThan ? null : (olderThan ?? this.olderThan),
      lockedOnly: lockedOnly ?? this.lockedOnly,
    );
  }

  /// Value equality, so derived lists can be cached against the filter that
  /// produced them even though the widget rebuilds build a fresh instance.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ResultItemFilter &&
        other.query == query &&
        other.extension == extension &&
        other.minimumSize == minimumSize &&
        other.olderThan == olderThan &&
        other.lockedOnly == lockedOnly;
  }

  @override
  int get hashCode =>
      Object.hash(query, extension, minimumSize, olderThan, lockedOnly);
}

String extensionOfPath(String path) {
  final name = fileNameOf(path);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Returns the distinct extensions in [items], sorted for a filter menu.
List<String> availableExtensions(List<JunkItem> items) {
  final extensions = <String>{};
  for (final item in items) {
    final extension = extensionOfPath(item.path);
    if (extension.isNotEmpty) extensions.add(extension);
  }
  final result = extensions.toList()..sort();
  return result;
}

List<JunkItem> filterResultItems(
  List<JunkItem> items,
  ResultItemFilter filter, {
  DateTime? now,
}) {
  final query = filter.query.trim().toLowerCase();
  final wantedExtension = filter.extension?.toLowerCase();
  final clock = now ?? DateTime.now();
  return [
    for (final item in items)
      if (_matchesQuery(item, query) &&
          (wantedExtension == null ||
              extensionOfPath(item.path) == wantedExtension) &&
          item.size >= filter.minimumSize &&
          (filter.olderThan == null ||
              clock.difference(item.modified) >= filter.olderThan!) &&
          (!filter.lockedOnly || item.possiblyLocked))
        item,
  ];
}

bool _matchesQuery(JunkItem item, String query) {
  if (query.isEmpty) return true;
  final path = item.path.toLowerCase();
  if (path.contains(query)) return true;
  // Windows paths use backslashes; accept paths pasted with forward slashes.
  final normalized = query.replaceAll('/', r'\');
  return normalized != query && path.contains(normalized);
}

/// A sort entry for the orders whose key has to be derived from the path.
///
/// The comparators used to call `toLowerCase()` (and `extensionOfPath`) inside
/// the comparison, which for a 100k-row list means millions of string
/// allocations per sort. Deriving the key once per item removes that, and it
/// only pays for itself when the key is expensive: for the size and time
/// orders the key is already a field on [JunkItem], so those sort the items
/// directly and only derive a lowercase path for the rare equal-key comparison.
class _SortEntry {
  _SortEntry(this.item, {bool withExtension = false})
    : lowerPath = item.path.toLowerCase(),
      extension = withExtension ? extensionOfPath(item.path) : '';

  final JunkItem item;
  final String lowerPath;

  /// Only derived for [ResultItemSort.extensionAsc].
  final String extension;
}

List<JunkItem> sortResultItems(List<JunkItem> items, ResultItemSort sort) {
  if (items.length < 2) return List<JunkItem>.of(items);

  switch (sort) {
    case ResultItemSort.sizeDesc:
    case ResultItemSort.sizeAsc:
    case ResultItemSort.modifiedDesc:
    case ResultItemSort.modifiedAsc:
      return _sortByOrdinal(items, sort);
    case ResultItemSort.pathAsc:
    case ResultItemSort.extensionAsc:
      return _sortByPathKey(items, sort);
  }
}

/// Sorts by a numeric key that is already stored on the item.
///
/// The tie-breaker still compares lowercase paths. It runs inside the
/// comparator on purpose: the cache is only created when two keys actually
/// collide, so a list with distinct sizes or timestamps allocates nothing,
/// while a list of thousands of equal-sized cache fragments still derives each
/// path at most once instead of once per comparison.
List<JunkItem> _sortByOrdinal(List<JunkItem> items, ResultItemSort sort) {
  final copy = List<JunkItem>.of(items);
  Map<JunkItem, String>? lowerPaths;

  String lowerPathOf(JunkItem item) {
    final cache = lowerPaths ??= Map<JunkItem, String>.identity();
    final cached = cache[item];
    if (cached != null) return cached;
    final value = item.path.toLowerCase();
    cache[item] = value;
    return value;
  }

  copy.sort((a, b) {
    final primary = switch (sort) {
      ResultItemSort.sizeDesc => b.size.compareTo(a.size),
      ResultItemSort.sizeAsc => a.size.compareTo(b.size),
      ResultItemSort.modifiedDesc => b.modified.compareTo(a.modified),
      ResultItemSort.modifiedAsc => a.modified.compareTo(b.modified),
      // The path orders are dispatched to _sortByPathKey before we get here.
      ResultItemSort.pathAsc || ResultItemSort.extensionAsc => 0,
    };
    if (primary != 0) return primary;
    return lowerPathOf(a).compareTo(lowerPathOf(b));
  });
  return copy;
}

/// Sorts by keys derived from the path, computed once per item.
List<JunkItem> _sortByPathKey(List<JunkItem> items, ResultItemSort sort) {
  final byExtension = sort == ResultItemSort.extensionAsc;
  final entries = <_SortEntry>[
    for (final item in items) _SortEntry(item, withExtension: byExtension),
  ];
  entries.sort((a, b) {
    final primary = byExtension
        ? a.extension.compareTo(b.extension)
        : a.lowerPath.compareTo(b.lowerPath);
    if (primary != 0) return primary;
    // pathAsc is already ordered by the full path.
    if (!byExtension) return 0;
    return a.lowerPath.compareTo(b.lowerPath);
  });
  return [for (final entry in entries) entry.item];
}

List<JunkItem> visibleResultItems(
  List<JunkItem> items,
  ResultItemFilter filter,
  ResultItemSort sort, {
  DateTime? now,
}) {
  return sortResultItems(filterResultItems(items, filter, now: now), sort);
}

/// Memoises the filtered and sorted view of one rule's items.
///
/// Building a preview page runs [visibleResultItems] on every rebuild, and the
/// controller notifies listeners at least every 250 ms while the lock probe is
/// running. At 100k items that is tens of milliseconds of repeated work per
/// notification for input that rarely changed, so the result is keyed on
/// `(source, filter, sort, version)`.
///
/// [version] must be bumped by the controller whenever the content of the
/// source items changes (`possiblyLocked` flips included), otherwise the cache
/// would keep serving items with stale flags.
class VisibleItemsCache {
  List<JunkItem>? _visible;
  List<JunkItem>? _source;
  ResultItemFilter? _filter;
  ResultItemSort? _sort;
  int? _version;

  /// How many times the visible list was actually recomputed. Kept for tests
  /// and diagnostics: the whole point of this class is that it stays flat
  /// across repeated rebuilds.
  int get recomputeCount => _recomputeCount;
  int _recomputeCount = 0;

  List<JunkItem> resolve(
    List<JunkItem> source,
    ResultItemFilter filter,
    ResultItemSort sort, {
    required int version,
    DateTime? now,
  }) {
    final cached = _visible;
    if (cached != null &&
        identical(_source, source) &&
        _version == version &&
        _sort == sort &&
        _filter == filter) {
      return cached;
    }
    final computed = visibleResultItems(source, filter, sort, now: now);
    _source = source;
    _visible = computed;
    _filter = filter;
    _sort = sort;
    _version = version;
    _recomputeCount++;
    return computed;
  }

  /// Drops the memoised list, e.g. when the page is handed a different source.
  void invalidate() {
    _visible = null;
    _source = null;
    _filter = null;
    _sort = null;
    _version = null;
  }
}
