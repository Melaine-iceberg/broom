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

List<JunkItem> sortResultItems(List<JunkItem> items, ResultItemSort sort) {
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
        final byExtension = extensionOfPath(a.path)
            .compareTo(extensionOfPath(b.path));
        if (byExtension != 0) return byExtension;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    }
  }

  copy.sort((a, b) {
    final result = comparison(a, b);
    if (result != 0) return result;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  });
  return copy;
}

List<JunkItem> visibleResultItems(
  List<JunkItem> items,
  ResultItemFilter filter,
  ResultItemSort sort, {
  DateTime? now,
}) {
  return sortResultItems(filterResultItems(items, filter, now: now), sort);
}
