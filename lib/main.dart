import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/clean/clean_history_store.dart';
import 'core/clean/file_metadata.dart';
import 'core/clean/quarantine_retention_service.dart';
import 'core/clean/quarantine_service.dart';
import 'core/clean/system_cache_cleaner.dart';
import 'core/clean/system_services.dart';
import 'core/diagnostics/app_logger.dart';
import 'core/leftover/leftover_service.dart';
import 'core/platform/app_version.dart';
import 'core/platform/cleaner_platform.dart';
import 'core/platform/file_lock_probe.dart';
import 'core/platform/installed_apps.dart';
import 'core/platform/linux_system_maintenance.dart';
import 'core/platform/path_semantics.dart';
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
import 'ui/app_update_controller.dart';
import 'ui/clean_controller.dart';
import 'ui/linux_system_cache_controller.dart';
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

  final semantics = platform.pathSemantics;
  final appDataRoot = semantics.dirname(quarantineRoot);
  final guard = PathGuard(
    protectedRoots: [...platform.protectedRoots, quarantineRoot],
    semantics: semantics,
  );
  final logger = AppLogger(
    directoryPath: semantics.join(appDataRoot, 'logs'),
    semantics: semantics,
  );
  AppLogger.instance = logger;
  _installErrorLogging(logger);
  logger.info(
    'app',
    'Broom 启动：平台 ${platform.displayName}，参数 ${args.isEmpty ? '无' : args.join(' ')}',
  );
  final exclusions = ExclusionStore(
    filePath: ExclusionStore.defaultFilePath(
      quarantineRoot,
      semantics: semantics,
    ),
    semantics: semantics,
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
    deviceIdProbe: Platform.isLinux ? PosixFileMetadataAccess.deviceIds : null,
    historyStore: CleanHistoryStore(
      filePath: CleanHistoryStore.defaultFilePath(
        quarantineRoot,
        semantics: semantics,
      ),
      semantics: semantics,
    ),
  );
  final retention = QuarantineRetentionService(
    quarantine: quarantine,
    store: QuarantinePolicyStore(
      filePath: QuarantinePolicyStore.defaultFilePath(
        quarantineRoot,
        semantics: semantics,
      ),
      semantics: semantics,
    ),
  );
  final settings = SettingsController(
    store: SettingsStore(
      filePath: SettingsStore.defaultFilePath(
        quarantineRoot,
        semantics: semantics,
      ),
      semantics: semantics,
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
    directoryPath: RuleCatalogStore.defaultDirectory(
      quarantineRoot,
      semantics: semantics,
    ),
    builtinRules: platform.rules,
    semantics: semantics,
  );
  final ntfsIndex = Platform.isWindows
      ? NtfsIndexClient()
      : const UnavailableNtfsIndex();
  final leftoverService = Platform.isWindows
      ? LeftoverService(
          installedApps: createInstalledApps(),
          guard: guard,
          exclusions: exclusions,
        )
      : null;
  final controller = CleanController(
    platform: platform,
    guard: guard,
    quarantine: quarantine,
    exclusions: exclusions,
    leftoverService: leftoverService,
    isRuleEnabled: settings.isRuleEnabled,
    scanSettings: () => settings.scanSettings,
    scanResultStore: ScanResultStore(
      rootDirectory: semantics.join(appDataRoot, 'scans'),
      semantics: semantics,
    ),
    ntfsIndex: ntfsIndex,
    lockProbe: createFileLockProbe(),
    logger: logger,
  );
  final ruleUpdates = Platform.isWindows
      ? RuleUpdateController(
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
        )
      : null;
  unawaited(
    _initializeBroom(controller, retention).catchError((Object error) {
      logger.error('app', '启动初始化失败', error: error);
    }),
  );

  final appUpdates = Platform.isWindows
      ? AppUpdateController(versionSource: createAppVersionSource())
      : null;
  if (appUpdates != null) {
    unawaited(appUpdates.loadVersion());
  }

  SystemCacheController? systemCacheController;
  if (Platform.isWindows) {
    final systemAccess = createSystemAccess();
    systemCacheController = SystemCacheController(
      platform: createSystemCachePlatform(access: systemAccess),
      access: systemAccess,
      cleaner: FileSystemCacheCleaner(services: WindowsServiceManager()),
      quarantineRoot: quarantineRoot,
      lockProbe: createFileLockProbe(),
    );
    _applyRuleCatalogAfterStartup(
      catalogStore: catalogStore,
      platform: platform,
      onApplied: controller.refreshLastScanSummary,
    );
  }

  // The Linux entry exists only when the helper, Polkit policy and pkexec are
  // all present. This check is synchronous and read-only; it never prompts.
  LinuxSystemCacheController? linuxSystemCacheController;
  if (Platform.isLinux) {
    final maintenance = createLinuxSystemMaintenance();
    if (maintenance != null) {
      linuxSystemCacheController = LinuxSystemCacheController(
        maintenance: maintenance,
      );
    }
  }

  _runBroom(
    BroomApp(
      controller: controller,
      settingsController: settings,
      systemShell: systemShell,
      systemCacheController: systemCacheController,
      linuxSystemCacheController: linuxSystemCacheController,
      quarantineRetention: retention,
      analysisInitialDirectory: _downloadsDirectory(
        platform.environment,
        semantics,
      ),
      analysisExcludedPaths: [quarantineRoot],
      startInSystemCache: Platform.isWindows && args.contains('--system-cache'),
      ruleUpdates: ruleUpdates,
      appUpdates: appUpdates,
      logger: logger,
    ),
  );
  logger.info('app', '主窗口已创建');
}

/// Applies the on-disk rule catalog once the first frame is on screen.
///
/// The catalog is not needed to paint the home page, so reading and decoding it
/// before [runApp] would put file I/O on the startup critical path. Until the
/// deferred load lands, the platform keeps its built-in catalog. [onApplied]
/// re-reads the persisted scan summary, because whether that summary is stale
/// depends on [CleanerPlatform.rulesVersion].
void _applyRuleCatalogAfterStartup({
  required RuleCatalogStore catalogStore,
  required CleanerPlatform platform,
  required Future<void> Function() onApplied,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_applyRuleCatalog(catalogStore, platform, onApplied));
  });
}

Future<void> _applyRuleCatalog(
  RuleCatalogStore catalogStore,
  CleanerPlatform platform,
  Future<void> Function() onApplied,
) async {
  // Yield first so the read and decode never run inside the frame callback.
  await Future<void>.delayed(Duration.zero);
  try {
    final catalog = catalogStore.loadSync();
    if (platform is WindowsCleanerPlatform) {
      platform.applyRuleCatalog(catalog.rules, catalog.version);
    }
    await onApplied();
    AppLogger.instance?.info(
      'app',
      '规则目录加载完成：${catalog.rules.length} 条，版本 ${catalog.version}',
    );
  } catch (error) {
    // A broken catalog must not take down a running app: the built-in rules stay
    // in effect and the failure only lands in diagnostics.
    AppLogger.instance?.error('app', '启动阶段规则目录加载失败', error: error);
  }
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

String? _downloadsDirectory(
  Map<String, String> environment,
  PathSemantics semantics,
) {
  String? lookup(String name) {
    return environment[name] ??
        environment.entries
            .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
            .map((entry) => entry.value)
            .firstOrNull;
  }

  if (Platform.isWindows) {
    final profile = lookup('USERPROFILE');
    if (profile == null || profile.trim().isEmpty) return null;
    return semantics.join(profile, 'Downloads');
  }

  final home = lookup('HOME');
  if (home == null || home.trim().isEmpty) return null;

  final configured = lookup('XDG_DOWNLOAD_DIR');
  if (configured != null && semantics.isAbsolute(configured)) {
    return semantics.normalize(semantics.absolute(configured));
  }

  final configHome =
      lookup('XDG_CONFIG_HOME') ?? semantics.join(home, '.config');
  final userDirs = File(
    semantics.forIo(semantics.join(configHome, 'user-dirs.dirs')),
  );
  try {
    if (userDirs.existsSync()) {
      for (final line in userDirs.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.startsWith('#')) continue;
        final separator = trimmed.indexOf('=');
        if (separator <= 0) continue;
        if (trimmed.substring(0, separator).trim() != 'XDG_DOWNLOAD_DIR') {
          continue;
        }
        final value = trimmed
            .substring(separator + 1)
            .trim()
            .replaceAll('"', '')
            .replaceAll(r'$HOME', home);
        if (semantics.isAbsolute(value)) {
          return semantics.normalize(semantics.absolute(value));
        }
      }
    }
  } catch (_) {
    // A malformed user-dirs.dirs must not prevent the analysis page from
    // opening; fall back to the conventional directory below.
  }
  return semantics.join(home, 'Downloads');
}

// The native runner registers the window channels while creating the view, so
// subscribe once the first frame is on screen.
void _runBroom(Widget app) {
  runApp(app);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    WindowChrome.instance.initialize();
  });
}
