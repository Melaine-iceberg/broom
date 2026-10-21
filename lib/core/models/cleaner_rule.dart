import 'leftover_models.dart';

enum CleanRisk { safe, review, info }

class RuleAudit {
  const RuleAudit({
    required this.reviewNotes,
    required this.reverseEvidence,
    required this.samples,
    this.reviewNotesEn,
    this.reverseEvidenceEn,
  });

  /// Why the rule exists, what it intentionally covers, and why its declared
  /// [CleanRisk] level is acceptable.
  final String reviewNotes;
  final String? reviewNotesEn;

  /// What must stay outside the rule: adjacent directories, personal data, or
  /// files excluded by extension and age. This is the negative boundary that
  /// reviewers use to judge whether a rule expands the deletion surface.
  final String reverseEvidence;
  final String? reverseEvidenceEn;

  /// Path fixtures exercised by the rule audit regression tests.
  final List<RuleAuditSample> samples;
}

class RuleAuditSample {
  const RuleAuditSample({
    required this.pattern,
    required this.path,
    required this.inScope,
    this.age = const Duration(days: 30),
    this.reason,
  });

  /// One of the rule's path patterns. System cache rules use [displayPath].
  final String pattern;

  /// File path to materialize in the audit fixture. Environment variables are
  /// substituted by the audit test.
  final String path;

  /// Whether scanning this rule must include the file.
  final bool inScope;

  /// Age of the fixture file, used to exercise min-age filters.
  final Duration age;

  /// Optional engineering note for failures and future reviews.
  final String? reason;
}

/// Stable, language-independent category key used for scan filters and
/// persisted settings. Localized labels remain on [CleanerRule.category].
String ruleCategoryKey(CleanerRule rule) {
  if (rule.id == 'windows.thumbnail_icon_cache') return 'thumbnails';
  if (rule.id == 'browser.extension_scripts') return 'browser_extension';
  if (rule.id.startsWith(leftoverRuleIdPrefix)) return 'leftover';
  return switch (rule.id.split('.').first) {
    'windows' => 'system',
    'browser' => 'browser',
    'dev' => 'dev',
    'app' => 'app',
    'gpu' => 'gpu',
    'logs' => 'logs',
    _ => 'other',
  };
}

class CleanerRule {
  const CleanerRule({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.pathPatterns,
    this.risk = CleanRisk.safe,
    this.minAge = Duration.zero,
    this.extensions,
    this.excludedPathPatterns = const [],
    this.note,
    this.titleEn,
    this.categoryEn,
    this.descriptionEn,
    this.noteEn,
    this.audit,
  });

  final String id;
  final String title;
  final String category;
  final String description;
  final CleanRisk risk;
  final List<String> pathPatterns;
  final Duration minAge;
  final Set<String>? extensions;

  /// Cache subdirectories claimed by a different rule. When this rule's roots
  /// overlap another rule with a stricter retention policy, these paths are
  /// skipped so the owning rule can apply its own filters.
  final List<String> excludedPathPatterns;
  final String? note;
  final String? titleEn;
  final String? categoryEn;
  final String? descriptionEn;
  final String? noteEn;
  final RuleAudit? audit;
}
