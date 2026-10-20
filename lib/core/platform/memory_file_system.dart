import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'file_system.dart';
import 'windows_path.dart';

/// Hook invoked before every mutating or reading operation.
///
/// Tests use it to introduce ordering barriers, inject failures or record which
/// filesystem calls an operation performs. Paths are the canonical paths passed
/// by the caller, not the internal normalized keys.
typedef FsOperationHook = FutureOr<void> Function(
  String operation,
  String path,
);

/// In-memory [BroomFileSystem] for tests and benchmarks.
///
/// Paths are Windows-style, case-insensitive and independent of the host
/// platform, so the same suite runs on CI without touching a real disk. Files
/// store their reported length separately from their bytes; seeding a large
/// file therefore does not allocate a huge buffer unless it is read.
class MemoryFileSystem implements BroomFileSystem, DetailedDirectoryListing {
  MemoryFileSystem({this.onOperation});

  FsOperationHook? onOperation;

  final Map<String, _MemNode> _nodes = {};

  static String _key(String path) =>
      p.windows.normalize(WindowsPath.canonical(path)).toLowerCase();

  static String _display(String path) =>
      p.windows.normalize(WindowsPath.canonical(path));

  static void _requireAbsolute(String path) {
    if (!p.windows.isAbsolute(WindowsPath.canonical(path))) {
      throw ArgumentError.value(path, 'path', '路径必须是绝对路径');
    }
  }

  /// Seeds a directory (and missing parents).
  String seedDirectory(String path, {DateTime? modified}) {
    final normalized = _display(path);
    _seedDirectoryNode(normalized, modified ?? DateTime(2026));
    return normalized;
  }

  /// Seeds a file (and missing parents).
  ///
  /// [size] defaults to the length of [contents]. Seeding a sparse file with a
  /// large [size] is cheap because bytes are generated only when read.
  String seedFile(
    String path, {
    String? contents,
    int? size,
    List<int>? bytes,
    DateTime? modified,
    bool readOnly = false,
  }) {
    final normalized = _display(path);
    _seedDirectoryNode(
      p.windows.dirname(normalized),
      modified ?? DateTime(2026),
    );
    final data = bytes ?? (contents == null ? null : utf8.encode(contents));
    final node = _MemNode(
      path: normalized,
      kind: FsEntityType.file,
      bytes: data == null ? null : Uint8List.fromList(data),
      size: size ?? data?.length ?? 0,
      modified: modified ?? DateTime(2026),
      readOnly: readOnly,
    );
    _nodes[_key(normalized)] = node;
    _parentNode(normalized)?.children.add(_key(normalized));
    return normalized;
  }

  void seedLink(String path) {
    final normalized = _display(path);
    _seedDirectoryNode(p.windows.dirname(normalized), DateTime(2026));
    _nodes[_key(normalized)] = _MemNode(
      path: normalized,
      kind: FsEntityType.link,
      modified: DateTime(2026),
    );
    _parentNode(normalized)?.children.add(_key(normalized));
  }

  /// Replaces a file's reported length without touching its bytes.
  void setLength(String path, int length) {
    final node = _requireNode(path);
    node.size = length;
  }

  /// Replaces a file's bytes and length.
  void setBytes(String path, List<int> bytes) {
    final node = _requireNode(path);
    node.bytes = Uint8List.fromList(bytes);
    node.size = bytes.length;
  }

  void setModified(String path, DateTime modified) {
    _requireNode(path).modified = modified;
  }

  bool hasNode(String path) => _nodes.containsKey(_key(path));

  void removeNode(String path) {
    final key = _key(path);
    final node = _nodes.remove(key);
    if (node == null) return;
    _parentNode(path)?.children.remove(key);
    if (node.kind == FsEntityType.directory) {
      final prefix = '$key${p.windows.separator}';
      _nodes.removeWhere((candidate, _) => candidate.startsWith(prefix));
    }
  }

  @override
  Future<FsEntityType> type(String path) async {
    await _before('type', path);
    return _nodes[_key(path)]?.kind ?? FsEntityType.notFound;
  }

  @override
  Future<FsStat> stat(String path) async {
    await _before('stat', path);
    final node = _nodes[_key(path)];
    if (node == null) throw _notFound(path);
    return FsStat(
      type: node.kind,
      size: node.kind == FsEntityType.file ? node.size : 0,
      modified: node.modified,
      mode: node.readOnly ? 0x1 : 0,
      // The in-memory backend models a single timestamp: creation and last
      // access follow the modification time so the clean loop always has the
      // restorable values it would get from a real stat.
      accessed: node.modified,
      changed: node.modified,
    );
  }

  @override
  Stream<FsEntry> list(String path) async* {
    await _before('list', path);
    final node = _nodes[_key(path)];
    if (node == null || node.kind != FsEntityType.directory) {
      throw FileSystemException('目录不存在', path, const OSError('文件系统操作失败', 3));
    }
    final children = node.children.toList()..sort();
    for (final key in children) {
      final child = _nodes[key];
      if (child == null) continue;
      yield FsEntry(path: child.path, type: child.kind);
    }
  }

  @override
  Stream<FsEntryDetail> listDetailed(String path) async* {
    await _before('listDetailed', path);
    final node = _nodes[_key(path)];
    if (node == null || node.kind != FsEntityType.directory) {
      throw FileSystemException('目录不存在', path, const OSError('文件系统操作失败', 3));
    }
    final children = node.children.toList()..sort();
    for (final key in children) {
      final child = _nodes[key];
      if (child == null) continue;
      yield FsEntryDetail(
        name: _leaf(child.path),
        type: child.kind,
        size: child.kind == FsEntityType.file ? child.size : 0,
        modified: child.modified,
      );
    }
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) async {
    await _before('createDirectory', path);
    _requireAbsolute(path);
    final normalized = _display(path);
    final key = _key(normalized);
    final existing = _nodes[key];
    if (existing != null) {
      if (existing.kind == FsEntityType.directory) return;
      throw FileSystemException(
        '路径已存在且不是目录',
        path,
        const OSError('文件系统操作失败', 183),
      );
    }
    if (!recursive) {
      final parent = _parentNode(normalized);
      if (parent == null) {
        throw FileSystemException('父目录不存在', path, const OSError('文件系统操作失败', 3));
      }
    }
    _seedDirectoryNode(normalized, DateTime.now());
  }

  @override
  Future<String> readString(String path) async {
    await _before('readString', path);
    final bytes = await _readFileBytes(path);
    return utf8.decode(bytes);
  }

  @override
  Future<List<String>> readLines(String path) async {
    final text = await readString(path);
    return const LineSplitter().convert(text);
  }

  @override
  Future<List<int>> readBytes(String path) async {
    await _before('readBytes', path);
    return _readFileBytes(path);
  }

  @override
  Future<void> writeString(
    String path,
    String contents, {
    bool append = false,
    bool flush = true,
  }) async {
    await _before('writeString', path);
    final normalized = _display(path);
    final key = _key(normalized);
    var node = _nodes[key];
    if (node == null) {
      if (_parentNode(normalized) == null) {
        throw FileSystemException('父目录不存在', path, const OSError('文件系统操作失败', 3));
      }
      node = _MemNode(
        path: normalized,
        kind: FsEntityType.file,
        modified: DateTime.now(),
      );
      _nodes[key] = node;
      _parentNode(normalized)?.children.add(key);
    }
    if (node.kind != FsEntityType.file) {
      throw FileSystemException('路径不是文件', path, const OSError('文件系统操作失败', 5));
    }
    final data = Uint8List.fromList(utf8.encode(contents));
    final existing = append ? _materializedBytes(node) : Uint8List(0);
    final merged = Uint8List(existing.length + data.length)
      ..setRange(0, existing.length, existing)
      ..setRange(existing.length, existing.length + data.length, data);
    node
      ..bytes = merged
      ..size = merged.length
      ..modified = DateTime.now();
  }

  @override
  Future<FsFileWriter> openAppend(String path) async {
    await _before('openAppend', path);
    final normalized = _display(path);
    final key = _key(normalized);
    var node = _nodes[key];
    if (node == null) {
      if (_parentNode(normalized) == null) {
        throw FileSystemException('父目录不存在', path, const OSError('文件系统操作失败', 3));
      }
      node = _MemNode(
        path: normalized,
        kind: FsEntityType.file,
        modified: DateTime.now(),
      );
      _nodes[key] = node;
      _parentNode(normalized)?.children.add(key);
    }
    if (node.kind != FsEntityType.file) {
      throw FileSystemException('路径不是文件', path, const OSError('文件系统操作失败', 5));
    }
    return _MemoryFileWriter(node);
  }

  @override
  Future<FsFileWriter> openWrite(String path) async {
    await _before('openWrite', path);
    final normalized = _display(path);
    final key = _key(normalized);
    var node = _nodes[key];
    if (node == null) {
      if (_parentNode(normalized) == null) {
        throw FileSystemException('父目录不存在', path, const OSError('文件系统操作失败', 3));
      }
      node = _MemNode(
        path: normalized,
        kind: FsEntityType.file,
        modified: DateTime.now(),
      );
      _nodes[key] = node;
      _parentNode(normalized)?.children.add(key);
    }
    if (node.kind != FsEntityType.file) {
      throw FileSystemException('路径不是文件', path, const OSError('文件系统操作失败', 5));
    }
    node
      ..bytes = Uint8List(0)
      ..size = 0;
    return _MemoryFileWriter(node, position: 0);
  }

  @override
  Future<void> rename(String from, String to) async {
    await _before('rename', from);
    _requireAbsolute(from);
    _requireAbsolute(to);
    final sourceKey = _key(from);
    final source = _nodes[sourceKey];
    if (source == null) throw _notFound(from);
    final target = _display(to);
    final targetKey = _key(target);
    final destinationParent = _parentNode(target);
    if (destinationParent == null) {
      throw FileSystemException('目标目录不存在', to, const OSError('文件系统操作失败', 3));
    }
    if (sourceKey != targetKey && _nodes.containsKey(targetKey)) {
      final existing = _nodes[targetKey]!;
      if (source.kind == FsEntityType.file &&
          existing.kind == FsEntityType.file) {
        // Dart's File.rename uses MoveFileEx with REPLACE_EXISTING on Windows.
        _nodes.remove(targetKey);
        _parentNode(target)?.children.remove(targetKey);
      } else {
        throw FileSystemException('目标已存在', to, const OSError('文件系统操作失败', 183));
      }
    }
    final sourceDisplay = source.path;
    if (source.kind == FsEntityType.directory) {
      final prefix = '$sourceKey${p.windows.separator}';
      if (targetKey.startsWith(prefix)) {
        throw FileSystemException(
          '无法将目录移动到其子目录',
          to,
          const OSError('文件系统操作失败', 87),
        );
      }
      final movedKeys = _nodes.keys
          .where((key) => key == sourceKey || key.startsWith(prefix))
          .toList();
      if (sourceKey != targetKey) {
        _parentNode(sourceDisplay)?.children.remove(sourceKey);
      }
      final moved = <_MemNode>[];
      for (final key in movedKeys) {
        final node = _nodes.remove(key)!;
        final suffix = node.path.substring(sourceDisplay.length);
        node.path = '$target$suffix';
        if (node.kind == FsEntityType.directory) node.children.clear();
        _nodes[_key(node.path)] = node;
        moved.add(node);
      }
      for (final node in moved) {
        final key = _key(node.path);
        if (key == targetKey) continue;
        _parentNode(node.path)?.children.add(key);
      }
      destinationParent.children.add(targetKey);
    } else {
      _parentNode(sourceDisplay)?.children.remove(sourceKey);
      _nodes.remove(sourceKey);
      source.path = target;
      _nodes[targetKey] = source;
      destinationParent.children.add(targetKey);
    }
  }

  @override
  Future<void> copy(String from, String to) async {
    await _before('copy', from);
    final source = _nodes[_key(from)];
    if (source == null || source.kind != FsEntityType.file) {
      throw _notFound(from);
    }
    final target = _display(to);
    final targetKey = _key(target);
    if (_parentNode(target) == null) {
      throw FileSystemException('目标目录不存在', to, const OSError('文件系统操作失败', 3));
    }
    var node = _nodes[targetKey];
    if (node == null) {
      node = _MemNode(
        path: target,
        kind: FsEntityType.file,
        modified: DateTime.now(),
      );
      _nodes[targetKey] = node;
      _parentNode(target)?.children.add(targetKey);
    } else if (node.kind != FsEntityType.file) {
      throw FileSystemException('目标不是文件', to, const OSError('文件系统操作失败', 5));
    }
    node
      ..bytes = source.bytes == null ? null : Uint8List.fromList(source.bytes!)
      ..size = source.size
      ..modified = DateTime.now();
  }

  @override
  Future<void> deleteFile(String path) async {
    await _before('deleteFile', path);
    final key = _key(path);
    final node = _nodes[key];
    if (node == null) throw _notFound(path);
    if (node.kind == FsEntityType.directory) {
      throw FileSystemException('路径是目录', path, const OSError('文件系统操作失败', 5));
    }
    if (node.readOnly) {
      throw FileSystemException('文件为只读', path, const OSError('文件系统操作失败', 5));
    }
    _nodes.remove(key);
    _parentNode(path)?.children.remove(key);
  }

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) async {
    await _before('deleteDirectory', path);
    final key = _key(path);
    final node = _nodes[key];
    if (node == null) throw _notFound(path);
    if (node.kind != FsEntityType.directory) {
      throw FileSystemException('路径不是目录', path, const OSError('文件系统操作失败', 267));
    }
    if (!recursive && node.children.isNotEmpty) {
      throw FileSystemException('目录不为空', path, const OSError('文件系统操作失败', 145));
    }
    _nodes.remove(key);
    _parentNode(node.path)?.children.remove(key);
    if (node.children.isNotEmpty) {
      final prefix = '$key${p.windows.separator}';
      _nodes.removeWhere((candidate, _) => candidate.startsWith(prefix));
    }
  }

  @override
  Future<int> length(String path) async {
    await _before('length', path);
    final node = _nodes[_key(path)];
    if (node == null) throw _notFound(path);
    if (node.kind != FsEntityType.file) {
      throw FileSystemException('路径不是文件', path, const OSError('文件系统操作失败', 5));
    }
    return node.size;
  }

  static String _leaf(String path) {
    final cut = path.lastIndexOf(p.windows.separator);
    return cut < 0 ? path : path.substring(cut + 1);
  }

  Future<void> _before(String operation, String path) async {
    final hook = onOperation;
    if (hook == null) return;
    await hook(operation, path);
  }

  Future<Uint8List> _readFileBytes(String path) async {
    final node = _nodes[_key(path)];
    if (node == null) throw _notFound(path);
    if (node.kind != FsEntityType.file) {
      throw FileSystemException('路径不是文件', path, const OSError('文件系统操作失败', 5));
    }
    return _materializedBytes(node);
  }

  Uint8List _materializedBytes(_MemNode node) {
    final bytes = node.bytes;
    if (bytes != null) return Uint8List.fromList(bytes);
    return Uint8List(node.size);
  }

  void _seedDirectoryNode(String path, DateTime modified) {
    _requireAbsolute(path);
    final missing = <String>[];
    var current = _display(path);
    while (true) {
      final existing = _nodes[_key(current)];
      if (existing != null) {
        if (existing.kind != FsEntityType.directory) {
          throw FileSystemException('路径已存在且不是目录', current);
        }
        break;
      }
      missing.add(current);
      final parent = p.windows.dirname(current);
      if (_key(parent) == _key(current)) break;
      current = parent;
    }
    for (final directory in missing.reversed) {
      final key = _key(directory);
      _nodes[key] = _MemNode(
        path: directory,
        kind: FsEntityType.directory,
        modified: modified,
      );
      final parentPath = p.windows.dirname(directory);
      if (_key(parentPath) != key) {
        _nodes[_key(parentPath)]?.children.add(key);
      }
    }
  }

  _MemNode? _parentNode(String path) {
    final parent = p.windows.dirname(_display(path));
    if (_key(parent) == _key(path)) return null;
    return _nodes[_key(parent)];
  }

  _MemNode _requireNode(String path) {
    final node = _nodes[_key(path)];
    if (node == null) throw _notFound(path);
    return node;
  }

  static FileSystemException _notFound(String path) {
    return FileSystemException(
      '系统找不到指定的文件',
      path,
      const OSError('文件系统操作失败', 2),
    );
  }
}

class _MemNode {
  _MemNode({
    required this.path,
    required this.kind,
    this.bytes,
    this.size = 0,
    required this.modified,
    this.readOnly = false,
  });

  String path;
  final FsEntityType kind;
  Uint8List? bytes;
  int size;
  DateTime modified;
  bool readOnly;
  final Set<String> children = {};
}

class _MemoryFileWriter implements FsFileWriter {
  _MemoryFileWriter(this._node, {int? position})
    : _position = position ?? _node.size;

  final _MemNode _node;
  int _position;

  @override
  Future<int> position() async => _position;

  @override
  Future<void> setPosition(int position) async {
    if (position < 0 || position > _node.size) {
      throw FileSystemException(
        '位置超出文件范围',
        _node.path,
        const OSError('文件系统操作失败', 131),
      );
    }
    _position = position;
  }

  @override
  Future<void> writeString(String contents) async {
    final data = Uint8List.fromList(utf8.encode(contents));
    final existing = _node.bytes ?? Uint8List(0);
    final end = _position + data.length;
    final targetLength = end > _node.size ? end : _node.size;
    final merged = Uint8List(targetLength);
    if (existing.isNotEmpty) {
      final copyLength = existing.length < targetLength
          ? existing.length
          : targetLength;
      merged.setRange(0, copyLength, existing);
    }
    merged.setRange(_position, end, data);
    _node
      ..bytes = merged
      ..size = targetLength
      ..modified = DateTime.now();
    _position = end;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> truncate(int length) async {
    if (length < 0 || length > _node.size) {
      throw FileSystemException(
        '截断长度无效',
        _node.path,
        const OSError('文件系统操作失败', 131),
      );
    }
    final existing = _node.bytes;
    if (existing == null) {
      _node.size = length;
    } else {
      final merged = Uint8List(length);
      merged.setRange(0, length, existing);
      _node
        ..bytes = merged
        ..size = length;
    }
    if (_position > length) _position = length;
  }

  @override
  Future<void> close() async {}
}
