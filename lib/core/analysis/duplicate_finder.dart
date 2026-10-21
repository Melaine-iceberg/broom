import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/analysis_models.dart';
import '../platform/file_system.dart';
import '../platform/windows_path.dart';
import 'file_tree_walker.dart';

const defaultDuplicateMinFileSize = 1024 * 1024;
const _defaultPartialChunkSize = 32 * 1024;
const _hashChunkSize = 1024 * 1024;

/// Finds byte-identical files using size prefiltering, a partial fingerprint
/// and finally a full SHA-256 hash. It never modifies or selects files.
class DuplicateFinder {
  DuplicateFinder({
    required this.root,
    this.minFileSize = defaultDuplicateMinFileSize,
    this.maxFiles = defaultAnalysisMaxFiles,
    this.excludedPaths = const [],
    this.partialChunkSize = _defaultPartialChunkSize,
    this.fileSystem = const IoFileSystem(),
    this.useDetailedListing = true,
  }) : assert(partialChunkSize > 0);

  final String root;
  final int minFileSize;
  final int maxFiles;
  final List<String> excludedPaths;
  final int partialChunkSize;
  final BroomFileSystem fileSystem;
  final bool useDetailedListing;

  Future<DuplicateScanReport> scan({
    void Function(DuplicateProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final filesBySize = <int, List<DuplicateFile>>{};
    var hashErrors = 0;
    var cancelled = false;
    var lastCompareReportAt = DateTime.fromMillisecondsSinceEpoch(0);
    late final FileWalkResult walkResult;

    void reportComparing(
      int processed,
      int total,
      String? currentPath, {
      bool force = false,
    }) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force &&
          now.difference(lastCompareReportAt) <
              const Duration(milliseconds: 160)) {
        return;
      }
      lastCompareReportAt = now;
      onProgress(
        DuplicateProgress(
          phase: AnalysisPhase.comparing,
          scannedFiles: walkResult.scannedFiles,
          scannedBytes: walkResult.scannedBytes,
          processedFiles: processed,
          totalFiles: total,
          currentPath: currentPath,
        ),
      );
    }

    walkResult =
        await FileTreeWalker(
          root: root,
          excludedPaths: excludedPaths,
          maxFiles: maxFiles,
          fileSystem: fileSystem,
          useDetailedListing: useDetailedListing,
        ).walk(
          onFile: (path, stat) {
            if (stat.size == 0 || stat.size < minFileSize) return;
            filesBySize
                .putIfAbsent(stat.size, () => [])
                .add(
                  DuplicateFile(
                    path: path,
                    size: stat.size,
                    modified: stat.modified,
                  ),
                );
          },
          onProgress: (scannedFiles, scannedBytes, currentPath) {
            onProgress?.call(
              DuplicateProgress(
                phase: AnalysisPhase.scanning,
                scannedFiles: scannedFiles,
                scannedBytes: scannedBytes,
                processedFiles: 0,
                totalFiles: 0,
                currentPath: currentPath,
              ),
            );
          },
          isCancelled: isCancelled,
        );

    if (walkResult.rootMissing) {
      throw StateError('选择的目录不存在或无法读取。');
    }

    DuplicateScanReport buildResult(List<DuplicateGroup> groups) {
      return DuplicateScanReport(
        groups: List.unmodifiable(groups),
        scannedFiles: walkResult.scannedFiles,
        scannedBytes: walkResult.scannedBytes,
        errorCount: walkResult.errorCount + hashErrors,
        truncated: walkResult.truncated,
        cancelled: cancelled,
      );
    }

    if (walkResult.cancelled) {
      cancelled = true;
      return buildResult(const []);
    }

    final sameSizeCandidates = [
      for (final files in filesBySize.values)
        if (files.length > 1) files,
    ];
    final partialTotal = sameSizeCandidates.fold<int>(
      0,
      (total, files) => total + files.length,
    );

    final byPartialHash = <String, List<DuplicateFile>>{};
    var verified = 0;
    for (final files in sameSizeCandidates) {
      for (final file in files) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          break;
        }
        try {
          final digest = await _partialDigest(file);
          byPartialHash.putIfAbsent('${file.size}:$digest', () => []).add(file);
        } on FileSystemException {
          hashErrors++;
        }
        verified++;
        reportComparing(verified, partialTotal, file.path);
      }
      if (cancelled) break;
    }

    if (cancelled) {
      return buildResult(const []);
    }

    final fullCandidates = [
      for (final files in byPartialHash.values)
        if (files.length > 1) files,
    ];
    final fullTotal = fullCandidates.fold<int>(
      0,
      (total, files) => total + files.length,
    );

    final groups = <DuplicateGroup>[];
    var fullyHashed = 0;
    for (final files in fullCandidates) {
      final byFullHash = <String, List<DuplicateFile>>{};
      for (final file in files) {
        try {
          final digest = await _fullDigest(file, isCancelled);
          byFullHash.putIfAbsent(digest, () => []).add(file);
        } on _AnalysisCancelled {
          cancelled = true;
          break;
        } on FileSystemException {
          hashErrors++;
        }
        fullyHashed++;
        reportComparing(fullyHashed, fullTotal, file.path);
      }
      if (cancelled) break;

      for (final exact in byFullHash.values) {
        if (exact.length < 2) continue;
        exact.sort((a, b) {
          final byModified = a.modified.compareTo(b.modified);
          if (byModified != 0) return byModified;
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
        });
        groups.add(
          DuplicateGroup(
            size: exact.first.size,
            files: List.unmodifiable(exact),
          ),
        );
      }
    }

    if (cancelled) {
      return buildResult(const []);
    }

    groups.sort((a, b) {
      final byWasted = b.wastedBytes.compareTo(a.wastedBytes);
      if (byWasted != 0) return byWasted;
      final bySize = b.size.compareTo(a.size);
      if (bySize != 0) return bySize;
      return a.files.first.path.toLowerCase().compareTo(
        b.files.first.path.toLowerCase(),
      );
    });
    if (fullTotal > 0) {
      reportComparing(fullyHashed, fullTotal, null, force: true);
    }
    return buildResult(groups);
  }

  Future<String> _partialDigest(DuplicateFile file) async {
    RandomAccessFile? handle;
    try {
      handle = await File(WindowsPath.forIo(file.path)).open();
      final length = await handle.length();
      if (length != file.size) {
        throw FileSystemException('文件在分析期间发生变化', file.path);
      }
      final headLength = min(partialChunkSize, file.size);
      final head = await handle.read(headLength);
      final tail = BytesBuilder(copy: false);
      if (file.size > headLength) {
        await handle.setPosition(max(headLength, file.size - partialChunkSize));
        tail.add(await handle.read(partialChunkSize));
      }

      final sink = _DigestSink();
      final input = sha256.startChunkedConversion(sink);
      input.add(head);
      input.add(tail.takeBytes());
      input.close();
      return sink.value.toString();
    } finally {
      await _closeQuietly(handle);
    }
  }

  Future<String> _fullDigest(
    DuplicateFile file,
    bool Function()? isCancelled,
  ) async {
    RandomAccessFile? handle;
    try {
      handle = await File(WindowsPath.forIo(file.path)).open();
      final length = await handle.length();
      if (length != file.size) {
        throw FileSystemException('文件在分析期间发生变化', file.path);
      }

      final sink = _DigestSink();
      final input = sha256.startChunkedConversion(sink);
      while (true) {
        if (isCancelled?.call() ?? false) {
          throw const _AnalysisCancelled();
        }
        final chunk = await handle.read(_hashChunkSize);
        if (chunk.isEmpty) break;
        input.add(chunk);
      }
      input.close();
      return sink.value.toString();
    } finally {
      await _closeQuietly(handle);
    }
  }

  static Future<void> _closeQuietly(RandomAccessFile? handle) async {
    try {
      await handle?.close();
    } on FileSystemException {
      // Read-only analysis: a close failure does not invalidate the result.
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}
}

class _AnalysisCancelled implements Exception {
  const _AnalysisCancelled();
}
