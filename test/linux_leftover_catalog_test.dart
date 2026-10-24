import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/rules/leftover_catalog.dart';
import 'package:broom/core/rules/linux_leftover_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

LeftoverCatalogEntry _entry({
  String id = 'linux-example',
  List<String> dataPaths = const [r'$XDG_CONFIG_HOME/Example'],
  List<String> markers = const [r'$XDG_DATA_HOME/flatpak/app/org.example.App'],
  List<String> prefixes = const ['Example'],
  List<String> packageIds = const ['example', 'org.example.App'],
}) {
  return LeftoverCatalogEntry(
    id: id,
    appName: 'Example',
    appNameEn: 'Example',
    description: '示例',
    descriptionEn: 'Example',
    dataPathPatterns: dataPaths,
    installMarkerPatterns: markers,
    installDisplayNamePrefixes: prefixes,
    installPackageIds: packageIds,
  );
}

void main() {
  test('curated Linux catalog is valid', () {
    expect(LinuxLeftoverCatalog.validate, returnsNormally);
  });

  test('curated Linux catalog covers the supported desktop apps', () {
    expect(
      LinuxLeftoverCatalog.entries.map((entry) => entry.id),
      containsAll(<String>[
        'linux-slack',
        'linux-discord',
        'linux-vscode',
        'linux-obsidian',
        'linux-spotify',
        'linux-signal',
        'linux-zoom',
      ]),
    );
  });

  test('rule ids resolve through the shared catalog index', () {
    final entry = LeftoverCatalog.entryForRuleId('leftover.linux-slack');
    expect(entry, isNotNull);
    expect(entry!.appName, 'Slack');
    expect(LeftoverCatalog.allEntries, contains(entry));
  });

  test('rejects data paths outside XDG user directories', () {
    expect(
      () => LinuxLeftoverCatalog.validateEntries([
        _entry(dataPaths: const ['/opt/example']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LinuxLeftoverCatalog.validateEntries([
        _entry(dataPaths: const [r'$HOME/.config/../secret']),
      ]),
      throwsFormatException,
    );
  });

  test('rejects wildcard and shared data roots', () {
    for (final path in [
      r'$XDG_CONFIG_HOME/*',
      r'$XDG_CONFIG_HOME',
      r'$HOME/.config',
      r'$XDG_DATA_HOME/flatpak',
    ]) {
      expect(
        () => LinuxLeftoverCatalog.validateEntries([
          _entry(dataPaths: [path]),
        ]),
        throwsFormatException,
        reason: path,
      );
    }
  });

  test('rejects wildcards outside the final marker segment', () {
    expect(
      () => LinuxLeftoverCatalog.validateEntries([
        _entry(markers: const [r'$HOME/.local/*/example']),
      ]),
      throwsFormatException,
    );
  });

  test('requires valid package ids', () {
    for (final id in ['', 'bad id', '/usr/bin/app']) {
      expect(
        () => LinuxLeftoverCatalog.validateEntries([
          _entry(packageIds: [id], prefixes: const []),
        ]),
        throwsFormatException,
        reason: id,
      );
    }
  });

  test('rejects data directories that overlap the install marker', () {
    expect(
      () => LinuxLeftoverCatalog.validateEntries([
        _entry(
          dataPaths: const [r'$XDG_DATA_HOME/flatpak/app/org.example.App'],
          markers: const [
            r'$XDG_DATA_HOME/flatpak/app/org.example.App/current/bin/app',
          ],
        ),
      ]),
      throwsFormatException,
    );
  });
}
