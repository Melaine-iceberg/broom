enum NtfsIndexStatus {
  available,
  notNtfs,
  unprivileged,
  journalInactive,
  unsupported,
  error,
}

class NtfsIndexAvailability {
  const NtfsIndexAvailability(this.status, {this.message});

  const NtfsIndexAvailability.available() : this(NtfsIndexStatus.available);

  final NtfsIndexStatus status;
  final String? message;

  bool get isAvailable => status == NtfsIndexStatus.available;
}

class NtfsIndexEntry {
  const NtfsIndexEntry(this.path);

  final String path;
}

/// Optional acceleration backed by the NTFS USN journal. Implementations must
/// never replace the directory walker: any probe or stream failure makes the
/// scanner fall back to normal traversal for that root.
abstract interface class NtfsIndex {
  Future<NtfsIndexAvailability> probe(String root);

  Stream<NtfsIndexEntry> enumerate(
    String root, {
    Set<String>? extensions,
    int? maxItems,
    bool Function()? isCancelled,
  });
}

class UnavailableNtfsIndex implements NtfsIndex {
  const UnavailableNtfsIndex();

  @override
  Future<NtfsIndexAvailability> probe(String root) async =>
      const NtfsIndexAvailability(
        NtfsIndexStatus.unsupported,
        message: 'NTFS 索引在当前平台不可用',
      );

  @override
  Stream<NtfsIndexEntry> enumerate(
    String root, {
    Set<String>? extensions,
    int? maxItems,
    bool Function()? isCancelled,
  }) {
    return const Stream.empty();
  }
}
