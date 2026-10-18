import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app.dart';
import 'core/clean/quarantine_service.dart';
import 'core/clean/system_cache_cleaner.dart';
import 'core/clean/system_services.dart';
import 'core/platform/cleaner_platform.dart';
import 'core/platform/system_access.dart';
import 'core/platform/system_cache_platform.dart';
import 'core/safety/path_guard.dart';
import 'platform/window_chrome.dart';
import 'ui/clean_controller.dart';
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
  final quarantine = QuarantineService(
    quarantineRoot: quarantineRoot,
    guard: guard,
  );
  final controller = CleanController(
    platform: platform,
    guard: guard,
    quarantine: quarantine,
  );
  unawaited(controller.initialize());

  final systemAccess = createSystemAccess();
  final systemCacheController = SystemCacheController(
    platform: createSystemCachePlatform(access: systemAccess),
    access: systemAccess,
    cleaner: FileSystemCacheCleaner(services: WindowsServiceManager()),
    quarantineRoot: quarantineRoot,
  );

  _runBroom(
    BroomApp(
      controller: controller,
      systemCacheController: systemCacheController,
      analysisInitialDirectory: _downloadsDirectory(platform.environment),
      analysisExcludedPaths: [quarantineRoot],
      startInSystemCache: args.contains('--system-cache'),
    ),
  );
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
