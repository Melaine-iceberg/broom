import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/models/cleaner_rule.dart';
import '../core/models/system_models.dart';
import 'broom_translations_en.dart';

class BroomStrings {
  const BroomStrings._(this.localeName, this._overrides);

  static const zh = BroomStrings._('zh', <String, String>{});
  static const en = BroomStrings._('en', translationsEn);

  static const supportedLocales = <Locale>[Locale('zh'), Locale('en')];

  static const delegate = _BroomStringsDelegate();

  // Controllers render messages without a BuildContext; the app updates this
  // whenever the resolved locale changes.
  static BroomStrings instance = zh;

  final String localeName;
  final Map<String, String> _overrides;

  static BroomStrings forLocale(Locale locale) {
    return locale.languageCode == 'en' ? en : zh;
  }

  static BroomStrings of(BuildContext context) {
    return Localizations.of<BroomStrings>(context, BroomStrings) ?? zh;
  }

  String t(String source) => _overrides[source] ?? source;

  String ruleTitle(CleanerRule rule) =>
      localeName == 'en' ? (rule.titleEn ?? rule.title) : rule.title;

  String ruleCategory(CleanerRule rule) =>
      localeName == 'en' ? (rule.categoryEn ?? rule.category) : rule.category;

  String ruleDescription(CleanerRule rule) => localeName == 'en'
      ? (rule.descriptionEn ?? rule.description)
      : rule.description;

  String? ruleNote(CleanerRule rule) =>
      localeName == 'en' ? (rule.noteEn ?? rule.note) : rule.note;

  String auditReviewNotes(RuleAudit audit) => localeName == 'en'
      ? (audit.reviewNotesEn ?? audit.reviewNotes)
      : audit.reviewNotes;

  String auditReverseEvidence(RuleAudit audit) => localeName == 'en'
      ? (audit.reverseEvidenceEn ?? audit.reverseEvidence)
      : audit.reverseEvidence;

  String systemRuleTitle(SystemCacheRule rule) =>
      localeName == 'en' ? (rule.titleEn ?? rule.title) : rule.title;

  String systemRuleCategory(SystemCacheRule rule) =>
      localeName == 'en' ? (rule.categoryEn ?? rule.category) : rule.category;

  String systemRuleDescription(SystemCacheRule rule) => localeName == 'en'
      ? (rule.descriptionEn ?? rule.description)
      : rule.description;

  String? systemRuleNote(SystemCacheRule rule) =>
      localeName == 'en' ? (rule.noteEn ?? rule.note) : rule.note;

  String serviceLabel(SystemServiceSpec service) =>
      localeName == 'en' ? (service.labelEn ?? service.label) : service.label;

  String tf(String source, [Map<String, Object?> args = const {}]) {
    var template = t(source);
    final count = args['count'];
    template = template.replaceAllMapped(_pluralPattern, (match) {
      final branch = count == 1 ? match.group(2)! : match.group(3)!;
      return branch.replaceAll('#', _formatValue(count));
    });
    template = template.replaceAllMapped(_placeholderPattern, (match) {
      final name = match.group(1)!;
      if (!args.containsKey(name)) return match.group(0)!;
      return _formatValue(args[name]);
    });
    return template;
  }

  static String _formatValue(Object? value) {
    if (value is int) {
      return NumberFormat.decimalPattern(instance.localeName).format(value);
    }
    return '$value';
  }

  static final _pluralPattern = RegExp(
    r'\{(\w+),\s*plural,\s*one\{([^{}]*)\}\s*other\{([^{}]*)\}\}',
  );
  static final _placeholderPattern = RegExp(r'\{(\w+)\}');
}

class _BroomStringsDelegate extends LocalizationsDelegate<BroomStrings> {
  const _BroomStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'zh' || locale.languageCode == 'en';

  @override
  Future<BroomStrings> load(Locale locale) =>
      SynchronousFuture(BroomStrings.forLocale(locale));

  @override
  bool shouldReload(covariant LocalizationsDelegate<BroomStrings> old) => false;
}

extension BroomStringsContext on BuildContext {
  BroomStrings get strings => BroomStrings.of(this);

  String t(String source) => strings.t(source);

  String tf(String source, [Map<String, Object?> args = const {}]) =>
      strings.tf(source, args);
}

String tr(String source) => BroomStrings.instance.t(source);

String trf(String source, [Map<String, Object?> args = const {}]) =>
    BroomStrings.instance.tf(source, args);
