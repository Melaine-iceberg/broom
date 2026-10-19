import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/memory_file_system.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/scan/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scans a file tree entirely through the injected filesystem', () async {
    final fs = MemoryFileSystem()
      ..seedFile(r'C:\Cache\Chrome\one.tmp', size: 10)
      ..seedFile(r'C:\Cache\Chrome\nested\two.tmp', size: 20)
      ..seedFile(r'C:\Cache\Chrome\skip.log', size: 30)
      ..seedFile(r'C:\Cache\Chrome\excluded\ignored.tmp', size: 40)
      ..seedLink(r'C:\Cache\Chrome\link.tmp');

    final scanner = JunkScanner(
      jobs: [
        ScanJob(
          ruleId: 'chrome',
          roots: [r'C:\Cache\Chrome'],
          extensions: const {'tmp'},
          excludedRoots: [r'C:\Cache\Chrome\excluded'],
        ),
      ],
      fileSystem: fs,
      semantics: const WindowsPathSemantics(),
      clock: () => DateTime(2026, 10, 19),
    );

    final result = await scanner.scan();
    expect(result.directoryErrors, 0);
    expect(result.scannedFiles, 2);
    expect(result.items, hasLength(2));
    expect(result.totalBytes, 30);
    expect(
      result.items.map((item) => item.path.toLowerCase()),
      unorderedEquals([
        r'c:\cache\chrome\one.tmp',
        r'c:\cache\chrome\nested\two.tmp',
      ]),
    );
  });

  test('streams batches from an in-memory tree without disk timing', () async {
    final fs = MemoryFileSystem();
    for (var index = 0; index < 600; index++) {
      fs.seedFile('C:\\Cache\\batch\\$index.tmp', size: index % 7);
    }

    final scanner = JunkScanner(
      jobs: const [
        ScanJob(ruleId: 'batch', roots: [r'C:\Cache\batch']),
      ],
      fileSystem: fs,
      batchSize: 100,
      semantics: const WindowsPathSemantics(),
    );

    final batches = <int>[];
    var found = 0;
    final result = await scanner.scan(
      retainItems: false,
      onItems: (items) {
        batches.add(items.length);
        found += items.length;
      },
    );

    expect(found, 600);
    expect(result.scannedFiles, 600);
    expect(result.items, isEmpty);
    expect(batches.reduce((a, b) => a + b), 600);
    expect(batches.every((length) => length <= 100), isTrue);
    expect(batches.length, 6);
  });
}
