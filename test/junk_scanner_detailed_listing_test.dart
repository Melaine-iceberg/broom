import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Seeds [files] files two levels deep and reports how many `stat` calls the
  /// scan needed.
  Future<({ScanResult result, int stats})> scanTree({
    required bool useDetailedListing,
    Duration minAge = Duration.zero,
    int files = 40,
  }) async {
    final stats = <String>[];
    final fs = MemoryFileSystem(
      onOperation: (operation, path) {
        if (operation == 'stat') stats.add(path);
      },
    );
    for (var index = 0; index < files; index++) {
      fs.seedFile(
        'C:\\Cache\\dir$index\\file$index.tmp',
        size: index + 1,
        modified: DateTime(2026, 1, 1),
      );
    }
    // Ignored by the extension filter, by the exclusion list, and by type.
    fs.seedFile('C:\\Cache\\dir0\\keep.log', size: 999);
    fs.seedFile('C:\\Cache\\dir0\\excluded\\hidden.tmp', size: 999);
    fs.seedLink('C:\\Cache\\dir0\\link.tmp');

    final scanner = JunkScanner(
      jobs: [
        ScanJob(
          ruleId: 'files',
          roots: const [r'C:\Cache'],
          extensions: const {'tmp'},
          excludedRoots: const [r'C:\Cache\dir0\excluded'],
          minAge: minAge,
        ),
      ],
      fileSystem: fs,
      useDetailedListing: useDetailedListing,
      semantics: const WindowsPathSemantics(),
      clock: () => DateTime(2026, 10, 19),
    );
    return (result: await scanner.scan(), stats: stats.length);
  }

  test('detailed listing finds the same files without any stat call', () async {
    final detailed = await scanTree(useDetailedListing: true);
    final legacy = await scanTree(useDetailedListing: false);

    expect(detailed.stats, 0);
    expect(legacy.stats, 40);
    expect(detailed.result.scannedFiles, legacy.result.scannedFiles);
    expect(detailed.result.directoryErrors, 0);
    expect(
      detailed.result.items.map((item) => item.path.toLowerCase()),
      unorderedEquals(
        legacy.result.items.map((item) => item.path.toLowerCase()),
      ),
    );
    expect(detailed.result.totalBytes, legacy.result.totalBytes);
  });

  test('detailed listing keeps sizes, timestamps and the age filter', () async {
    final fresh = await scanTree(useDetailedListing: true);
    final aged = await scanTree(
      useDetailedListing: true,
      minAge: const Duration(hours: 24),
    );

    // Sizes come from the enumeration itself: 1 + 2 + ... + 40.
    expect(fresh.result.totalBytes, 820);
    expect(fresh.result.items, hasLength(40));
    expect(fresh.result.items.first.modified, DateTime(2026, 1, 1));

    // Every seeded file is older than 24h relative to the fixed clock, so the
    // filter keeps all of them; the point is that the timestamps are usable.
    expect(aged.result.items, hasLength(40));
  });
}
