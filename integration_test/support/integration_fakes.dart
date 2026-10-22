import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/cleaner_platform.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/scan/scan_service.dart';
import 'package:broom/core/shell/system_shell.dart';
import 'package:path/path.dart' as p;

const integrationRule = CleanerRule(
  id: 'integration.cache',
  title: '集成测试缓存',
  category: '测试',
  description: '集成测试使用的安全缓存规则',
  pathPatterns: [],
);

const integrationRoot = r'C:\Integration\Cache';

List<JunkItem> buildIntegrationItems(int count) {
  return [
    for (var index = 0; index < count; index++)
      JunkItem(
        rootIndex: 0,
        path: p.join(integrationRoot, 'item-$index.tmp'),
        size: 1024 + index,
        modifiedMicros: DateTime(2026, 10, 19).microsecondsSinceEpoch,
      ),
  ];
}

class IntegrationPlatform implements CleanerPlatform {
  @override
  String get displayName => 'Integration';

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => true;

  @override
  PathSemantics get pathSemantics => PathSemanticsFactory.forCurrentPlatform();

  @override
  List<String> get protectedRoots => const [];

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => const [integrationRule];

  @override
  String get rulesVersion => 'integration';

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [
    integrationRoot,
  ];
}

class IntegrationScanService extends ScanService {
  IntegrationScanService({List<JunkItem>? items})
    : items = items ?? buildIntegrationItems(1);

  final List<JunkItem> items;

  @override
  Future<ScanResult> scan({
    required List<ScanJob> jobs,
    required List<String> excludedPaths,
    ScanOptions options = const ScanOptions(),
    NtfsIndex? ntfsIndex,
    void Function(ScanProgress progress)? onProgress,
    void Function(List<JunkItem> items)? onItems,
    void Function(ScanIssue issue)? onIssue,
    bool retainItems = true,
  }) async {
    onProgress?.call(
      ScanProgress(
        jobIndex: 0,
        jobCount: jobs.length,
        ruleId: integrationRule.id,
        scannedFiles: items.length,
        foundFiles: items.length,
        foundBytes: items.fold(0, (total, item) => total + item.size),
      ),
    );
    onItems?.call(items);
    return ScanResult(
      items: retainItems ? items : const [],
      scannedFiles: items.length,
      directoryErrors: 0,
      truncated: false,
      cancelled: false,
    );
  }
}

class IntegrationShell implements SystemShell {
  @override
  Future<void> emptyRecycleBin() async {}

  @override
  Future<String?> pickFolder({String? initialDirectory}) async => null;

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
      const DiskSpaceSnapshot(freeBytes: 1 << 30, totalBytes: 1 << 32);

  @override
  Future<RecycleBinSnapshot> queryRecycleBin() async =>
      const RecycleBinSnapshot(itemCount: 0, totalBytes: 0);

  @override
  Future<void> revealPath(String path) async {}
}
