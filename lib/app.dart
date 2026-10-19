import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';

import 'core/analysis/analysis_service.dart';
import 'core/clean/quarantine_retention_service.dart';
import 'core/diagnostics/app_logger.dart';
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
    this.logger,
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
  final AppLogger? logger;

  @override
  State<BroomApp> createState() => _BroomAppState();
}

class _BroomAppState extends State<BroomApp> {
  late final SettingsController _settings =
      widget.settingsController ?? SettingsController(logger: widget.logger);
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
          themeAnimationDuration: Duration.zero,
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
            logger: widget.logger,
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
      themeAnimationDuration: Duration.zero,
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

const _fontFamily = 'Segoe UI Variable Text';
const _fontFallback = <String>[
  'Segoe UI',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
  'Arial',
];

ThemeData buildBroomTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF2F7BFF),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF8CBDFF) : const Color(0xFF1F6FEB),
        onPrimary: dark ? const Color(0xFF04182E) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF1A3558)
            : const Color(0xFFD8E8FF),
        onPrimaryContainer: dark
            ? const Color(0xFFDCEBFF)
            : const Color(0xFF06264F),
        secondary: dark ? const Color(0xFFC3B5FF) : const Color(0xFF5B4BC4),
        onSecondary: dark ? const Color(0xFF1B123D) : Colors.white,
        secondaryContainer: dark
            ? const Color(0xFF2C2755)
            : const Color(0xFFE7E1FF),
        onSecondaryContainer: dark
            ? const Color(0xFFE8E0FF)
            : const Color(0xFF20164F),
        tertiary: dark ? const Color(0xFFF0C67D) : const Color(0xFF8A5A10),
        onTertiary: dark ? const Color(0xFF3A2A0A) : Colors.white,
        tertiaryContainer: dark
            ? const Color(0xFF463516)
            : const Color(0xFFFBEAC6),
        onTertiaryContainer: dark
            ? const Color(0xFFFFE5B5)
            : const Color(0xFF3C2A06),
        error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
        onError: dark ? const Color(0xFF690005) : Colors.white,
        errorContainer: dark
            ? const Color(0xFF5D1F1B)
            : const Color(0xFFF9DEDC),
        onErrorContainer: dark
            ? const Color(0xFFFFDAD6)
            : const Color(0xFF410E0B),
        surface: dark ? const Color(0xFF0D131A) : const Color(0xFFF7F9FC),
        onSurface: dark ? const Color(0xFFF1F5F9) : const Color(0xFF111820),
        onSurfaceVariant: dark
            ? const Color(0xFF9AA6B4)
            : const Color(0xFF5A6675),
        surfaceContainerLowest: dark
            ? const Color(0xFF090D12)
            : const Color(0xFFFFFFFF),
        surfaceContainerLow: dark
            ? const Color(0x14FFFFFF)
            : const Color(0xB8FFFFFF),
        surfaceContainer: dark
            ? const Color(0x1AFFFFFF)
            : const Color(0xCCFFFFFF),
        surfaceContainerHigh: dark
            ? const Color(0x24FFFFFF)
            : const Color(0xD9FFFFFF),
        surfaceContainerHighest: dark
            ? const Color(0x2EFFFFFF)
            : const Color(0xE6FFFFFF),
        outline: dark ? const Color(0xFF3B4653) : const Color(0xFFC5CED9),
        outlineVariant: dark
            ? const Color(0xFF26313C)
            : const Color(0xFFDCE3EB),
        inverseSurface: dark
            ? const Color(0xFFE7EDF3)
            : const Color(0xFF20262E),
        onInverseSurface: dark
            ? const Color(0xFF1A222B)
            : const Color(0xFFF3F6F9),
        inversePrimary: dark
            ? const Color(0xFF1F6FEB)
            : const Color(0xFF8CBDFF),
        shadow: Colors.black,
        scrim: Colors.black,
        surfaceTint: Colors.transparent,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  final textTheme = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 25,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.6,
      height: 1.2,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: 21,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.4,
      height: 1.2,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 13.5),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.45),
    bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.45),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: base.textTheme.labelMedium?.copyWith(
      fontSize: 11.8,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: base.textTheme.labelSmall?.copyWith(
      fontSize: 11.2,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
    ),
  );

  const buttonText = TextStyle(
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFallback,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
  );
  final fieldFill = dark ? const Color(0x0FFFFFFF) : const Color(0x09000000);
  final hairline = dark ? const Color(0x17FFFFFF) : const Color(0x0F0B1220);
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: hairline),
  );

  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: buttonText,
        elevation: 0,
        backgroundColor: dark
            ? const Color(0xFF2F7BFF)
            : const Color(0xFF1F6FEB),
        foregroundColor: Colors.white,
        disabledBackgroundColor: dark
            ? const Color(0x14FFFFFF)
            : const Color(0x0F000000),
        disabledForegroundColor: dark
            ? const Color(0x61FFFFFF)
            : const Color(0x61000000),
        iconColor: Colors.white,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(
          color: dark ? const Color(0x24FFFFFF) : const Color(0x1A0B1220),
        ),
        backgroundColor: dark
            ? const Color(0x0AFFFFFF)
            : const Color(0x66FFFFFF),
        textStyle: buttonText.copyWith(fontWeight: FontWeight.w500),
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: buttonText.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        iconSize: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        foregroundColor: scheme.onSurfaceVariant,
        highlightColor: scheme.primary.withValues(alpha: 0.1),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 64,
      leadingWidth: 52,
      titleSpacing: 0,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 19),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      shape: Border(bottom: BorderSide(color: hairline)),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbVisibility: const WidgetStatePropertyAll(false),
      thumbColor: WidgetStatePropertyAll(
        dark ? const Color(0x2EFFFFFF) : const Color(0x33000000),
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      crossAxisMargin: 2,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(
        color: dark ? const Color(0x3DFFFFFF) : const Color(0x33000000),
        width: 1.2,
      ),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(scheme.onPrimary),
      visualDensity: VisualDensity.compact,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.onPrimary;
        return dark ? const Color(0xFFB8C2CE) : Colors.white;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return dark ? const Color(0x2EFFFFFF) : const Color(0x1F000000);
      }),
      trackOutlineColor: WidgetStatePropertyAll(
        dark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fieldFill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      labelStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      helperStyle: textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.8)),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF141B24) : const Color(0xFFFCFDFE),
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.55,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF1D2733) : const Color(0xFF202933),
      contentTextStyle: textTheme.bodySmall?.copyWith(color: Colors.white),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      insetPadding: const EdgeInsets.all(16),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1F2833) : const Color(0xFF2A333D),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      textStyle: textTheme.labelSmall?.copyWith(color: Colors.white),
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF161E27) : const Color(0xFFFCFDFE),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: hairline),
      ),
      textStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurface),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          dark ? const Color(0xFF161E27) : const Color(0xFFFCFDFE),
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: dark ? const Color(0x0FFFFFFF) : const Color(0x99FFFFFF),
      side: BorderSide(
        color: dark ? const Color(0x1AFFFFFF) : const Color(0x140B1220),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: textTheme.labelSmall?.copyWith(color: scheme.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: dark
          ? const Color(0x17FFFFFF)
          : const Color(0x14000000),
      circularTrackColor: dark
          ? const Color(0x17FFFFFF)
          : const Color(0x14000000),
      linearMinHeight: 4,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
          textTheme.labelLarge?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return dark ? scheme.primary : scheme.onPrimaryContainer;
          }
          return scheme.onSurfaceVariant;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary.withValues(alpha: dark ? 0.16 : 0.13);
          }
          return Colors.transparent;
        }),
        side: WidgetStatePropertyAll(
          BorderSide(
            color: dark ? const Color(0x1FFFFFFF) : const Color(0x140B1220),
          ),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      minVerticalPadding: 8,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: textTheme.labelLarge,
      dividerColor: Colors.transparent,
    ),
  );
}
