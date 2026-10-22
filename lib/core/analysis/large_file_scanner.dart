import '../models/analysis_models.dart';
import '../platform/file_system.dart';
import '../platform/path_semantics.dart';
import 'file_tree_walker.dart';

const defaultLargeFileMinSize = 100 * 1024 * 1024;
const defaultLargeFileMaxResults = 200;

/// Lists the largest files under a directory. Read-only by design.
class LargeFileScanner {
  LargeFileScanner({
    required this.root,
    this.minFileSize = defaultLargeFileMinSize,
    this.maxResults = defaultLargeFileMaxResults,
    this.maxFiles = defaultAnalysisMaxFiles,
    this.excludedPaths = const [],
    this.fileSystem = const IoFileSystem(),
    this.useDetailedListing = true,
    PathSemantics? semantics,
  }) : semantics = semantics ?? PathSemanticsFactory.forCurrentPlatform();

  final String root;
  final int minFileSize;
  final int maxResults;
  final int maxFiles;
  final List<String> excludedPaths;
  final BroomFileSystem fileSystem;
  final bool useDetailedListing;
  final PathSemantics semantics;

  Future<LargeFileScanReport> scan({
    void Function(LargeFileProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final matches = <LargeFileEntry>[];

    final walkResult =
        await FileTreeWalker(
          root: root,
          excludedPaths: excludedPaths,
          maxFiles: maxFiles,
          fileSystem: fileSystem,
          useDetailedListing: useDetailedListing,
          semantics: semantics,
        ).walk(
          onFile: (path, stat) {
            if (stat.size < minFileSize) return;
            matches.add(
              LargeFileEntry(
                path: path,
                size: stat.size,
                modified: stat.modified,
              ),
            );
          },
          onProgress: (scannedFiles, scannedBytes, currentPath) {
            onProgress?.call(
              LargeFileProgress(
                scannedFiles: scannedFiles,
                scannedBytes: scannedBytes,
                matchedFiles: matches.length,
                currentPath: currentPath,
              ),
            );
          },
          isCancelled: isCancelled,
        );

    if (walkResult.rootMissing) {
      throw StateError('选择的目录不存在或无法读取。');
    }

    matches.sort((a, b) {
      final bySize = b.size.compareTo(a.size);
      if (bySize != 0) return bySize;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });

    final matchedBytes = matches.fold<int>(
      0,
      (total, file) => total + file.size,
    );
    final visible = matches.take(maxResults).toList(growable: false);

    onProgress?.call(
      LargeFileProgress(
        scannedFiles: walkResult.scannedFiles,
        scannedBytes: walkResult.scannedBytes,
        matchedFiles: matches.length,
      ),
    );

    return LargeFileScanReport(
      files: List.unmodifiable(visible),
      matchedCount: matches.length,
      matchedBytes: matchedBytes,
      scannedFiles: walkResult.scannedFiles,
      scannedBytes: walkResult.scannedBytes,
      errorCount: walkResult.errorCount,
      truncated: walkResult.truncated,
      cancelled: walkResult.cancelled,
    );
  }
}
