import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app.dart';
import 'core/clean/clean_history_store.dart';
import 'core/clean/file_metadata.dart';
import 'core/clean/quarantine_retention_service.dart';
import 'core/clean/quarantine_service.dart';
import 'core/clean/system_cache_cleaner.dart';
import 'core/clean/system_services.dart';
import 'core/diagnostics/app_logger.dart';
import 'core/leftover/leftover_service.dart';
import 'core/platform/cleaner_platform.dart';
import 'core/platform/file_lock_probe.dart';
import 'core/platform/installed_apps.dart';
import 'core/platform/system_access.dart';
import 'core/platform/system_cache_platform.dart';
import 'core/rules/rule_catalog_store.dart';
import 'core/rules/rule_update_service.dart';
import 'core/safety/path_guard.dart';
import 'core/scan/ntfs_index.dart';
import 'core/scan/ntfs_index_client.dart';
import 'core/scan/scan_result_store.dart';
import 'core/settings/exclusion_store.dart';
import 'core/settings/quarantine_policy_store.dart';
import 'core/settings/settings_store.dart';
import 'core/shell/system_shell.dart';
import 'platform/window_chrome.dart';
import 'ui/clean_controller.dart';
import 'ui/rule_update_controller.dart';
import 'ui/settings_controller.dart';
import 'ui/system_cache_controller.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();

  final platform = createCleanerPlatform();
  if (!platform.isSupported) {
    _runBroom(UnsupportedApp(platformName: platform.displayName));
    return;
  }

  final quarantineRoot = platform.quarantineRoot;
  if (quarantineRoot == null) {
    _runBroom(
      UnsupportedApp(
        platformName: platform.displayName,
        reason: '无法确定本地应用数据目录，清理功能不可用。',
      ),
    );
    return;
  }

  final guard = PathGuard.forWindows(
    environment: platform.environment,
    additionalProtectedRoots: [quarantineRoot],
  );
  final logger = AppLogger(
    directoryPath: p.windows.join(p.windows.dirname(quarantineRoot), 'logs'),
  );
  AppLogger.instance = logger;
  _installErrorLogging(logger);
  logger.info(
    'app',
    'Broom 启动：平台 ${platform.displayName}，参数 ${args.isEmpty ? '无' : args.join(' ')}',
  );
  final exclusions = ExclusionStore(
    filePath: ExclusionStore.defaultFilePath(quarantineRoot),
  );
  final systemShell = createSystemShell();
  final quarantine = QuarantineService(
    quarantineRoot: quarantineRoot,
    guard: guard,
    metadataAccess: createFileMetadataAccess(),
    exclusions: exclusions,
    freeSpaceProbe: (path) async {
      try {
        return (await systemShell.queryDiskSpace(path)).freeBytes;
      } catch (_) {
        // If disk space cannot be queried, cleaning must remain available.
        return null;
      }
    },
    historyStore: CleanHistoryStore(
      filePath: CleanHistoryStore.defaultFilePath(quarantineRoot),
    ),
  );
  final retention = QuarantineRetentionService(
    quarantine: quarantine,
    store: QuarantinePolicyStore(
      filePath: QuarantinePolicyStore.defaultFilePath(quarantineRoot),
    ),
  );
  final settings = SettingsController(
    store: SettingsStore(
      filePath: SettingsStore.defaultFilePath(quarantineRoot),
    ),
    logger: logger,
  );
  settings.load();
  logger.info(
    'app',
    '设置加载完成：诊断日志 ${settings.diagnosticsEnabled ? '已启用' : '已关闭'}，'
        '规则 ${platform.rules.length} 条',
  );

  final catalogStore = RuleCatalogStore(
    directoryPath: RuleCatalogStore.defaultDirectory(quarantineRoot),
  );
  final activeCatalog = catalogStore.loadSync();
  if (platform is WindowsCleanerPlatform) {
    platform.applyRuleCatalog(activeCatalog.rules, activeCatalog.version);
  }
  final ntfsIndex = Platform.isWindows
      ? NtfsIndexClient()
      : const UnavailableNtfsIndex();
  final leftoverService = LeftoverService(
    installedApps: createInstalledApps(),
    guard: guard,
    exclusions: exclusions,
  );
  final controller = CleanController(
    platform: platform,
    guard: guard,
    quarantine: quarantine,
    exclusions: exclusions,
    leftoverService: leftoverService,
    isRuleEnabled: settings.isRuleEnabled,
    scanSettings: () => settings.scanSettings,
    scanResultStore: ScanResultStore(
      rootDirectory: p.windows.join(p.windows.dirname(quarantineRoot), 'scans'),
    ),
    ntfsIndex: ntfsIndex,
    lockProbe: createFileLockProbe(),
    logger: logger,
  );
  final ruleUpdates = RuleUpdateController(
    service: RuleUpdateService(
      store: catalogStore,
      signingKey: RuleUpdateService.compiledSigningKey,
    ),
    settings: settings,
    onCatalogChanged: (catalog) {
      if (platform is WindowsCleanerPlatform) {
        platform.applyRuleCatalog(catalog.rules, catalog.version);
      }
      unawaited(controller.refreshRuleExclusionScopes());
    },
  );
  unawaited(
    _initializeBroom(controller, retention).catchError((Object error) {
      logger.error('app', '启动初始化失败', error: error);
    }),
  );

  final systemAccess = createSystemAccess();
  final systemCacheController = SystemCacheController(
    platform: createSystemCachePlatform(access: systemAccess),
    access: systemAccess,
    cleaner: FileSystemCacheCleaner(services: WindowsServiceManager()),
    quarantineRoot: quarantineRoot,
    lockProbe: createFileLockProbe(),
  );

  _runBroom(
    BroomApp(
      controller: controller,
      settingsController: settings,
      systemShell: systemShell,
      systemCacheController: systemCacheController,
      quarantineRetention: retention,
      analysisInitialDirectory: _downloadsDirectory(platform.environment),
      analysisExcludedPaths: [quarantineRoot],
      startInSystemCache: args.contains('--system-cache'),
      ruleUpdates: ruleUpdates,
      logger: logger,
    ),
  );
  logger.info('app', '主窗口已创建');
}

void _installErrorLogging(AppLogger logger) {
  FlutterError.onError = (details) {
    logger.error(
      'flutter',
      details.exceptionAsString(),
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logger.error('platform', '未捕获的异步异常', error: error, stackTrace: stack);
    return false;
  };
}

// Apply the quarantine retention policy before loading pending sessions so the
// home page counts reflect anything auto-purged at startup.
Future<void> _initializeBroom(
  CleanController controller,
  QuarantineRetentionService retention,
) async {
  await retention.ensureInitialized();
  await controller.initialize();
}

String? _downloadsDirectory(Map<String, String> environment) {
  String? lookup(String name) {
    return environment[name] ??
        environment.entries
            .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
            .map((entry) => entry.value)
            .firstOrNull;
  }

  final profile = lookup('USERPROFILE');
  if (profile == null || profile.trim().isEmpty) return null;
  return p.windows.join(profile, 'Downloads');
}

// The native runner registers the window channels while creating the view, so
// subscribe once the first frame is on screen.
void _runBroom(Widget app) {
  runApp(app);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    WindowChrome.instance.initialize();
  });
}
