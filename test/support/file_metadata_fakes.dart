import 'package:broom/core/clean/file_metadata.dart';
import 'package:broom/core/platform/file_system.dart';

class FakeFileMetadataAccess implements FileMetadataAccess {
  FakeFileMetadataAccess({this.metadata, this.readError, this.applyError});

  FileMetadata? metadata;
  Object? readError;
  Object? applyError;
  final List<({String path, bool captureAcl})> reads = [];
  final List<({String path, FileMetadata metadata})> applies = [];

  @override
  Future<FileMetadata?> read(
    String path, {
    required FsStat stat,
    required bool captureAcl,
  }) async {
    reads.add((path: path, captureAcl: captureAcl));
    if (readError != null) throw readError!;
    return metadata;
  }

  @override
  Future<void> apply(String path, FileMetadata metadata) async {
    applies.add((path: path, metadata: metadata));
    if (applyError != null) throw applyError!;
  }
}
