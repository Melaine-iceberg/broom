import 'clean_models.dart';

class QuarantineRetentionPolicy {
  const QuarantineRetentionPolicy({
    required this.enabled,
    required this.retentionDays,
    required this.maxBytes,
  });

  static const int minRetentionDays = 1;
  static const int maxRetentionDays = 3650;
  static const int minMaxBytes = 1024 * 1024;

  static const defaults = QuarantineRetentionPolicy(
    enabled: false,
    retentionDays: 30,
    maxBytes: 5 * 1024 * 1024 * 1024,
  );

  final bool enabled;
  final int retentionDays;
  final int maxBytes;

  bool get isValid =>
      retentionDays >= minRetentionDays &&
      retentionDays <= maxRetentionDays &&
      maxBytes >= minMaxBytes;

  QuarantineRetentionPolicy copyWith({
    bool? enabled,
    int? retentionDays,
    int? maxBytes,
  }) {
    return QuarantineRetentionPolicy(
      enabled: enabled ?? this.enabled,
      retentionDays: retentionDays ?? this.retentionDays,
      maxBytes: maxBytes ?? this.maxBytes,
    );
  }
}

class QuarantineRetentionReport {
  const QuarantineRetentionReport({
    required this.evaluatedSessionCount,
    required this.selectedSessionCount,
    required this.removedSessionCount,
    required this.removedFileCount,
    required this.removedBytes,
    required this.failureCount,
    required this.failures,
  });

  static const empty = QuarantineRetentionReport(
    evaluatedSessionCount: 0,
    selectedSessionCount: 0,
    removedSessionCount: 0,
    removedFileCount: 0,
    removedBytes: 0,
    failureCount: 0,
    failures: [],
  );

  final int evaluatedSessionCount;
  final int selectedSessionCount;
  final int removedSessionCount;
  final int removedFileCount;
  final int removedBytes;
  final int failureCount;
  final List<CleanFailure> failures;

  bool get didPurge =>
      removedSessionCount > 0 || removedFileCount > 0 || failureCount > 0;
}
