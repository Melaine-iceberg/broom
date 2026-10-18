import 'package:broom/app.dart';
import 'package:broom/core/analysis/analysis_service.dart';
import 'package:broom/core/models/analysis_models.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:broom/ui/duplicate_finder_page.dart';
import 'package:broom/ui/large_files_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSystemShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async =>
      r'C:\Users\Alice\Downloads';

  @override
  Future<String?> pickJsonFile({
    String? initialDirectory,
    String? title,
  }) async => null;

  @override
  Future<String?> saveJsonFile({
    required String suggestedName,
    String? initialDirectory,
    String? title,
  }) async => null;

  @override
  Future<DiskSpaceSnapshot> queryDiskSpace(String path) async =>
      const DiskSpaceSnapshot(freeBytes: 1000000, totalBytes: 2000000);

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);

  @override
  Future<void> revealPath(String path) async {}
}

class _FakeRunner implements AnalysisRunner {
  _FakeRunner({this.duplicateReport, this.largeReport});

  final DuplicateScanReport? duplicateReport;
  final LargeFileScanReport? largeReport;
  bool disposed = false;

  @override
  bool get isRunning => false;

  @override
  Future<DuplicateScanReport> findDuplicates({
    required String root,
    required int minFileSize,
    required List<String> excludedPaths,
    void Function(DuplicateProgress progress)? onProgress,
  }) async {
    expect(root, r'C:\Users\Alice\Downloads');
    return duplicateReport!;
  }

  @override
  Future<LargeFileScanReport> findLargeFiles({
    required String root,
    required int minFileSize,
    required int maxResults,
    required List<String> excludedPaths,
    void Function(LargeFileProgress progress)? onProgress,
  }) async {
    expect(root, r'C:\Users\Alice\Downloads');
    return largeReport!;
  }

  @override
  void cancel() {}

  @override
  void dispose() {
    disposed = true;
  }
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: buildBroomTheme(Brightness.light), home: page),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('duplicate results are read-only and reveal duplicates', (
    tester,
  ) async {
    final modified = DateTime(2026, 1, 2, 3, 4);
    final runner = _FakeRunner(
      duplicateReport: DuplicateScanReport(
        groups: [
          DuplicateGroup(
            size: 2048,
            files: [
              DuplicateFile(
                path: r'C:\Users\Alice\Downloads\a.bin',
                size: 2048,
                modified: modified,
              ),
              DuplicateFile(
                path: r'C:\Users\Alice\Downloads\copy\b.bin',
                size: 2048,
                modified: modified,
              ),
            ],
          ),
        ],
        scannedFiles: 4,
        scannedBytes: 4096,
        errorCount: 0,
        truncated: false,
        cancelled: false,
      ),
    );

    await _pumpPage(
      tester,
      DuplicateFinderPage(
        shell: _FakeSystemShell(),
        runnerFactory: () => runner,
        initialDirectory: r'C:\Users\Alice\Downloads',
        excludedPaths: const [r'C:\Users\Alice\AppData\Local\Broom\quarantine'],
      ),
    );

    expect(find.text('INFO · 只读'), findsOneWidget);
    expect(find.textContaining('不会删除、移动或修改'), findsOneWidget);

    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();

    expect(runner.disposed, isTrue);
    expect(find.text('2 个相同文件'), findsOneWidget);
    expect(find.text('可释放 2.0 KB'), findsOneWidget);
    expect(find.text('a.bin'), findsOneWidget);
    expect(find.text('b.bin'), findsOneWidget);
    expect(find.text('清理'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(
      find.widgetWithIcon(IconButton, Icons.folder_open_rounded),
      findsNWidgets(2),
    );
  });

  testWidgets('large-file results are sorted and read-only', (tester) async {
    final modified = DateTime(2026, 2, 3);
    final runner = _FakeRunner(
      largeReport: LargeFileScanReport(
        files: [
          LargeFileEntry(
            path: r'C:\Users\Alice\Downloads\video.iso',
            size: 5 * 1024 * 1024,
            modified: modified,
          ),
          LargeFileEntry(
            path: r'C:\Users\Alice\Downloads\archive.zip',
            size: 2 * 1024 * 1024,
            modified: modified,
          ),
        ],
        matchedCount: 2,
        matchedBytes: 7 * 1024 * 1024,
        scannedFiles: 8,
        scannedBytes: 8 * 1024 * 1024,
        errorCount: 0,
        truncated: false,
        cancelled: false,
      ),
    );

    await _pumpPage(
      tester,
      LargeFilesPage(
        shell: _FakeSystemShell(),
        runnerFactory: () => runner,
        initialDirectory: r'C:\Users\Alice\Downloads',
      ),
    );

    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();

    expect(runner.disposed, isTrue);
    expect(find.text('video.iso'), findsOneWidget);
    expect(find.text('archive.zip'), findsOneWidget);
    expect(find.text('5.0 MB'), findsOneWidget);
    expect(find.text('7.0 MB'), findsWidgets);
    expect(find.textContaining('不会删除、移动或修改'), findsOneWidget);
    expect(find.text('清理'), findsNothing);
    expect(
      find.widgetWithIcon(IconButton, Icons.folder_open_rounded),
      findsNWidgets(2),
    );
  });
}
