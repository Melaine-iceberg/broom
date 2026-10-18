import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class FileMetadata {
  const FileMetadata({
    this.created,
    this.modified,
    this.accessed,
    this.readOnly,
    this.acl,
    this.aclUnavailable = false,
  });

  final DateTime? created;
  final DateTime? modified;
  final DateTime? accessed;
  final bool? readOnly;
  final String? acl;
  final bool aclUnavailable;

  bool get hasRestorableValues =>
      created != null ||
      modified != null ||
      accessed != null ||
      readOnly != null ||
      acl != null;
}

abstract interface class FileMetadataAccess {
  Future<FileMetadata?> read(String path, {required bool captureAcl});

  Future<void> apply(String path, FileMetadata metadata);
}

class FileMetadataException implements Exception {
  const FileMetadataException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalFileMetadataAccess implements FileMetadataAccess {
  const LocalFileMetadataAccess();

  @override
  Future<FileMetadata?> read(String path, {required bool captureAcl}) async {
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return FileMetadata(
      created: stat.changed,
      modified: stat.modified,
      accessed: stat.accessed,
      readOnly: isReadOnlyMode(stat.mode),
      aclUnavailable: captureAcl,
    );
  }

  @override
  Future<void> apply(String path, FileMetadata metadata) async {
    final file = File(path);
    if (metadata.modified != null) {
      await file.setLastModified(metadata.modified!);
    }
    if (metadata.accessed != null) {
      await file.setLastAccessed(metadata.accessed!);
    }
  }
}

class MethodChannelFileMetadataAccess implements FileMetadataAccess {
  const MethodChannelFileMetadataAccess();

  static const channel = MethodChannel('broom/file_metadata');

  @override
  Future<FileMetadata?> read(String path, {required bool captureAcl}) async {
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file) return null;

    String? acl;
    var aclUnavailable = false;
    if (captureAcl) {
      try {
        final value = await channel.invokeMethod<String>('readAcl', {
          'path': path,
        });
        if (value == null || value.isEmpty) {
          aclUnavailable = true;
        } else {
          acl = value;
        }
      } on PlatformException {
        aclUnavailable = true;
      } on MissingPluginException {
        aclUnavailable = true;
      }
    }

    return FileMetadata(
      created: stat.changed,
      modified: stat.modified,
      accessed: stat.accessed,
      readOnly: isReadOnlyMode(stat.mode),
      acl: acl,
      aclUnavailable: aclUnavailable,
    );
  }

  @override
  Future<void> apply(String path, FileMetadata metadata) async {
    final arguments = <String, Object?>{
      'path': path,
      'readOnly': metadata.readOnly,
      if (metadata.acl != null) 'acl': metadata.acl,
      if (metadata.created != null) 'created': _fileTime(metadata.created!),
      if (metadata.modified != null) 'modified': _fileTime(metadata.modified!),
      if (metadata.accessed != null) 'accessed': _fileTime(metadata.accessed!),
    };
    try {
      await channel.invokeMethod<void>('applyMetadata', arguments);
    } on PlatformException catch (error) {
      throw FileMetadataException(_errorMessage(error));
    } on MissingPluginException {
      throw const FileMetadataException('当前系统不支持恢复文件元数据。');
    }
  }
}

/// ACLs are preserved by a same-volume rename. A cross-volume copy creates a
/// new file with the destination's inherited ACL, so capture the source DACL
/// before moving it.
bool shouldCaptureAcl(String sourcePath, String quarantineRoot) {
  final sourceRoot = p.windows
      .rootPrefix(p.windows.normalize(sourcePath))
      .toLowerCase();
  final quarantinePrefix = p.windows
      .rootPrefix(p.windows.normalize(quarantineRoot))
      .toLowerCase();
  return sourceRoot.isNotEmpty && sourceRoot != quarantinePrefix;
}

// Dart exposes the Windows read-only attribute by clearing all write bits.
bool isReadOnlyMode(int mode) => (mode & 0x92) == 0;

// FILETIME counts 100-nanosecond ticks since 1601-01-01 UTC.
int _fileTime(DateTime value) =>
    (value.toUtc().microsecondsSinceEpoch + 11644473600000000) * 10;

String _errorMessage(PlatformException error) {
  final details = error.details;
  final suffix = details is int
      ? '（Windows 错误 0x${details.toRadixString(16).toUpperCase().padLeft(8, '0')}）'
      : '';
  final message = error.message?.trim();
  return '${message == null || message.isEmpty ? '无法恢复文件元数据。' : message}$suffix';
}

FileMetadataAccess createFileMetadataAccess() {
  if (Platform.isWindows) return const MethodChannelFileMetadataAccess();
  return const LocalFileMetadataAccess();
}
