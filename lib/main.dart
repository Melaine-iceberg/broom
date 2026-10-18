import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/clean/quarantine_service.dart';
import 'core/platform/cleaner_platform.dart';
import 'core/safety/path_guard.dart';
import 'platform/window_chrome.dart';
import 'ui/clean_controller.dart';

void main() {
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

  _runBroom(BroomApp(controller: controller));
}

// The native runner registers the window channels while creating the view, so
// subscribe once the first frame is on screen.
void _runBroom(Widget app) {
  runApp(app);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    WindowChrome.instance.initialize();
  });
}
