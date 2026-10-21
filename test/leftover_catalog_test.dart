import 'package:broom/core/models/leftover_models.dart';
import 'package:broom/core/rules/leftover_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

LeftoverCatalogEntry _entry({
  String id = 'example',
  List<String> dataPaths = const [r'%APPDATA%\Example'],
  List<String> markers = const [r'%LOCALAPPDATA%\Example\app.exe'],
  List<String> prefixes = const ['Example'],
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
  );
}

void main() {
  test('curated catalog is valid', () {
    expect(LeftoverCatalog.validate, returnsNormally);
  });

  test('first batch contains the confirmed applications', () {
    expect(LeftoverCatalog.entries, hasLength(3));
    expect(
      LeftoverCatalog.entries.map((entry) => entry.id),
      containsAll(<String>['slack', 'discord', 'vscode']),
    );
  });

  test('rule ids round-trip through the catalog', () {
    for (final entry in LeftoverCatalog.entries) {
      expect(entry.ruleId, 'leftover.${entry.id}');
      expect(LeftoverCatalog.entryForRuleId(entry.ruleId), same(entry));
      expect(LeftoverCatalog.isLeftoverRuleId(entry.ruleId), isTrue);
    }
    expect(LeftoverCatalog.entryForRuleId('app.slack'), isNull);
    expect(LeftoverCatalog.entryForRuleId('leftover.unknown'), isNull);
  });

  test('data paths cannot target shared or unsafe directories', () {
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(dataPaths: [r'%APPDATA%\Microsoft']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(dataPaths: [r'%APPDATA%']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(dataPaths: [r'%USERPROFILE%\Desktop\Example']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(dataPaths: [r'%APPDATA%\Example\..\Microsoft']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(dataPaths: [r'%APPDATA%\Example*']),
      ]),
      throwsFormatException,
    );
  });

  test('install markers require an env root and a final-segment wildcard', () {
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(markers: [r'C:\Program Files\Example\Example.exe']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(markers: [r'%LOCALAPPDATA%']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(markers: [r'%LOCALAPPDATA%\*\Example.exe']),
      ]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(markers: [r'%LOCALAPPDATA%\Example\app-*']),
      ]),
      returnsNormally,
    );
  });

  test('ids and data paths are unique', () {
    expect(
      () => LeftoverCatalog.validateEntries([_entry(), _entry()]),
      throwsFormatException,
    );
    expect(
      () => LeftoverCatalog.validateEntries([
        _entry(id: 'first'),
        _entry(id: 'second'),
      ]),
      throwsFormatException,
    );
  });

  test('install display name prefixes are required', () {
    expect(
      () => LeftoverCatalog.validateEntries([_entry(prefixes: const [])]),
      throwsFormatException,
    );
  });
}
