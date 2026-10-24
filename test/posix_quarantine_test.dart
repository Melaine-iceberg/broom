import 'dart:io';

import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/clean/quarantine_service.dart';
import 'package:broom/core/models/clean_models.dart';
import 'package:broom/core/models/scan_models.dart';
import 'package:broom/core/platform/path_semantics.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/file_metadata_fakes.dart';

final _linuxOnly = !Platform.isLinux ? 'Linux only' : false;

const _semantics = PosixPathSemantics();

void main() {
  late Directory temp;
  late Directory source;
  late FakeFileMetadataAccess metadata;
  late QuarantineService quarantine;
  late ScanRoots testRoots;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('broom_posix_quarantine_');
    source = Directory(p.posix.join(temp.path, 'source'));
    await source.create(recursive: true);
    testRoots = ScanRoots([
      ScanRoot(ruleId: 'test.rule', rootPath: source.path),
    ]);
    metadata = FakeFileMetadataAccess();
    quarantine = QuarantineService(
      quarantineRoot: p.posix.join(temp.path, 'quarantine'),
      guard: PathGuard(protectedRoots: const [], semantics: _semantics),
      metadataAccess: metadata,
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<File> createFile(String relative, String content) async {
    final file = File(p.posix.join(source.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  Future<JunkItem> itemFor(File file) async {
    final stat = await file.stat();
    return JunkItem(
      rootIndex: 0,
      path: file.path,
      size: stat.size,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
    );
  }

  test('moves and restores files using POSIX paths', () async {
    final file = await createFile('nested/cache.txt', 'alpha');
    final report = await quarantine.clean([
      await itemFor(file),
    ], roots: testRoots);

    expect(report.movedCount, 1);
    expect(report.failureCount, 0);
    expect(await file.exists(), isFalse);
    expect(quarantine.quarantineRoot.contains('\\'), isFalse);

    final sessions = await quarantine.listSessions();
    expect(sessions, hasLength(1));
    final entry = (await quarantine.listEntries(sessions.single.id)).single;
    expect(entry.originalPath, file.path);
    expect(entry.originalPath.contains('\\'), isFalse);

    final undo = await quarantine.undo(report.sessionId!);
    expect(undo.restoredCount, 1);
    expect(undo.sessionRemoved, isTrue);
    expect(await file.readAsString(), 'alpha');
  }, skip: _linuxOnly);

  test('treats every move as cross-volume without a device probe', () async {
    final file = await createFile('cache.txt', 'alpha');
    final assessment = await quarantine.assessSpace([await itemFor(file)]);

    expect(assessment.crossVolumeCount, 1);
    expect(assessment.requiredBytes, 5);
    expect(assessment.freeBytes, isNull);
  }, skip: _linuxOnly);

  test('uses device ids to detect same-volume moves', () async {
    final file = await createFile('cache.txt', 'alpha');
    final probe = _ProbeQuarantineService(
      root: p.posix.join(temp.path, 'quarantine'),
      metadata: metadata,
      deviceIds: const [7, 7],
    );

    final assessment = await probe.assessSpace([await itemFor(file)]);

    expect(assessment.crossVolumeCount, 0);
    expect(assessment.requiredBytes, 0);
  }, skip: _linuxOnly);

  test('counts a different device as a cross-volume copy', () async {
    final file = await createFile('cache.txt', 'alpha');
    final probe = _ProbeQuarantineService(
      root: p.posix.join(temp.path, 'quarantine'),
      metadata: metadata,
      deviceIds: const [7, 8],
    );

    final assessment = await probe.assessSpace([await itemFor(file)]);

    expect(assessment.crossVolumeCount, 1);
    expect(assessment.requiredBytes, 5);
  }, skip: _linuxOnly);

  test('captures extended metadata for cross-device moves', () async {
    final file = await createFile('cache.txt', 'alpha');
    final service = _serviceWithDevice(
      p.posix.join(temp.path, 'quarantine'),
      metadata,
      sourcePrefix: source.path,
      sourceDevice: 8,
    );

    final report = await service.clean([await itemFor(file)], roots: testRoots);

    expect(report.movedCount, 1);
    expect(metadata.reads.single.captureAcl, isTrue);
  }, skip: _linuxOnly);

  test('skips extended metadata capture for same-device moves', () async {
    final file = await createFile('cache.txt', 'alpha');
    final service = _serviceWithDevice(
      p.posix.join(temp.path, 'quarantine'),
      metadata,
      sourcePrefix: source.path,
      sourceDevice: 7,
    );

    final report = await service.clean([await itemFor(file)], roots: testRoots);

    expect(report.movedCount, 1);
    expect(metadata.reads.single.captureAcl, isFalse);
  }, skip: _linuxOnly);
}

QuarantineService _serviceWithDevice(
  String root,
  FileMetadataAccess metadata, {
  required String sourcePrefix,
  required int sourceDevice,
}) {
  return QuarantineService(
    quarantineRoot: root,
    guard: PathGuard(protectedRoots: const [], semantics: _semantics),
    metadataAccess: metadata,
    deviceIdProbe: (paths) async => [
      for (final path in paths)
        path.startsWith(sourcePrefix) ? sourceDevice : 7,
    ],
  );
}

class _ProbeQuarantineService {
  _ProbeQuarantineService({
    required String root,
    required FileMetadataAccess metadata,
    required this.deviceIds,
  }) : _service = QuarantineService(
         quarantineRoot: root,
         guard: PathGuard(protectedRoots: const [], semantics: _semantics),
         metadataAccess: metadata,
         freeSpaceProbe: (_) async => 1024 * 1024,
         deviceIdProbe: (_) async => deviceIds,
       );

  final QuarantineService _service;
  final List<int?> deviceIds;

  Future<QuarantineSpaceAssessment> assessSpace(List<JunkItem> items) =>
      _service.assessSpace(items);
}
