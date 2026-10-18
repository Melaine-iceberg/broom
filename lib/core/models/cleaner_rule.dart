enum CleanRisk { safe, review, info }

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
    this.note,
  });

  final String id;
  final String title;
  final String category;
  final String description;
  final CleanRisk risk;
  final List<String> pathPatterns;
  final Duration minAge;
  final Set<String>? extensions;
  final String? note;
}
