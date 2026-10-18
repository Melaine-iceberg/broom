import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/cleaner_rule.dart';
import '../rules/windows_rules.dart';
import 'windows_rule_resolver.dart';

abstract interface class CleanerPlatform {
  bool get isSupported;
  String get displayName;
  String? get quarantineRoot;
  Map<String, String> get environment;
  List<CleanerRule> get rules;
  Future<List<String>> resolveRoots(CleanerRule rule);
}

class WindowsCleanerPlatform implements CleanerPlatform {
  WindowsCleanerPlatform({Map<String, String>? environment})
    : environment = environment ?? Platform.environment {
    _resolver = WindowsRuleResolver(environment: this.environment);
  }

  @override
  final Map<String, String> environment;
  late final WindowsRuleResolver _resolver;

  @override
  bool get isSupported => Platform.isWindows;

  @override
  String get displayName => 'Windows';

  @override
  List<CleanerRule> get rules => windowsCleanupRules;

  @override
  String? get quarantineRoot {
    final localAppData = _lookup('LOCALAPPDATA');
    if (localAppData != null) {
      return p.windows.join(localAppData, 'Broom', 'quarantine');
    }
    final userProfile = _lookup('USERPROFILE');
    if (userProfile != null) {
      return p.windows.join(
        userProfile,
        'AppData',
        'Local',
        'Broom',
        'quarantine',
      );
    }
    return null;
  }

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) =>
      _resolver.resolve(rule);

  String? _lookup(String name) {
    final value =
        environment[name] ??
        environment.entries
            .where((entry) => entry.key.toLowerCase() == name.toLowerCase())
            .map((entry) => entry.value)
            .firstOrNull;
    return value == null || value.isEmpty ? null : value;
  }
}

class UnsupportedCleanerPlatform implements CleanerPlatform {
  const UnsupportedCleanerPlatform();

  @override
  String get displayName => Platform.operatingSystem;

  @override
  Map<String, String> get environment => const {};

  @override
  bool get isSupported => false;

  @override
  String? get quarantineRoot => null;

  @override
  List<CleanerRule> get rules => const [];

  @override
  Future<List<String>> resolveRoots(CleanerRule rule) async => const [];
}

CleanerPlatform createCleanerPlatform() {
  if (Platform.isWindows) return WindowsCleanerPlatform();
  return const UnsupportedCleanerPlatform();
}
