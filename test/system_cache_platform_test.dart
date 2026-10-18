import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/models/system_models.dart';
import 'package:broom/core/platform/system_access.dart';
import 'package:broom/core/platform/system_cache_platform.dart';
import 'package:broom/core/rules/windows_system_rules.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeAccess implements SystemAccess {
  _FakeAccess(this.roots);

  SystemCacheRoots roots;

  @override
  Future<bool> isElevated() async => true;

  @override
  Future<bool> relaunchElevated() async => false;

  @override
  Future<SystemCacheRoots> locateSystemCacheRoots() async => roots;
}

void main() {
  late Directory temp;
  late Directory updateRoot;
  late Directory deliveryRoot;
  late Directory windowsOldRoot;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_system_platform_');
    updateRoot = Directory(
      p.join(temp.path, 'Windows', 'SoftwareDistribution', 'Download'),
    );
    await updateRoot.create(recursive: true);
    deliveryRoot = Directory(
      p.join(
        temp.path,
        'ProgramData',
        'Microsoft',
        'Windows',
        'DeliveryOptimization',
        'Cache',
      ),
    );
    await deliveryRoot.create(recursive: true);
    windowsOldRoot = Directory(p.join(temp.path, 'Windows.old'));
    await windowsOldRoot.create(recursive: true);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  _FakeAccess accessFor({
    String? update,
    String? delivery,
    String? windowsOld,
  }) {
    return _FakeAccess(
      SystemCacheRoots(
        windowsUpdateDownload: update ?? updateRoot.path,
        deliveryOptimizationCache: delivery ?? deliveryRoot.path,
        windowsOld: windowsOld ?? windowsOldRoot.path,
      ),
    );
  }

  test('resolves the declared Windows Update cache directory', () async {
    final platform = WindowsSystemCachePlatform(access: accessFor());
    final roots = await platform.resolveRoots(windowsSystemCacheRules[0]);

    expect(roots, [PathGuard.normalize(updateRoot.path)]);
  });

  test('resolves the declared Delivery Optimization cache directory', () async {
    final platform = WindowsSystemCachePlatform(access: accessFor());
    final roots = await platform.resolveRoots(windowsSystemCacheRules[1]);

    expect(roots, [PathGuard.normalize(deliveryRoot.path)]);
  });

  test('resolves the declared Windows.old directory', () async {
    final platform = WindowsSystemCachePlatform(access: accessFor());
    final roots = await platform.resolveRoots(windowsSystemCacheRules[2]);

    expect(roots, [PathGuard.normalize(windowsOldRoot.path)]);
  });

  test('rejects a Windows.old-like path with the wrong name', () async {
    final wrong = Directory(p.join(temp.path, 'Windows.old.000'));
    await wrong.create(recursive: true);
    final platform = WindowsSystemCachePlatform(
      access: accessFor(windowsOld: wrong.path),
    );

    await expectLater(
      platform.resolveRoots(windowsSystemCacheRules[2]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('不符合规则声明'),
        ),
      ),
    );
  });

  test('returns no roots when the cache directory does not exist', () async {
    await updateRoot.delete(recursive: true);
    final platform = WindowsSystemCachePlatform(access: accessFor());

    expect(await platform.resolveRoots(windowsSystemCacheRules[0]), isEmpty);
  });

  test('rejects roots whose shape does not match the rule', () async {
    final wrong = Directory(
      p.join(temp.path, 'Windows', 'SoftwareDistribution'),
    );
    final platform = WindowsSystemCachePlatform(
      access: accessFor(update: wrong.path),
    );

    await expectLater(
      platform.resolveRoots(windowsSystemCacheRules[0]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('不符合规则声明'),
        ),
      ),
    );
  });

  test('rejects a drive root', () async {
    final platform = WindowsSystemCachePlatform(
      access: accessFor(update: r'C:\'),
    );

    await expectLater(
      platform.resolveRoots(windowsSystemCacheRules[0]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('磁盘根目录'),
        ),
      ),
    );
  });

  test('rejects a non-directory at the expected path', () async {
    final file = File(updateRoot.path);
    await updateRoot.delete(recursive: true);
    await file.writeAsString('not a directory');
    final platform = WindowsSystemCachePlatform(access: accessFor());

    await expectLater(
      platform.resolveRoots(windowsSystemCacheRules[0]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('不是普通目录'),
        ),
      ),
    );
  });

  test('unsupported platform exposes no rules or roots', () async {
    const platform = UnsupportedSystemCachePlatform();

    expect(platform.isSupported, isFalse);
    expect(platform.rules, isEmpty);
    expect(await platform.resolveRoots(windowsSystemCacheRules[0]), isEmpty);
  });

  test('system rules stay review level with fixed cache locations', () {
    expect(windowsSystemCacheRules, hasLength(3));
    expect(windowsSystemCacheRules.map((rule) => rule.location), [
      SystemCacheLocation.windowsUpdate,
      SystemCacheLocation.deliveryOptimization,
      SystemCacheLocation.windowsOld,
    ]);
    expect(
      windowsSystemCacheRules.every((rule) => rule.risk == CleanRisk.review),
      isTrue,
    );
    expect(windowsSystemCacheRules[0].services.map((service) => service.name), [
      'wuauserv',
      'bits',
    ]);
    expect(windowsSystemCacheRules[1].services.single.name, 'dosvc');
    expect(windowsSystemCacheRules[2].id, 'windows.old');
    expect(windowsSystemCacheRules[2].services, isEmpty);
  });
}
