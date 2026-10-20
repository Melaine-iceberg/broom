import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';

import 'core/analysis/analysis_service.dart';
import 'core/clean/quarantine_retention_service.dart';
import 'core/diagnostics/app_logger.dart';
import 'core/shell/system_shell.dart';
import 'l10n/broom_strings.dart';
import 'ui/broom_fonts.dart';
import 'ui/clean_controller.dart';
import 'ui/glass_ui.dart';
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

ThemeData buildBroomTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? const Color(0xFF0A84FF) : BroomColors.primary,
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF0A2B52) : const Color(0xFFDCEBFF),
    onPrimaryContainer: dark
        ? const Color(0xFFD3E4FF)
        : const Color(0xFF001B3D),
    secondary: dark ? const Color(0xFFB9B9C2) : const Color(0xFF5F5F6B),
    onSecondary: dark ? const Color(0xFF202127) : Colors.white,
    secondaryContainer: dark
        ? const Color(0xFF26272F)
        : const Color(0xFFECEDF3),
    onSecondaryContainer: dark
        ? const Color(0xFFE7E7EC)
        : const Color(0xFF2B2C33),
    tertiary: dark ? const Color(0xFFA5A1FF) : const Color(0xFF5E5CE6),
    onTertiary: dark ? const Color(0xFF1B1757) : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF322D83) : const Color(0xFFE5E3FF),
    onTertiaryContainer: dark
        ? const Color(0xFFE6E3FF)
        : const Color(0xFF1F1B60),
    error: dark ? const Color(0xFFFF453A) : BroomColors.danger,
    onError: dark ? const Color(0xFF2D0806) : Colors.white,
    errorContainer: dark ? const Color(0xFF4A1512) : const Color(0xFFFFE5E1),
    onErrorContainer: dark ? const Color(0xFFFFDAD4) : const Color(0xFF7A1710),
    surface: dark ? const Color(0xFF0B0C10) : const Color(0xFFF3F4F8),
    onSurface: dark ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E),
    onSurfaceVariant: dark ? const Color(0xFFA7A7B0) : const Color(0xFF6C6C70),
    surfaceContainerLowest: dark
        ? const Color(0xFF06070A)
        : const Color(0xFFFFFFFF),
    surfaceContainerLow: dark
        ? const Color(0xFF101116)
        : const Color(0xFFFAFAFD),
    surfaceContainer: dark ? const Color(0xFF17181F) : const Color(0xFFF0F1F6),
    surfaceContainerHigh: dark
        ? const Color(0xFF1E1F27)
        : const Color(0xFFE9EAF0),
    surfaceContainerHighest: dark
        ? const Color(0xFF26272F)
        : const Color(0xFFE1E3EA),
    outline: dark ? const Color(0xFF5B5C66) : const Color(0xFFC3C4CC),
    outlineVariant: dark ? const Color(0xFF2D2E37) : const Color(0xFFE3E4EA),
    inverseSurface: dark ? const Color(0xFFF2F2F7) : const Color(0xFF2C2C2E),
    onInverseSurface: dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
    inversePrimary: dark ? BroomColors.primary : const Color(0xFF0A84FF),
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: broomFontFamily,
    fontFamilyFallback: broomFontFallback,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );

  TextStyle display(
    double size,
    double height, {
    FontWeight weight = FontWeight.w700,
  }) {
    return TextStyle(
      fontFamily: broomFontFamily,
      fontFamilyFallback: broomFontFallback,
      fontSize: size,
      height: height / size,
      fontWeight: weight,
      letterSpacing: size * -0.02,
      color: scheme.onSurface,
    );
  }

  final textTheme = base.textTheme
      .copyWith(
        displayLarge: display(40, 44),
        displayMedium: display(34, 41),
        displaySmall: display(34, 41),
        headlineLarge: display(32, 38),
        headlineMedium: display(28, 34),
        headlineSmall: display(24, 30),
        titleLarge: TextStyle(
          fontSize: 20,
          height: 25 / 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.25,
          color: scheme.onSurface,
        ),
        titleMedium: TextStyle(
          fontSize: 17,
          height: 22 / 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.15,
          color: scheme.onSurface,
        ),
        titleSmall: TextStyle(
          fontSize: 15,
          height: 20 / 15,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        bodyLarge: TextStyle(
          fontSize: 17,
          height: 22 / 17,
          color: scheme.onSurface,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          height: 20 / 14,
          color: scheme.onSurface,
        ),
        bodySmall: TextStyle(
          fontSize: 13,
          height: 18 / 13,
          color: scheme.onSurface,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          height: 18 / 14,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        labelMedium: TextStyle(
          fontSize: 12,
          height: 16 / 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          color: scheme.onSurfaceVariant,
        ),
        labelSmall: TextStyle(
          fontSize: 11.5,
          height: 15 / 11.5,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
          color: scheme.onSurfaceVariant,
        ),
      )
      .apply(
        fontFamily: broomFontFamily,
        fontFamilyFallback: broomFontFallback,
      );

  const buttonText = TextStyle(
    fontFamily: broomFontFamily,
    fontFamilyFallback: broomFontFallback,
    fontSize: 14,
    height: 18 / 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );
  final cardRadius = BorderRadius.circular(26);
  final inputRadius = BorderRadius.circular(16);
  final inputFill = dark ? const Color(0xFF23242C) : const Color(0xFFF0F1F6);
  final hairline = dark ? const Color(0x1FFFFFFF) : const Color(0x14000000);

  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        shape: const StadiumBorder(),
        textStyle: buttonText,
        elevation: 0,
        iconSize: 18,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        shape: const StadiumBorder(),
        side: BorderSide(color: hairline),
        backgroundColor: dark
            ? const Color(0xFF1B1C23)
            : Colors.white.withValues(alpha: 0.6),
        foregroundColor: scheme.onSurface,
        textStyle: buttonText.copyWith(fontWeight: FontWeight.w500),
        elevation: 0,
        iconSize: 17,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: const StadiumBorder(),
        foregroundColor: scheme.primary,
        textStyle: buttonText.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(36, 36),
        iconSize: 20,
        shape: const CircleBorder(),
        foregroundColor: scheme.onSurfaceVariant,
        highlightColor: scheme.onSurface.withValues(alpha: 0.06),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 76,
      leadingWidth: 64,
      titleSpacing: 8,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
      titleTextStyle: textTheme.headlineSmall?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xFF17181F) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: cardRadius),
      margin: EdgeInsets.zero,
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(999),
      thumbVisibility: const WidgetStatePropertyAll(false),
      thumbColor: WidgetStatePropertyAll(
        dark ? const Color(0x33FFFFFF) : const Color(0x33000000),
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      crossAxisMargin: 3,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6.5)),
      side: BorderSide(
        color: dark ? const Color(0x45FFFFFF) : const Color(0x3D000000),
        width: 1.4,
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
        if (states.contains(WidgetState.selected)) return Colors.white;
        return dark ? const Color(0xFFB9B9C2) : Colors.white;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return dark ? const Color(0xFF34353E) : const Color(0xFFD9DAE2);
      }),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      labelStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      helperStyle: textTheme.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      border: OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF1B1C23) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: 0.32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.55,
      ),
      iconColor: scheme.primary,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      modalBackgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2C2D36) : const Color(0xFF2C2C2E),
      contentTextStyle: textTheme.bodySmall?.copyWith(color: Colors.white),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.all(18),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A3B44) : const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: textTheme.labelSmall?.copyWith(color: Colors.white),
      waitDuration: const Duration(milliseconds: 450),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF1E1F27) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          dark ? const Color(0xFF1E1F27) : Colors.white,
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: dark ? const Color(0xFF23242C) : const Color(0xFFF0F1F6),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: dark
          ? const Color(0xFF26272F)
          : const Color(0xFFE7E9F0),
      circularTrackColor: dark
          ? const Color(0xFF26272F)
          : const Color(0xFFE7E9F0),
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(999),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        textStyle: WidgetStatePropertyAll(
          buttonText.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.onSurfaceVariant;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return dark ? const Color(0xFF23242C) : const Color(0xFFF0F1F6);
        }),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: textTheme.titleSmall,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.45,
      ),
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
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
