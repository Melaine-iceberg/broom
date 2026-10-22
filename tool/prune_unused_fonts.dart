// Removes font families that a built bundle declares but the application never
// references.
//
// `lucide_icons_flutter` declares seven font families in its pubspec — one per
// variable-font weight — while the app only imports the default `Lucide` family.
// Flutter registers every family listed in FontManifest.json when the engine
// starts, so those six unused variants (~2.9 MB of TTF) are read and parsed on
// every cold start. Flutter's icon tree shaking does not help here: it only
// subsets families that referenced IconData actually uses.
//
// The tool refuses to drop a family that still appears anywhere under lib/, so a
// future switch to a weighted icon family can never silently produce blank
// glyphs.
//
// Usage:
//   dart tool/prune_unused_fonts.dart                 # prune the default bundle
//   dart tool/prune_unused_fonts.dart --check         # report, change nothing
//   dart tool/prune_unused_fonts.dart --bundle <dir>  # explicit flutter_assets
//
// `tool/package_windows.ps1` runs this after `flutter build windows --release`,
// which is what makes the saving reach the MSIX and the portable ZIP.
import 'dart:convert';
import 'dart:io';

/// Families to consider removing, with the identifiers that would prove the app
/// still uses them.
const _candidates = <_FontCandidate>[
  _FontCandidate(family: 'Lucide100', markers: ['Lucide100']),
  _FontCandidate(family: 'Lucide200', markers: ['Lucide200']),
  _FontCandidate(family: 'Lucide300', markers: ['Lucide300']),
  _FontCandidate(family: 'Lucide400', markers: ['Lucide400']),
  _FontCandidate(family: 'Lucide500', markers: ['Lucide500']),
  _FontCandidate(family: 'Lucide600', markers: ['Lucide600']),
];

class _FontCandidate {
  const _FontCandidate({required this.family, required this.markers});

  /// Suffix of the family name; the bundle prefixes it with the package path.
  final String family;

  /// Substrings that indicate the family is in use. `lucide_icons_100.dart`
  /// imports are covered by the numeric suffix match.
  final List<String> markers;
}

void main(List<String> args) {
  String? bundleArg;
  var checkOnly = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--check':
        checkOnly = true;
      case '--bundle':
        if (i + 1 >= args.length) _fail('--bundle requires a directory');
        bundleArg = args[++i];
      case '-h' || '--help':
        stdout.writeln(
          'Usage: dart tool/prune_unused_fonts.dart [--check] [--bundle <dir>]',
        );
        return;
      default:
        _fail('Unknown argument: ${args[i]}');
    }
  }

  final root = Directory.fromUri(Platform.script).parent.parent;
  final bundle = Directory(
    bundleArg ??
        '${root.path}${Platform.pathSeparator}build'
            '${Platform.pathSeparator}windows${Platform.pathSeparator}x64'
            '${Platform.pathSeparator}runner${Platform.pathSeparator}Release'
            '${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets',
  );
  final manifest = File(
    '${bundle.path}${Platform.pathSeparator}FontManifest.json',
  );
  if (!manifest.existsSync()) {
    _fail('FontManifest.json not found under ${bundle.path}');
  }

  final libSources = _readLibSources(Directory('${root.path}/lib'));
  final entries = (jsonDecode(manifest.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  final kept = <Map<String, dynamic>>[];
  final removed = <Map<String, dynamic>>[];
  final skipped = <String>[];
  for (final entry in entries) {
    final family = entry['family'];
    if (family is! String) {
      kept.add(entry);
      continue;
    }
    final candidate = _candidates
        .where((c) => family == c.family || family.endsWith('/${c.family}'))
        .firstOrNull;
    if (candidate == null) {
      kept.add(entry);
      continue;
    }
    if (libSources.any((source) => candidate.markers.any(source.contains))) {
      skipped.add(family);
      kept.add(entry);
      continue;
    }
    removed.add(entry);
  }

  if (skipped.isNotEmpty) {
    stdout.writeln('Kept (still referenced in lib/): ${skipped.join(', ')}');
  }
  if (removed.isEmpty) {
    stdout.writeln('Nothing to prune: no unused font families in the bundle.');
    return;
  }

  var freedBytes = 0;
  final removedFiles = <String>[];
  for (final entry in removed) {
    final fonts = entry['fonts'];
    if (fonts is! List) continue;
    for (final font in fonts) {
      final asset = font is Map ? font['asset'] : null;
      if (asset is! String) continue;
      final file = File('${bundle.path}${Platform.pathSeparator}$asset');
      if (!file.existsSync()) continue;
      freedBytes += file.lengthSync();
      removedFiles.add(asset);
      if (!checkOnly) file.deleteSync();
    }
  }

  if (!checkOnly) {
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent(null).convert(kept),
    );
  }

  final families = removed
      .map((entry) => entry['family'])
      .whereType<String>()
      .toList();
  final megabytes = (freedBytes / (1024 * 1024)).toStringAsFixed(1);
  stdout.writeln(
    '${checkOnly ? 'Would prune' : 'Pruned'} ${families.length} font '
    'famil${families.length == 1 ? 'y' : 'ies'} '
    '(${removedFiles.length} files, $megabytes MB): ${families.join(', ')}',
  );
}

/// Returns every dart source under [lib] as a single flat list of file contents.
List<String> _readLibSources(Directory lib) {
  if (!lib.existsSync()) return const [];
  return [
    for (final entity in lib.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        entity.readAsStringSync(),
  ];
}

Never _fail(String message) {
  stderr.writeln('prune_unused_fonts: $message');
  exit(64);
}
