import 'dart:io';

import 'package:broom/core/models/cleaner_rule.dart';
import 'package:broom/core/platform/windows_rule_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late WindowsRuleResolver resolver;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_resolver_');
    resolver = WindowsRuleResolver(environment: {'TESTBASE': temp.path});
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  CleanerRule createRule(List<String> patterns) => CleanerRule(
    id: 'test.rule',
    title: 'test',
    category: 'test',
    description: 'test',
    pathPatterns: patterns,
  );

  test(
    'expands environment variables and wildcard profile directories',
    () async {
      final defaultCache = Directory(
        p.windows.join(
          temp.path,
          'User Data',
          'Default',
          'Cache',
          'Cache_Data',
        ),
      );
      final profileCache = Directory(
        p.windows.join(temp.path, 'User Data', 'Profile 1', 'Cache'),
      );
      final noCache = Directory(
        p.windows.join(temp.path, 'User Data', 'Guest'),
      );
      await defaultCache.create(recursive: true);
      await profileCache.create(recursive: true);
      await noCache.create(recursive: true);

      final roots = await resolver.resolve(
        createRule([r'%TESTBASE%\User Data\*\Cache']),
      );

      expect(
        roots,
        unorderedEquals([
          p.windows.normalize(defaultCache.parent.path),
          p.windows.normalize(profileCache.path),
        ]),
      );
    },
  );

  test('resolves a non-wildcard directory that exists', () async {
    final shaderCache = Directory(
      p.windows.join(temp.path, 'User Data', 'ShaderCache', 'GPUCache'),
    );
    await shaderCache.create(recursive: true);

    final roots = await resolver.resolve(
      createRule([
        r'%TESTBASE%\User Data\ShaderCache\GPUCache',
        r'%TESTBASE%\User Data\Missing',
      ]),
    );

    expect(roots, [p.windows.normalize(shaderCache.path)]);
  });

  test('returns no roots when the environment variable is missing', () async {
    final roots = await resolver.resolve(
      createRule([r'%BROOM_MISSING_ENV_VAR_42%\Somewhere']),
    );
    expect(roots, isEmpty);
  });

  test('does not treat a file as a scan root', () async {
    final file = File(p.windows.join(temp.path, 'cache-file.txt'));
    await file.writeAsString('not a directory');

    final roots = await resolver.resolve(
      createRule([r'%TESTBASE%\cache-file.txt']),
    );
    expect(roots, isEmpty);
  });
}
