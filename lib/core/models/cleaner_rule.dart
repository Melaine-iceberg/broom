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
    this.content,
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

  /// Optional fixture content. Audit tests write this instead of the default
  /// placeholder file, which lets version-aware rules seed files such as a
  /// browser `Preferences` document.
  final String? content;
}

/// Stable key for the category whose rules are created at runtime from the
/// leftover catalog. It never exists in the built-in rule list, so the scope
/// UI has to render it explicitly.
const leftoverCategoryKey = 'leftover';

const leftoverCategoryLabel = '卸载残留';
const leftoverCategoryLabelEn = 'Uninstall leftovers';

/// Stable, language-independent category key used for scan filters and
/// persisted settings. Localized labels remain on [CleanerRule.category].
String ruleCategoryKey(CleanerRule rule) {
  if (rule.id == 'windows.thumbnail_icon_cache') return 'thumbnails';
  if (rule.id == 'system.linux_thumbnails') return 'thumbnails';
  if (rule.id == 'browser.extension_scripts' ||
      rule.id == 'browser.linux_extension_versions' ||
      rule.id == 'browser.windows_extension_versions') {
    return 'browser_extension';
  }
  if (rule.id.startsWith(leftoverRuleIdPrefix)) return leftoverCategoryKey;
  return switch (rule.id.split('.').first) {
    'windows' => 'system',
    'system' => 'system',
    'browser' => 'browser',
    'dev' => 'dev',
    'app' => 'app',
    'gpu' => 'gpu',
    'logs' => 'logs',
    _ => 'other',
  };
}

/// One scan category as presented to the scope and settings surfaces.
///
/// [key] is the persisted category id, [label]/[labelEn] are the localized
/// names, and [rules] holds the rules the category currently contributes. The
/// leftover category is intentionally present with an empty list before the
/// first detection so its toggle stays reachable.
class RuleCategoryGroup {
  const RuleCategoryGroup({
    required this.key,
    required this.label,
    required this.labelEn,
    required this.rules,
  });

  final String key;
  final String label;
  final String labelEn;
  final List<CleanerRule> rules;

  bool get isLeftover => key == leftoverCategoryKey;
  int get ruleCount => rules.length;
  bool get isEmpty => rules.isEmpty;
}

/// Groups [rules] by [ruleCategoryKey], preserving first-seen order.
///
/// The leftover category is always appended, because its rules only exist
/// after runtime detection and a category that disappears from the UI can no
/// longer be enabled or disabled.
List<RuleCategoryGroup> groupRuleCategories(Iterable<CleanerRule> rules) {
  final grouped = <String, List<CleanerRule>>{};
  final labels = <String, (String, String)>{};
  for (final rule in rules) {
    final key = ruleCategoryKey(rule);
    grouped.putIfAbsent(key, () => <CleanerRule>[]).add(rule);
    labels.putIfAbsent(
      key,
      () => (rule.category, rule.categoryEn ?? rule.category),
    );
  }
  grouped.putIfAbsent(leftoverCategoryKey, () => <CleanerRule>[]);
  labels.putIfAbsent(
    leftoverCategoryKey,
    () => (leftoverCategoryLabel, leftoverCategoryLabelEn),
  );
  return [
    for (final entry in grouped.entries)
      RuleCategoryGroup(
        key: entry.key,
        label: labels[entry.key]!.$1,
        labelEn: labels[entry.key]!.$2,
        rules: List<CleanerRule>.unmodifiable(entry.value),
      ),
  ];
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
    this.keepActiveExtensionVersions = false,
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

  /// Treats each declared root as a Chromium profile and resolves only
  /// extension version directories that the profile's `Preferences` no longer
  /// references. Missing or unreadable preferences make the rule fail closed.
  final bool keepActiveExtensionVersions;
  final String? note;
  final String? titleEn;
  final String? categoryEn;
  final String? descriptionEn;
  final String? noteEn;
  final RuleAudit? audit;
}
