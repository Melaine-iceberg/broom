import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'file_system.dart';
import 'windows_path.dart';

/// Client for the native `FindFirstFileW` enumerator.
///
/// One call returns every child of a directory as four columns — names, sizes,
/// modification times and attributes — because `WIN32_FIND_DATAW` already
/// carries them. That replaces dart:io's listing plus one `stat` per child.
///
/// Failures are split by scope:
/// - the channel is missing (other platforms, unit tests, old builds) →
///   [list] returns null once and stays null, so callers use the dart:io path;
/// - one directory cannot be read → [FileSystemException] with the Win32 code,
///   which the scanner reports like any other directory error.
class MethodChannelDirectoryEnumerator {
  MethodChannelDirectoryEnumerator({
    this.channel = const MethodChannel(_channelName),
  });

  static const String _channelName = 'broom/directory_enum';

  // FILE_ATTRIBUTE_* bits the type mapping needs.
  static const int _attributeDirectory = 0x00000010;
  static const int _attributeReparsePoint = 0x00000400;

  final MethodChannel channel;
  bool _unavailable = false;
  bool? _available;

  bool get isAvailable => !_unavailable;

  /// Asks the native side whether it implements this channel.
  ///
  /// Worker isolates can only use the channel when the root isolate proved it
  /// works: a platform message sent from a background isolate without a live
  /// engine (unit tests) aborts the isolate instead of raising a catchable
  /// error. Callers therefore probe once from the root isolate and pass the
  /// verdict down.
  Future<bool> probe() async {
    final cached = _available;
    if (cached != null) return cached;
    var available = false;
    try {
      final value = await channel.invokeMethod<bool>('ping');
      available = value ?? false;
    } on MissingPluginException {
      available = false;
    } on FlutterError {
      available = false;
    } on StateError {
      available = false;
    } on PlatformException {
      available = false;
    }
    if (!available) _unavailable = true;
    _available = available;
    return available;
  }

  Future<List<FsEntryDetail>?> list(String path) async {
    if (_unavailable) return null;
    final Object? response;
    try {
      response = await channel.invokeMethod<Object?>('listDirectory', {
        'path': WindowsPath.canonical(path),
      });
    } on MissingPluginException {
      _unavailable = true;
      return null;
    } on FlutterError {
      // No binding (plain `dart:io` tests) means there is no channel to talk to.
      _unavailable = true;
      return null;
    } on StateError {
      // A background isolate without a root isolate token cannot reach the
      // platform; the caller keeps the dart:io path.
      _unavailable = true;
      return null;
    } on PlatformException catch (error) {
      final message = error.message ?? error.code;
      final details = error.details;
      throw FileSystemException(
        message,
        path,
        OSError(message, details is int ? details : 0),
      );
    }
    if (response == null) return null;
    return _decode(response, path);
  }

  List<FsEntryDetail> _decode(Object? response, String path) {
    if (response is! Map) {
      throw FileSystemException('目录枚举返回了无法识别的结果', path);
    }
    final names = response['names'];
    final sizes = response['sizes'];
    final modified = response['modified'];
    final attributes = response['attributes'];
    if (names is! List ||
        sizes is! List ||
        modified is! List ||
        attributes is! List ||
        sizes.length != names.length ||
        modified.length != names.length ||
        attributes.length != names.length) {
      throw FileSystemException('目录枚举返回的字段不完整', path);
    }

    final entries = <FsEntryDetail>[];
    for (var index = 0; index < names.length; index++) {
      final name = names[index];
      final attribute = attributes[index];
      if (name is! String || name.isEmpty || attribute is! int) continue;
      final size = sizes[index];
      final modifiedMicros = modified[index];
      entries.add(
        FsEntryDetail(
          name: name,
          type: _typeOf(attribute),
          size: size is int ? size : 0,
          modified: modifiedMicros is int && modifiedMicros > 0
              ? DateTime.fromMicrosecondsSinceEpoch(
                  modifiedMicros,
                  isUtc: true,
                ).toLocal()
              : DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }
    return entries;
  }

  static FsEntityType _typeOf(int attributes) {
    if ((attributes & _attributeReparsePoint) != 0) return FsEntityType.link;
    if ((attributes & _attributeDirectory) != 0) return FsEntityType.directory;
    return FsEntityType.file;
  }
}

/// Decides once, from the root isolate, whether spawned isolates may use the
/// native directory enumerator.
///
/// A background isolate can only reach the platform when the engine shares the
/// root isolate's messenger, and a message sent without one aborts the isolate
/// instead of raising a catchable error. Callers must probe here before
/// spawning and forward [RootIsolateToken.instance] to the worker.
Future<bool> probeDetailedListingFromRoot() async {
  if (!Platform.isWindows) return false;
  if (RootIsolateToken.instance == null) return false;
  return MethodChannelDirectoryEnumerator().probe();
}
