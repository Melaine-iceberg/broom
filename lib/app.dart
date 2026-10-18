import 'package:flutter/material.dart';

import 'core/analysis/analysis_service.dart';
import 'core/shell/system_shell.dart';
import 'ui/clean_controller.dart';
import 'ui/home_page.dart';
import 'ui/system_cache_controller.dart';
import 'ui/window_title_bar.dart';

class BroomApp extends StatelessWidget {
  const BroomApp({
    super.key,
    required this.controller,
    this.systemShell,
    this.systemCacheController,
    this.analysisRunnerFactory,
    this.analysisInitialDirectory,
    this.analysisExcludedPaths = const [],
    this.startInSystemCache = false,
  });

  final CleanController controller;
  final SystemShell? systemShell;
  final SystemCacheController? systemCacheController;
  final AnalysisRunner Function()? analysisRunnerFactory;
  final String? analysisInitialDirectory;
  final List<String> analysisExcludedPaths;
  final bool startInSystemCache;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Broom',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildBroomTheme(Brightness.light),
      darkTheme: buildBroomTheme(Brightness.dark),
      builder: (context, child) =>
          BroomWindowFrame(child: child ?? const SizedBox.shrink()),
      home: HomePage(
        controller: controller,
        shell: systemShell ?? createSystemShell(),
        systemCacheController: systemCacheController,
        analysisRunnerFactory: analysisRunnerFactory ?? AnalysisService.new,
        analysisInitialDirectory: analysisInitialDirectory,
        analysisExcludedPaths: analysisExcludedPaths,
        startInSystemCache: startInSystemCache,
      ),
    );
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
      theme: buildBroomTheme(Brightness.light),
      darkTheme: buildBroomTheme(Brightness.dark),
      builder: (context, child) =>
          BroomWindowFrame(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cleaning_services_rounded, size: 56),
                const SizedBox(height: 20),
                Text(
                  'Broom 暂不支持 $platformName',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  reason,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
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
