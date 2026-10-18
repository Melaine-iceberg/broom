import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';

import 'core/analysis/analysis_service.dart';
import 'core/clean/quarantine_retention_service.dart';
import 'core/shell/system_shell.dart';
import 'l10n/broom_strings.dart';
import 'ui/clean_controller.dart';
import 'ui/home_page.dart';
import 'ui/rule_update_controller.dart';
import 'ui/settings_controller.dart';
import 'ui/system_cache_controller.dart';
import 'ui/window_title_bar.dart';

class BroomApp extends StatefulWidget {
  const BroomApp({
    super.key,
    required this.controller,
    this.settingsController,
    this.systemShell,
    this.systemCacheController,
    this.quarantineRetention,
    this.analysisRunnerFactory,
    this.analysisInitialDirectory,
    this.analysisExcludedPaths = const [],
    this.startInSystemCache = false,
    this.ruleUpdates,
  });

  final CleanController controller;
  final SettingsController? settingsController;
  final SystemShell? systemShell;
  final SystemCacheController? systemCacheController;
  final QuarantineRetentionService? quarantineRetention;
  final AnalysisRunner Function()? analysisRunnerFactory;
  final String? analysisInitialDirectory;
  final List<String> analysisExcludedPaths;
  final bool startInSystemCache;
  final RuleUpdateController? ruleUpdates;

  @override
  State<BroomApp> createState() => _BroomAppState();
}

class _BroomAppState extends State<BroomApp> {
  late final SettingsController _settings =
      widget.settingsController ?? SettingsController();
  late final bool _ownsSettings = widget.settingsController == null;

  @override
  void initState() {
    super.initState();
    if (_ownsSettings) _settings.load();
    widget.controller.isRuleEnabled = _settings.isRuleEnabled;
    widget.controller.scanSettings = () => _settings.scanSettings;
  }

  @override
  void dispose() {
    if (_ownsSettings) _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'Broom',
          debugShowCheckedModeBanner: false,
          themeMode: _settings.themeMode,
          locale: _settings.locale,
          supportedLocales: BroomStrings.supportedLocales,
          localizationsDelegates: const [
            BroomStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          localeListResolutionCallback: _resolveLocale,
          theme: buildBroomTheme(Brightness.light),
          darkTheme: buildBroomTheme(Brightness.dark),
          builder: (context, child) {
            final strings = BroomStrings.of(context);
            BroomStrings.instance = strings;
            Intl.defaultLocale = strings.localeName;
            return BroomWindowFrame(child: child ?? const SizedBox.shrink());
          },
          home: HomePage(
            controller: widget.controller,
            settingsController: _settings,
            shell: widget.systemShell ?? createSystemShell(),
            systemCacheController: widget.systemCacheController,
            quarantineRetention: widget.quarantineRetention,
            analysisRunnerFactory:
                widget.analysisRunnerFactory ?? AnalysisService.new,
            analysisInitialDirectory: widget.analysisInitialDirectory,
            analysisExcludedPaths: widget.analysisExcludedPaths,
            startInSystemCache: widget.startInSystemCache,
            ruleUpdates: widget.ruleUpdates,
          ),
        );
      },
    );
  }

  static Locale _resolveLocale(
    List<Locale>? locales,
    Iterable<Locale> supported,
  ) {
    for (final locale in locales ?? const <Locale>[]) {
      if (locale.languageCode == 'en') return const Locale('en');
      if (locale.languageCode == 'zh') return const Locale('zh');
    }
    return const Locale('zh');
  }
}

class UnsupportedApp extends StatelessWidget {
  const UnsupportedApp({
    super.key,
    required this.platformName,
    this.reason = '当前版本仅支持 Windows 桌面端。',
  });

  final String platformName;
  final String reason;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Broom',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      supportedLocales: BroomStrings.supportedLocales,
      localizationsDelegates: const [
        BroomStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildBroomTheme(Brightness.light),
      darkTheme: buildBroomTheme(Brightness.dark),
      builder: (context, child) =>
          BroomWindowFrame(child: child ?? const SizedBox.shrink()),
      home: _UnsupportedView(platformName: platformName, reason: reason),
    );
  }
}

class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView({required this.platformName, required this.reason});

  final String platformName;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final strings = BroomStrings.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cleaning_services_rounded, size: 56),
              const SizedBox(height: 20),
              Text(
                strings.tf('Broom 暂不支持 {platform}', {'platform': platformName}),
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                strings.t(reason),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _fontFamily = 'Microsoft YaHei UI';
const _fontFallback = <String>['Microsoft YaHei', 'Segoe UI', 'Arial'];

ThemeData buildBroomTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2E7D62),
    brightness: brightness,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        height: 1.15,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFallback,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFallback,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFallback,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.55),
      thickness: 1,
      space: 1,
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(8),
      radius: Radius.circular(4),
    ),
  );
}
