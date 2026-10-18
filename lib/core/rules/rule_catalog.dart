import '../models/cleaner_rule.dart';
import 'windows_rules.dart';

class RuleCatalog {
  RuleCatalog({
    required this.version,
    required List<CleanerRule> rules,
    this.source = 'builtin',
    this.publishedAt,
  }) : rules = List.unmodifiable(rules);

  final String version;
  final String source;
  final DateTime? publishedAt;
  final List<CleanerRule> rules;

  bool get isBuiltin => source == 'builtin';

  static final builtin = RuleCatalog(
    version: 'builtin',
    source: 'builtin',
    rules: windowsCleanupRules,
  );
}

/// Strict codec for rule catalogs. Every persisted or downloaded rule must
/// carry its audit notes and at least one regression sample; an update cannot
/// quietly introduce an unexplained rule.
abstract final class RuleCatalogCodec {
  static const schemaVersion = 1;

  static Map<String, Object?> encodeRule(CleanerRule rule) => {
    'id': rule.id,
    'title': rule.title,
    if (rule.titleEn != null) 'titleEn': rule.titleEn,
    'category': rule.category,
    if (rule.categoryEn != null) 'categoryEn': rule.categoryEn,
    'description': rule.description,
    if (rule.descriptionEn != null) 'descriptionEn': rule.descriptionEn,
    'risk': rule.risk.name,
    'pathPatterns': rule.pathPatterns,
    'minAgeSeconds': rule.minAge.inSeconds,
    if (rule.extensions != null)
      'extensions': rule.extensions!.toList()..sort(),
    if (rule.excludedPathPatterns.isNotEmpty)
      'excludedPathPatterns': rule.excludedPathPatterns,
    if (rule.note != null) 'note': rule.note,
    if (rule.noteEn != null) 'noteEn': rule.noteEn,
    if (rule.audit != null) 'audit': _encodeAudit(rule.audit!),
  };

  static CleanerRule decodeRule(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('规则条目必须是对象');
    }
    final id = _requiredString(value['id'], 'id');
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]*$').hasMatch(id)) {
      throw FormatException('规则编号无效：$id');
    }
    final title = _requiredString(value['title'], '$id.title');
    final category = _requiredString(value['category'], '$id.category');
    final description = _requiredString(
      value['description'],
      '$id.description',
    );
    final risk = switch (value['risk']) {
      'safe' => CleanRisk.safe,
      'review' => CleanRisk.review,
      _ => throw FormatException('$id 的风险等级无效'),
    };
    final rawPatterns = value['pathPatterns'];
    if (rawPatterns is! List || rawPatterns.isEmpty) {
      throw FormatException('$id 缺少路径模板');
    }
    final patterns = <String>[];
    for (final raw in rawPatterns) {
      if (raw is! String || raw.trim().isEmpty) {
        throw FormatException('$id 的路径模板无效');
      }
      final pattern = raw.trim();
      if (pattern.contains('\u0000') ||
          pattern.contains('<') ||
          pattern.contains('>') ||
          pattern.contains('|') ||
          pattern.contains('"')) {
        throw FormatException('$id 的路径模板包含非法字符');
      }
      if (RegExp(r'(^|[\\/])\.\.([\\/]|$)').hasMatch(pattern)) {
        throw FormatException('$id 的路径模板不能包含 ..');
      }
      patterns.add(pattern);
    }
    final minAgeSeconds = value['minAgeSeconds'] ?? 0;
    if (minAgeSeconds is! int || minAgeSeconds < 0) {
      throw FormatException('$id 的保留时间无效');
    }
    Set<String>? extensions;
    final rawExtensions = value['extensions'];
    if (rawExtensions != null) {
      if (rawExtensions is! List || rawExtensions.isEmpty) {
        throw FormatException('$id 的扩展名列表无效');
      }
      extensions = <String>{};
      for (final raw in rawExtensions) {
        if (raw is! String || raw.trim().isEmpty) {
          throw FormatException('$id 的扩展名列表无效');
        }
        var extension = raw.trim().toLowerCase();
        if (extension.startsWith('.')) extension = extension.substring(1);
        if (extension.contains('\\') ||
            extension.contains('/') ||
            extension.contains('*')) {
          throw FormatException('$id 的扩展名无效：$raw');
        }
        extensions.add(extension);
      }
    }
    final excludedPatterns = _stringList(
      value['excludedPathPatterns'],
      '$id.excludedPathPatterns',
    );
    final audit = _decodeAudit(value['audit'], id);
    return CleanerRule(
      id: id,
      title: title,
      titleEn: _optionalString(value['titleEn']),
      category: category,
      categoryEn: _optionalString(value['categoryEn']),
      description: description,
      descriptionEn: _optionalString(value['descriptionEn']),
      risk: risk,
      pathPatterns: List.unmodifiable(patterns),
      minAge: Duration(seconds: minAgeSeconds),
      extensions: extensions,
      excludedPathPatterns: excludedPatterns,
      note: _optionalString(value['note']),
      noteEn: _optionalString(value['noteEn']),
      audit: audit,
    );
  }

  static Map<String, Object?> encodeCatalog(RuleCatalog catalog) => {
    'schemaVersion': schemaVersion,
    'version': catalog.version,
    'source': catalog.source,
    if (catalog.publishedAt != null)
      'publishedAt': catalog.publishedAt!.toUtc().toIso8601String(),
    'rules': [for (final rule in catalog.rules) encodeRule(rule)],
  };

  static RuleCatalog decodeCatalog(
    Object? value, {
    String fallbackSource = 'remote',
  }) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('规则目录必须是对象');
    }
    if (value['schemaVersion'] != schemaVersion) {
      throw FormatException('不支持的规则目录版本：${value['schemaVersion']}');
    }
    final version = _requiredString(value['version'], 'version');
    final source =
        value['source'] is String && (value['source'] as String).isNotEmpty
        ? value['source'] as String
        : fallbackSource;
    final rawRules = value['rules'];
    if (rawRules is! List || rawRules.isEmpty) {
      throw const FormatException('规则目录不能为空');
    }
    final rules = <CleanerRule>[];
    final ids = <String>{};
    for (final raw in rawRules) {
      final rule = decodeRule(raw);
      if (!ids.add(rule.id)) {
        throw FormatException('规则编号重复：${rule.id}');
      }
      rules.add(rule);
    }
    return RuleCatalog(
      version: version,
      source: source,
      publishedAt: DateTime.tryParse('${value['publishedAt'] ?? ''}'),
      rules: rules,
    );
  }

  static Map<String, Object?> _encodeAudit(RuleAudit audit) => {
    'reviewNotes': audit.reviewNotes,
    if (audit.reviewNotesEn != null) 'reviewNotesEn': audit.reviewNotesEn,
    'reverseEvidence': audit.reverseEvidence,
    if (audit.reverseEvidenceEn != null)
      'reverseEvidenceEn': audit.reverseEvidenceEn,
    'samples': [
      for (final sample in audit.samples)
        {
          'pattern': sample.pattern,
          'path': sample.path,
          'inScope': sample.inScope,
          'ageSeconds': sample.age.inSeconds,
          if (sample.reason != null) 'reason': sample.reason,
        },
    ],
  };

  static RuleAudit _decodeAudit(Object? value, String ruleId) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('$ruleId 缺少规则审计信息');
    }
    final reviewNotes = _requiredString(
      value['reviewNotes'],
      '$ruleId.audit.reviewNotes',
    );
    final reverseEvidence = _requiredString(
      value['reverseEvidence'],
      '$ruleId.audit.reverseEvidence',
    );
    final rawSamples = value['samples'];
    if (rawSamples is! List || rawSamples.isEmpty) {
      throw FormatException('$ruleId 缺少审计回归样例');
    }
    final samples = <RuleAuditSample>[];
    for (final raw in rawSamples) {
      if (raw is! Map<String, dynamic>) {
        throw FormatException('$ruleId 的审计样例无效');
      }
      final ageSeconds =
          raw['ageSeconds'] ?? const Duration(days: 30).inSeconds;
      if (ageSeconds is! int || ageSeconds < 0) {
        throw FormatException('$ruleId 的审计样例时间无效');
      }
      final inScope = raw['inScope'];
      if (inScope is! bool) {
        throw FormatException('$ruleId 的审计样例缺少 inScope');
      }
      samples.add(
        RuleAuditSample(
          pattern: _requiredString(raw['pattern'], '$ruleId.sample.pattern'),
          path: _requiredString(raw['path'], '$ruleId.sample.path'),
          inScope: inScope,
          age: Duration(seconds: ageSeconds),
          reason: _optionalString(raw['reason']),
        ),
      );
    }
    return RuleAudit(
      reviewNotes: reviewNotes,
      reviewNotesEn: _optionalString(value['reviewNotesEn']),
      reverseEvidence: reverseEvidence,
      reverseEvidenceEn: _optionalString(value['reverseEvidenceEn']),
      samples: List.unmodifiable(samples),
    );
  }

  static List<String> _stringList(Object? value, String field) {
    if (value == null) return const [];
    if (value is! List) throw FormatException('$field 必须是数组');
    final result = <String>[];
    for (final raw in value) {
      if (raw is! String || raw.trim().isEmpty) {
        throw FormatException('$field 包含无效值');
      }
      result.add(raw.trim());
    }
    return List.unmodifiable(result);
  }

  static String _requiredString(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field 不能为空');
    }
    return value.trim();
  }

  static String? _optionalString(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }
}
