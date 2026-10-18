import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/clean/quarantine_service.dart';
import 'core/platform/cleaner_platform.dart';
import 'core/safety/path_guard.dart';
import 'ui/clean_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final platform = createCleanerPlatform();
  if (!platform.isSupported) {
    runApp(UnsupportedApp(platformName: platform.displayName));
    return;
  }

  final quarantineRoot = platform.quarantineRoot;
  if (quarantineRoot == null) {
    runApp(
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

  runApp(BroomApp(controller: controller));
}
