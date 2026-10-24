import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/analysis/analysis_service.dart';
import '../core/clean/quarantine_retention_service.dart';
import '../core/diagnostics/app_logger.dart';
import '../core/models/clean_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/scan_models.dart';
import '../core/rules/leftover_catalog.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'app_sidebar.dart';
import 'app_update_controller.dart';
import 'clean_controller.dart';
import 'clean_dashboard.dart';
import 'clean_history_page.dart';
import 'duplicate_finder_page.dart';
import 'exclusions_page.dart';
import 'format.dart';
import 'glass_ui.dart';
import 'large_files_page.dart';
import 'linux_system_cache_controller.dart';
import 'linux_system_cache_page.dart';
import 'onboarding_dialog.dart';
import 'quarantine_page.dart';
import 'recycle_bin_page.dart';
import 'rule_detail_page.dart';
import 'rule_update_controller.dart';
import 'settings_controller.dart';
import 'settings_page.dart';
import 'system_cache_controller.dart';
import 'system_cache_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.settingsController,
    required this.shell,
    required this.analysisRunnerFactory,
    this.systemCacheController,
    this.linuxSystemCacheController,
    this.quarantineRetention,
    this.analysisInitialDirectory,
    this.analysisExcludedPaths = const [],
    this.startInSystemCache = false,
    this.ruleUpdates,
    this.appUpdates,
    this.logger,
    this.showWindowsTools = true,
    this.showSystemCache = true,
    this.showRecycleBin = true,
  });

  final CleanController controller;
  final SettingsController settingsController;
  final SystemShell shell;
  final SystemCacheController? systemCacheController;
  final LinuxSystemCacheController? linuxSystemCacheController;
  final QuarantineRetentionService? quarantineRetention;
  final AnalysisRunner Function() analysisRunnerFactory;
  final String? analysisInitialDirectory;
  final List<String> analysisExcludedPaths;
  final bool startInSystemCache;
  final RuleUpdateController? ruleUpdates;
  final AppUpdateController? appUpdates;
  final AppLogger? logger;

  /// Hides features that only exist on Windows (recycle bin, app/rule updates
  /// and NTFS indexing).
  final bool showWindowsTools;

  /// The system-cache entry is platform-independent: Windows uses the UAC
  /// per-file tool and Linux uses the Polkit helper. Each controller is only
  /// created when its prerequisites exist.
  final bool showSystemCache;

  final bool showRecycleBin;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CleanController get controller => widget.controller;

  final GlobalKey<NavigatorState> _contentNavigator =
      GlobalKey<NavigatorState>();
  AppSection _section = AppSection.clean;

  bool _startupPromptScheduled = false;
  bool _onboardingScheduled = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_maybeScheduleUnfinishedPrompt);
    widget.settingsController.addListener(_maybeScheduleOnboarding);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeScheduleOnboarding();
      _maybeScheduleUnfinishedPrompt();
    });
    if (widget.startInSystemCache &&
        (widget.systemCacheController != null ||
            widget.linuxSystemCacheController != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openSystemCache();
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(_maybeScheduleUnfinishedPrompt);
    widget.settingsController.removeListener(_maybeScheduleOnboarding);
    super.dispose();
  }

  void _maybeScheduleOnboarding() {
    if (!mounted || _onboardingScheduled) return;
    if (widget.startInSystemCache) return;
    if (!widget.settingsController.loaded) return;
    if (widget.settingsController.onboardingCompleted) return;
    _onboardingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showOnboarding());
    });
  }

  Future<void> _showOnboarding() async {
    await showOnboardingDialog(context);
    if (!mounted) return;
    final error = await widget.settingsController.completeOnboarding();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tf('无法保存引导状态：{error}', {'error': error})),
        ),
      );
    }
    _maybeScheduleUnfinishedPrompt();
  }

  void _handleRefreshShortcut() {
    if (_section != AppSection.clean || controller.isBusy) return;
    if (controller.phase == CleanPhase.idle ||
        controller.phase == CleanPhase.preview) {
      unawaited(controller.scan());
    }
  }

  void _handleEscapeShortcut() {
    if (_section != AppSection.clean) return;
    switch (controller.phase) {
      case CleanPhase.scanning:
        controller.cancelScan();
        break;
      case CleanPhase.cleaning:
        controller.cancelCleaning();
        break;
      case CleanPhase.done:
        controller.returnHome();
        break;
      case CleanPhase.idle:
      case CleanPhase.preview:
        break;
    }
  }

  void _handleBackShortcut() {
    if (_section != AppSection.clean) return;
    if (controller.phase == CleanPhase.preview ||
        controller.phase == CleanPhase.done) {
      controller.returnHome();
    }
  }

  void _maybeScheduleUnfinishedPrompt() {
    if (!mounted || _startupPromptScheduled) return;
    if (!controller.initialized || widget.startInSystemCache) return;
    if (widget.settingsController.loaded &&
        !widget.settingsController.onboardingCompleted) {
      return;
    }
    if (controller.unfinishedSessions.isEmpty) return;
    _startupPromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showUnfinishedPrompt());
    });
  }

  Future<void> _showUnfinishedPrompt() async {
    final count = controller.unfinishedSessions.length;
    if (count == 0 || !mounted) return;
    final strings = context.strings;
    final openQuarantine = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          LucideIcons.undo2,
          size: 30,
          color: Theme.of(dialogContext).colorScheme.primary,
        ),
        title: Text(strings.tf('发现 {count} 个未完成的清理会话', {'count': count})),
        content: Text(
          strings.t(
            'Broom 上次退出时还有清理没有正常结束，或恢复只完成了一部分。'
            '已移动的文件仍保存在隔离区，可以继续恢复；中断的清理也可以继续。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.t('稍后处理')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.t('查看隔离区')),
          ),
        ],
      ),
    );
    if (openQuarantine == true && mounted) {
      await _openQuarantine();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): _handleRefreshShortcut,
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscapeShortcut,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            _handleBackShortcut,
      },
      child: Focus(
        autofocus: true,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final expandedSidebar = constraints.maxWidth >= 980;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => AppSidebar(
                          section: _section,
                          expanded: expandedSidebar,
                          quarantineCount: controller.pendingSessions.length,
                          showHistory:
                              controller.quarantine.historyStore != null,
                          showSystemCache: widget.showSystemCache,
                          showRecycleBin: widget.showRecycleBin,
                          onSelected: _navigateTo,
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: BroomColors.page(context),
                          child: Navigator(
                            key: _contentNavigator,
                            onGenerateInitialRoutes:
                                (navigator, initialRoute) => [
                                  MaterialPageRoute<void>(
                                    settings: const RouteSettings(name: 'home'),
                                    builder: (_) => _buildCleanHost(),
                                  ),
                                ],
                            onGenerateRoute: (settings) =>
                                MaterialPageRoute<void>(
                                  settings: settings,
                                  builder: (_) => _buildCleanHost(),
                                ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCleanHost() {
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Expanded(child: _buildBody(context))],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (controller.phase) {
      case CleanPhase.idle:
        return _IdleView(
          controller: controller,
          onOpenQuarantine: _openQuarantine,
          onOpenSystemCache:
              widget.systemCacheController == null &&
                  widget.linuxSystemCacheController == null
              ? null
              : _openSystemCache,
          onOpenRecycleBin: widget.showRecycleBin ? _openRecycleBin : null,
          onOpenDuplicateFinder: _openDuplicateFinder,
          onOpenLargeFiles: _openLargeFiles,
          onOpenExclusions: _openExclusions,
          isRuleEnabled: widget.settingsController.isRuleEnabled,
          settingsController: widget.settingsController,
        );
      case CleanPhase.scanning:
        return _ScanningView(controller: controller);
      case CleanPhase.preview:
        return _PreviewView(
          controller: controller,
          shell: widget.shell,
          onCleanRequested: () => _requestClean(context),
        );
      case CleanPhase.cleaning:
        return _CleaningView(controller: controller);
      case CleanPhase.done:
        return _DoneView(
          controller: controller,
          onUndo: (sessionId) => _undo(context, sessionId),
          onOpenQuarantine: _openQuarantine,
        );
    }
  }

  Future<void> _requestClean(BuildContext context) async {
    final count = controller.selectedCount;
    if (count == 0) return;
    final bytes = controller.selectedBytes;
    final reviewCount = controller.selectedReviewRuleCount;
    final strings = context.strings;
    var reviewAcknowledged = reviewCount == 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            icon: const Icon(LucideIcons.archive, size: 30),
            title: Text(strings.t('移入隔离区？')),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.tf(
                      '将暂存 {count} 个文件，共 {bytes}。\n\n'
                      '文件会先移动到 Broom 的隔离区，磁盘空间不会立即释放。'
                      '你可以随时恢复，或在隔离区中永久释放。',
                      {'count': count, 'bytes': formatBytes(bytes)},
                    ),
                  ),
                  if (reviewCount > 0) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiaryContainer
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        strings.tf(
                          '所选内容包含 {count} 条需确认规则。它们默认不会勾选，'
                          '清理后仍会进入隔离区并可撤销；但离线数据需要重新下载，'
                          '首次构建或启动也可能变慢。',
                          {'count': reviewCount},
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onTertiaryContainer,
                          height: 1.5,
                        ),
                      ),
                    ),
                    CheckboxListTile(
                      key: const ValueKey('acknowledge-review-clean'),
                      value: reviewAcknowledged,
                      onChanged: (value) =>
                          setState(() => reviewAcknowledged = value ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: Text(
                        strings.t('我了解需确认规则的影响，并仍要清理所选内容'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(strings.t('取消')),
              ),
              FilledButton(
                onPressed: reviewAcknowledged
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: Text(strings.tf('暂存 {count} 项', {'count': count})),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true && mounted) {
      await controller.cleanSelected();
    }
  }

  Future<void> _undo(BuildContext context, String sessionId) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BusyDialog(message: context.t('正在恢复文件…')),
    );

    UndoReport? result;
    Object? failure;
    try {
      result = await controller.undo(sessionId);
    } catch (error) {
      failure = error;
    }
    if (!context.mounted) return;
    navigator.pop();

    if (failure != null) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(LucideIcons.circleAlert, size: 30),
          title: Text(context.t('撤销失败')),
          content: Text('$failure'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.t('知道了')),
            ),
          ],
        ),
      );
      return;
    }

    final report = result;
    if (report == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _UndoResultDialog(report: report),
    );
  }

  Future<void> _navigateTo(AppSection target) async {
    if (target == AppSection.clean) {
      final navigator = _contentNavigator.currentState;
      final hadToolPage = navigator?.canPop() ?? false;
      if (_section != AppSection.clean) {
        setState(() => _section = AppSection.clean);
      }
      navigator?.popUntil((route) => route.isFirst);
      if (!hadToolPage &&
          (controller.phase == CleanPhase.preview ||
              controller.phase == CleanPhase.done)) {
        controller.returnHome();
      }
      return;
    }
    if (_section == target) return;

    final page = _buildSectionPage(target);
    final navigator = _contentNavigator.currentState;
    if (page == null || navigator == null) return;

    setState(() => _section = target);
    await navigator.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => page),
      (route) => route.isFirst,
    );
    if (!mounted || _section != target) return;

    setState(() => _section = AppSection.clean);
    switch (target) {
      case AppSection.quarantine:
        await controller.refreshQuarantine();
      case AppSection.settings:
        await controller.refreshRuleExclusionScopes();
      case AppSection.clean:
      case AppSection.systemCache:
      case AppSection.recycleBin:
      case AppSection.duplicates:
      case AppSection.largeFiles:
      case AppSection.history:
        break;
    }
  }

  Map<String, String> _ruleTitles(BuildContext context) {
    return {
      for (final rule in controller.rules)
        rule.id: context.strings.ruleTitle(rule),
      for (final entry in LeftoverCatalog.entries)
        entry.ruleId: context.strings.leftoverRuleTitle(
          entry.appName,
          entry.appNameEn,
        ),
    };
  }

  Widget? _buildSectionPage(AppSection target) {
    switch (target) {
      case AppSection.clean:
        return null;
      case AppSection.systemCache:
        final linuxController = widget.linuxSystemCacheController;
        if (linuxController != null) {
          return LinuxSystemCachePage(controller: linuxController);
        }
        final cacheController = widget.systemCacheController;
        if (cacheController == null) return null;
        return SystemCachePage(controller: cacheController);
      case AppSection.recycleBin:
        if (!widget.showRecycleBin) return null;
        return RecycleBinPage(shell: widget.shell);
      case AppSection.duplicates:
        return DuplicateFinderPage(
          shell: widget.shell,
          runnerFactory: widget.analysisRunnerFactory,
          initialDirectory: widget.analysisInitialDirectory,
          excludedPaths: widget.analysisExcludedPaths,
        );
      case AppSection.largeFiles:
        return LargeFilesPage(
          shell: widget.shell,
          runnerFactory: widget.analysisRunnerFactory,
          initialDirectory: widget.analysisInitialDirectory,
          excludedPaths: widget.analysisExcludedPaths,
        );
      case AppSection.quarantine:
        return QuarantinePage(
          service: controller.quarantine,
          shell: widget.shell,
          retention: widget.quarantineRetention,
          ruleTitles: _ruleTitles(context),
        );
      case AppSection.history:
        final store = controller.quarantine.historyStore;
        if (store == null) return null;
        return CleanHistoryPage(store: store, ruleTitles: _ruleTitles(context));
      case AppSection.settings:
        return SettingsPage(
          settings: widget.settingsController,
          cleanController: controller,
          shell: widget.shell,
          retention: widget.quarantineRetention,
          ruleUpdates: widget.ruleUpdates,
          appUpdates: widget.appUpdates,
          onShowOnboarding: _showOnboarding,
          logger: widget.logger,
          showWindowsOptions: widget.showWindowsTools,
        );
    }
  }

  Future<void> _openQuarantine() => _navigateTo(AppSection.quarantine);

  Future<void> _openSystemCache() => _navigateTo(AppSection.systemCache);

  Future<void> _openRecycleBin() => _navigateTo(AppSection.recycleBin);

  Future<void> _openDuplicateFinder() => _navigateTo(AppSection.duplicates);

  Future<void> _openLargeFiles() => _navigateTo(AppSection.largeFiles);

  Future<void> _openExclusions() {
    return _contentNavigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExclusionsPage(controller: controller, shell: widget.shell),
      ),
    );
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView({
    required this.controller,
    required this.onOpenQuarantine,
    required this.onOpenRecycleBin,
    required this.onOpenDuplicateFinder,
    required this.onOpenLargeFiles,
    required this.onOpenExclusions,
    required this.isRuleEnabled,
    required this.settingsController,
    this.onOpenSystemCache,
  });

  final CleanController controller;
  final VoidCallback onOpenQuarantine;
  final VoidCallback? onOpenRecycleBin;
  final VoidCallback onOpenDuplicateFinder;
  final VoidCallback onOpenLargeFiles;
  final VoidCallback onOpenExclusions;
  final bool Function(String ruleId) isRuleEnabled;
  final SettingsController settingsController;
  final VoidCallback? onOpenSystemCache;

  @override
  Widget build(BuildContext context) {
    return CleanDashboard(
      controller: controller,
      settingsController: settingsController,
      onOpenQuarantine: onOpenQuarantine,
      onOpenRecycleBin: onOpenRecycleBin,
      onOpenDuplicateFinder: onOpenDuplicateFinder,
      onOpenLargeFiles: onOpenLargeFiles,
      onOpenSystemCache: onOpenSystemCache,
      scopeSection: ListenableBuilder(
        listenable: settingsController,
        builder: (context, _) => _ScopeSection(
          categories: controller.scanCategories,
          scopes: controller.ruleExclusionScopes,
          exclusionCount: controller.exclusionCount,
          onOpenExclusions: onOpenExclusions,
          isRuleEnabled: isRuleEnabled,
          settings: settingsController,
          onCategoryChanged: controller.refreshLeftoverRules,
        ),
      ),
    );
  }
}

class _ScopeSection extends StatefulWidget {
  const _ScopeSection({
    required this.categories,
    required this.scopes,
    required this.exclusionCount,
    required this.onOpenExclusions,
    required this.isRuleEnabled,
    required this.settings,
    required this.onCategoryChanged,
  });

  final List<RuleCategoryGroup> categories;
  final Map<String, RuleExclusionScope> scopes;
  final int exclusionCount;
  final VoidCallback onOpenExclusions;
  final bool Function(String ruleId) isRuleEnabled;
  final SettingsController settings;

  /// Re-runs runtime detection when a category that owns no catalog rules
  /// (the leftover category) is toggled.
  final Future<void> Function() onCategoryChanged;

  @override
  State<_ScopeSection> createState() => _ScopeSectionState();
}

class _ScopeSectionState extends State<_ScopeSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final categories = widget.categories;
    final exclusionCount = widget.exclusionCount;
    final ruleCount = categories.fold<int>(
      0,
      (total, category) => total + category.ruleCount,
    );
    final enabledCategories = categories
        .where((category) => widget.settings.isCategoryEnabled(category.key))
        .length;

    return GlassCard(
      radius: 26,
      padding: EdgeInsets.fromLTRB(20, 17, 18, _expanded ? 14 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.slidersHorizontal,
                size: 18,
                color: BroomColors.inkMuted(context),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  context.t('扫描范围'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('open-exclusions'),
                onPressed: widget.onOpenExclusions,
                icon: const Icon(LucideIcons.ban, size: 14),
                label: Text(
                  exclusionCount == 0
                      ? context.t('排除列表')
                      : '${context.t('排除列表')} · $exclusionCount',
                ),
              ),
              const SizedBox(width: 2),
              TextButton.icon(
                key: const ValueKey('scope-toggle'),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: const Icon(LucideIcons.chevronDown, size: 17),
                ),
                label: Text(_expanded ? context.t('收起') : context.t('展开')),
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 10),
            for (final (index, category) in categories.indexed) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  indent: 34,
                  color: BroomColors.hairline(context),
                ),
              _buildCategoryRow(context, theme, scheme, strings, category),
            ],
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 27),
              child: Text(
                exclusionCount > 0
                    ? context.tf(
                        '已启用 {enabled}/{total} 个类别 · {rules} 条规则 · {exclusions} 个目录已排除',
                        {
                          'enabled': enabledCategories,
                          'total': categories.length,
                          'rules': ruleCount,
                          'exclusions': exclusionCount,
                        },
                      )
                    : context.tf('已启用 {enabled}/{total} 个类别 · {rules} 条规则', {
                        'enabled': enabledCategories,
                        'total': categories.length,
                        'rules': ruleCount,
                      }),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: BroomColors.inkMuted(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCategoryRow(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    BroomStrings strings,
    RuleCategoryGroup category,
  ) {
    final categoryKey = category.key;
    final enabled = widget.settings.isCategoryEnabled(categoryKey);
    final categoryLabel = strings.ruleCategoryGroupLabel(category);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 172,
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  height: 30,
                  child: Checkbox(
                    key: ValueKey('scan-category-$categoryKey'),
                    value: enabled,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (value) async {
                      final next = value ?? false;
                      await widget.settings.setCategoryEnabled(
                        categoryKey,
                        next,
                      );
                      // Runtime categories have no catalog rules to resolve,
                      // so detection has to re-run on every toggle.
                      if (category.isLeftover) {
                        await widget.onCategoryChanged();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  _categoryIcon(categoryLabel),
                  size: 15,
                  color: enabled
                      ? BroomColors.inkMuted(context)
                      : BroomColors.inkFaint(context),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        categoryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontSize: 12.5,
                          color: enabled
                              ? BroomColors.ink(context)
                              : BroomColors.inkFaint(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _categorySubtitle(strings, category, enabled),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: BroomColors.inkFaint(context),
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final rule in category.rules)
                    Tooltip(
                      message: _scopeTooltip(
                        strings,
                        rule,
                        widget.scopes[rule.id],
                        widget.isRuleEnabled(rule.id),
                      ),
                      child: _RuleChip(
                        rule: rule,
                        scope:
                            widget.scopes[rule.id] ?? RuleExclusionScope.none,
                        enabled: widget.isRuleEnabled(rule.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _categorySubtitle(
    BroomStrings strings,
    RuleCategoryGroup category,
    bool enabled,
  ) {
    if (!enabled) return strings.t('本次跳过');
    if (category.isLeftover) {
      return category.isEmpty
          ? strings.t('未检测到残留应用')
          : strings.tf('{count} 个残留应用', {'count': category.ruleCount});
    }
    return strings.tf('{count} 条规则', {'count': category.ruleCount});
  }

  String _scopeTooltip(
    BroomStrings strings,
    CleanerRule rule,
    RuleExclusionScope? scope,
    bool enabled,
  ) {
    final description = switch (scope) {
      RuleExclusionScope.all => strings.tf('{description}\n此规则的所有目录都在排除列表中。', {
        'description': strings.ruleDescription(rule),
      }),
      RuleExclusionScope.partial => strings.tf('{description}\n此规则的部分目录已被排除。', {
        'description': strings.ruleDescription(rule),
      }),
      _ => strings.ruleDescription(rule),
    };
    final withRisk = rule.risk == CleanRisk.review
        ? '$description\n${strings.t('需确认规则默认不勾选，需要在预览中手动选择。')}'
        : description;
    if (enabled) return withRisk;
    return '$withRisk\n${strings.t('此规则已在设置中关闭。')}';
  }
}

class _RuleChip extends StatelessWidget {
  const _RuleChip({
    required this.rule,
    required this.scope,
    required this.enabled,
  });

  final CleanerRule rule;
  final RuleExclusionScope scope;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final excluded = scope != RuleExclusionScope.none;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5.5),
      decoration: BoxDecoration(
        color: excluded
            ? BroomColors.warning.withValues(alpha: 0.12)
            : BroomColors.block(context),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _ruleIcon(rule.id),
            size: 11.5,
            color: excluded ? BroomColors.amber : BroomColors.inkMuted(context),
          ),
          const SizedBox(width: 5),
          Text(
            context.strings.ruleTitle(rule),
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              color: enabled
                  ? BroomColors.ink(context)
                  : BroomColors.inkFaint(context),
            ),
          ),
          if (rule.risk == CleanRisk.review) ...[
            const SizedBox(width: 5),
            Icon(
              LucideIcons.shield,
              size: 10,
              color: BroomColors.amber.withValues(alpha: 0.9),
            ),
          ],
          if (excluded) ...[
            const SizedBox(width: 5),
            Text(
              scope == RuleExclusionScope.all
                  ? context.t('已排除')
                  : context.t('部分排除'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.amber,
                fontWeight: FontWeight.w600,
                fontSize: 9.6,
              ),
            ),
          ],
          if (!enabled) ...[
            const SizedBox(width: 5),
            Text(
              context.t('已关闭'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.inkFaint(context),
                fontSize: 9.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    required this.message,
    this.isError = false,
    this.icon,
    this.onClose,
    this.action,
  });

  final String message;
  final bool isError;
  final IconData? icon;
  final VoidCallback? onClose;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = isError ? scheme.error : BroomColors.inkMuted(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: isError
            ? scheme.errorContainer.withValues(alpha: 0.55)
            : BroomColors.card(context),
        borderRadius: BorderRadius.circular(16),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: Row(
        children: [
          Icon(
            isError ? LucideIcons.circleAlert : (icon ?? LucideIcons.info),
            size: 15,
            color: foreground,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.labelSmall?.copyWith(
                color: foreground,
                height: 1.45,
              ),
            ),
          ),
          ?action,
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(LucideIcons.x, size: 15),
              tooltip: context.t('关闭'),
            ),
        ],
      ),
    );
  }
}

class _ScanningView extends StatelessWidget {
  const _ScanningView({required this.controller});

  final CleanController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = controller.scanProgress;
    final ruleId = progress?.ruleId;
    final scanningRule = ruleId == null
        ? null
        : controller.platform.rules
              .where((rule) => rule.id == ruleId)
              .firstOrNull;
    final scanningTitle = scanningRule == null
        ? null
        : context.strings.ruleTitle(scanningRule);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: _SurfaceCard(
            padding: const EdgeInsets.fromLTRB(32, 34, 32, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SizedBox(
                    width: 82,
                    height: 82,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        RepaintBoundary(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: controller.scanCompletion),
                            duration: const Duration(milliseconds: 320),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) => SizedBox.expand(
                              child: CircularProgressIndicator(
                                value: value,
                                strokeWidth: 4,
                                strokeCap: StrokeCap.round,
                                backgroundColor: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ),
                        ),
                        Icon(
                          LucideIcons.scanSearch,
                          size: 28,
                          color: scheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  context.t('正在扫描'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  scanningTitle ?? context.t('正在准备扫描目录…'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (progress != null && progress.jobCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    progress.workerCount > 1
                        ? context.tf(
                            '第 {current} / {total} 组 · {workers} 个并行线程',
                            {
                              'current': progress.jobIndex + 1,
                              'total': progress.jobCount,
                              'workers': progress.workerCount,
                            },
                          )
                        : context.tf('第 {current} / {total} 组', {
                            'current': progress.jobIndex + 1,
                            'total': progress.jobCount,
                          }),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Semantics(
                  label: context.t('扫描进度'),
                  value: progress != null && progress.jobCount > 0
                      ? context.tf('第 {current} / {total} 组', {
                          'current': progress.jobIndex + 1,
                          'total': progress.jobCount,
                        })
                      : null,
                  child: RepaintBoundary(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: controller.scanCompletion),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: value,
                          minHeight: 7,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: _ProgressStat(
                        label: context.t('已检查'),
                        value: formatCount(progress?.scannedFiles ?? 0),
                      ),
                    ),
                    _statDivider(scheme),
                    Expanded(
                      child: _ProgressStat(
                        label: context.t('发现文件'),
                        value: formatCount(
                          controller.liveFoundCount > 0
                              ? controller.liveFoundCount
                              : (progress?.foundFiles ?? 0),
                        ),
                      ),
                    ),
                    _statDivider(scheme),
                    Expanded(
                      child: _ProgressStat(
                        label: context.t('已找到'),
                        value: formatBytes(
                          controller.liveFoundCount > 0
                              ? controller.liveFoundBytes
                              : (progress?.foundBytes ?? 0),
                        ),
                      ),
                    ),
                  ],
                ),
                if (controller.liveRuleCounts.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final entry
                          in controller.liveRuleCounts.entries.take(6))
                        Builder(
                          builder: (context) {
                            final rule = controller.platform.rules
                                .where((rule) => rule.id == entry.key)
                                .firstOrNull;
                            if (rule == null) return const SizedBox.shrink();
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                '${context.strings.ruleTitle(rule)} · '
                                '${formatCount(entry.value)}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ],
                if (controller.recentScanItems.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.35,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.t('流式结果 · 已聚合的结果会立即计入统计'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final item in controller.recentScanItems.take(4))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Icon(
                                  LucideIcons.file,
                                  size: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    fileNameOf(item.path),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  formatBytes(item.size),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if ((progress?.errorCount ?? 0) > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    context.tf('已有 {count} 个路径问题，扫描结束后可查看明细。', {
                      'count': formatCount(progress!.errorCount),
                    }),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.tertiary,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Center(
                  child: Tooltip(
                    message: context.t('取消扫描（Esc）'),
                    child: TextButton(
                      onPressed: controller.cancelScan,
                      child: Text(context.t('取消扫描')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statDivider(ColorScheme scheme) {
    return Container(
      width: 1,
      height: 30,
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}

class _ProgressStat extends StatelessWidget {
  const _ProgressStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

enum _RuleSort { original, sizeDesc, sizeAsc, name }

class _PreviewView extends StatefulWidget {
  const _PreviewView({
    required this.controller,
    required this.onCleanRequested,
    required this.shell,
  });

  final CleanController controller;
  final VoidCallback onCleanRequested;
  final SystemShell shell;

  @override
  State<_PreviewView> createState() => _PreviewViewState();
}

class _PreviewViewState extends State<_PreviewView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  _RuleSort _sort = _RuleSort.original;

  CleanController get controller => widget.controller;
  VoidCallback get onCleanRequested => widget.onCleanRequested;
  SystemShell get shell => widget.shell;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  String _sortLabel(BuildContext context, _RuleSort sort) {
    return switch (sort) {
      _RuleSort.original => context.t('默认顺序'),
      _RuleSort.sizeDesc => context.t('体积从大到小'),
      _RuleSort.sizeAsc => context.t('体积从小到大'),
      _RuleSort.name => context.t('名称 A–Z'),
    };
  }

  bool _matchesRule(RuleResult result, String query, BroomStrings strings) {
    if (query.isEmpty) return true;
    final fields = [
      strings.ruleTitle(result.rule),
      strings.ruleCategory(result.rule),
      strings.ruleDescription(result.rule),
      strings.ruleNote(result.rule) ?? '',
      result.rule.id,
      ...result.rule.pathPatterns,
    ];
    return fields.any((field) => field.toLowerCase().contains(query));
  }

  List<({String category, List<RuleResult> results})> _visibleGroups(
    BuildContext context,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    final results = [
      for (final result in controller.results)
        if (_matchesRule(result, query, context.strings)) result,
    ];
    final groups = _groupResults(results, context.strings);
    if (_sort == _RuleSort.original) return groups;

    int compare(RuleResult a, RuleResult b) {
      return switch (_sort) {
        _RuleSort.original => 0,
        _RuleSort.sizeDesc => b.totalBytes.compareTo(a.totalBytes),
        _RuleSort.sizeAsc => a.totalBytes.compareTo(b.totalBytes),
        _RuleSort.name =>
          context.strings
              .ruleTitle(a.rule)
              .toLowerCase()
              .compareTo(context.strings.ruleTitle(b.rule).toLowerCase()),
      };
    }

    for (final group in groups) {
      group.results.sort(compare);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totalItems = controller.results.fold<int>(
      0,
      (total, result) => total + result.items.length,
    );
    final totalBytes = controller.results.fold<int>(
      0,
      (total, result) => total + result.totalBytes,
    );
    final allSelected = controller.allItemsSelected;
    final query = _searchController.text.trim();
    final visibleGroups = _visibleGroups(context);
    final visibleRuleCount = visibleGroups.fold<int>(
      0,
      (total, group) => total + group.results.length,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.error case final error?)
            _InlineBanner(
              message: error,
              isError: true,
              onClose: controller.clearError,
            ),
          if (controller.scanRestoredFromPersistence)
            if (controller.notice case final notice?)
              _InlineBanner(message: notice, onClose: controller.clearNotice),
          if (controller.scanPersistenceNotice case final notice?)
            _InlineBanner(icon: LucideIcons.save, message: notice),
          if (controller.scanDirectoryErrors > 0)
            _InlineBanner(
              message: context.tf('扫描时遇到 {count} 个路径问题，已跳过。', {
                'count': formatCount(controller.scanDirectoryErrors),
              }),
              action: TextButton(
                key: const ValueKey('scan-issue-details'),
                onPressed: () => _showScanIssueDetails(context),
                child: Text(context.t('查看明细')),
              ),
            ),
          if (controller.scanTruncated)
            _InlineBanner(
              message: controller.scanRestoredFromPersistence
                  ? context.t('上次扫描结果达到设定的数量上限，可能不完整。')
                  : context.t('扫描结果达到设定的数量上限，预览与清理仅包含已找到的部分。'),
            ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('扫描结果'),
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      controller.results.isEmpty
                          ? context.t('没有发现可清理的文件')
                          : query.isNotEmpty
                          ? context.tf('筛选后显示 {shown} / {total} 条规则', {
                              'shown': formatCount(visibleRuleCount),
                              'total': formatCount(controller.results.length),
                            })
                          : context.tf('发现 {count} 个文件 · {bytes}，请选择要清理的内容。', {
                              'count': formatCount(totalItems),
                              'bytes': formatBytes(totalBytes),
                            }),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('preview-back'),
                onPressed: controller.returnHome,
                icon: const Icon(LucideIcons.arrowLeft, size: 16),
                label: Text(context.t('返回概览')),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: context.t('F5 重新扫描'),
                child: OutlinedButton.icon(
                  onPressed: controller.scan,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: Text(context.t('重新扫描')),
                ),
              ),
            ],
          ),
          if (controller.lockProbeRunning ||
              controller.possiblyLockedCount > 0 ||
              controller.previewReviewRuleCount > 0) ...[
            const SizedBox(height: 10),
            _PreviewNotices(controller: controller),
          ],
          if (controller.results.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ScanSummaryCard(
              controller: controller,
              onShowIssues: () => _showScanIssueDetails(context),
            ),
            const SizedBox(height: 12),
            _PreviewToolbar(
              searchController: _searchController,
              searchFocus: _searchFocus,
              sort: _sort,
              sortLabel: _sortLabel(context, _sort),
              onQueryChanged: () => setState(() {}),
              onClearQuery: () {
                _searchController.clear();
                setState(() {});
                _searchFocus.requestFocus();
              },
              onSortChanged: (sort) => setState(() => _sort = sort),
            ),
          ],
          const SizedBox(height: 14),
          if (controller.results.isEmpty)
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: _SurfaceCard(
                    padding: const EdgeInsets.fromLTRB(28, 34, 28, 30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.circleCheck,
                          size: 44,
                          color: scheme.primary,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          context.t('没有发现可清理的内容'),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.t('系统看起来很干净。关闭正在使用的浏览器或开发工具后，可以再扫描一次。'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Tooltip(
                          message: context.t('再扫描一次（F5）'),
                          child: FilledButton.tonalIcon(
                            onPressed: controller.scan,
                            icon: const Icon(LucideIcons.refreshCw, size: 18),
                            label: Text(context.t('再扫描一次')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else ...[
            Expanded(
              child: visibleGroups.isEmpty
                  ? Center(
                      key: const ValueKey('preview-filter-empty'),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              LucideIcons.searchX,
                              size: 40,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              context.t('没有匹配的规则'),
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              context.t('试试更短的名称、类别或路径模板。'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() {});
                              },
                              child: Text(context.t('清除搜索')),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 6),
                      children: [
                        for (final group in visibleGroups)
                          _ResultGroup(
                            category: group.category,
                            results: group.results,
                            controller: controller,
                            shell: shell,
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            _CleanActionBar(
              controller: controller,
              allSelected: allSelected,
              onCleanRequested: onCleanRequested,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showScanIssueDetails(BuildContext context) async {
    final groups = controller.scanIssueGroups;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final scheme = theme.colorScheme;
        return AlertDialog(
          icon: const Icon(LucideIcons.triangleAlert, size: 30),
          title: Text(context.t('扫描问题明细')),
          content: SizedBox(
            width: 560,
            child: groups.isEmpty
                ? Text(context.t('没有可展示的问题明细。'))
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        Text(
                          context.t('这些路径在扫描时无法读取，已安全跳过，不会影响其他结果。'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (final group in groups) ...[
                          Row(
                            children: [
                              Icon(
                                _scanIssueIcon(group.kind),
                                size: 16,
                                color: scheme.tertiary,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _scanIssueLabel(context, group.kind),
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                              Text(
                                formatCount(group.count),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          for (final path in group.samplePaths)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 23,
                                bottom: 2,
                              ),
                              child: Text(
                                path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.t('知道了')),
            ),
          ],
        );
      },
    );
  }
}

String _scanIssueLabel(BuildContext context, ScanErrorKind kind) {
  return switch (kind) {
    ScanErrorKind.accessDenied => context.t('没有访问权限'),
    ScanErrorKind.pathTooLong => context.t('路径过长'),
    ScanErrorKind.notFound => context.t('文件或目录不存在'),
    ScanErrorKind.deviceNotReady => context.t('设备未就绪'),
    ScanErrorKind.networkUnavailable => context.t('网络路径不可用'),
    ScanErrorKind.writeProtected => context.t('介质为只读'),
    ScanErrorKind.diskFull => context.t('磁盘空间不足'),
    ScanErrorKind.unsupported => context.t('文件系统不支持'),
    ScanErrorKind.sharingViolation => context.t('被其他程序占用'),
    ScanErrorKind.invalidName => context.t('文件名或路径无效'),
    ScanErrorKind.ioError => context.t('读取失败'),
    ScanErrorKind.other => context.t('其他错误'),
  };
}

IconData _scanIssueIcon(ScanErrorKind kind) {
  return switch (kind) {
    ScanErrorKind.accessDenied => LucideIcons.lock,
    ScanErrorKind.pathTooLong => LucideIcons.ruler,
    ScanErrorKind.notFound => LucideIcons.searchX,
    ScanErrorKind.deviceNotReady => LucideIcons.usb,
    ScanErrorKind.networkUnavailable => LucideIcons.wifiOff,
    ScanErrorKind.writeProtected => LucideIcons.lock,
    ScanErrorKind.diskFull => LucideIcons.hardDrive,
    ScanErrorKind.unsupported => LucideIcons.unplug,
    ScanErrorKind.sharingViolation => LucideIcons.fileLock2,
    ScanErrorKind.invalidName => LucideIcons.alignLeft,
    ScanErrorKind.ioError => LucideIcons.circleAlert,
    ScanErrorKind.other => LucideIcons.circleHelp,
  };
}

class _PreviewToolbar extends StatelessWidget {
  const _PreviewToolbar({
    required this.searchController,
    required this.searchFocus,
    required this.sort,
    required this.sortLabel,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onSortChanged,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;
  final _RuleSort sort;
  final String sortLabel;
  final VoidCallback onQueryChanged;
  final VoidCallback onClearQuery;
  final ValueChanged<_RuleSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('preview-search'),
            controller: searchController,
            focusNode: searchFocus,
            onChanged: (_) => onQueryChanged(),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: context.t('搜索扫描结果'),
              hintText: context.t('规则名称、类别或路径模板'),
              prefixIcon: const Icon(LucideIcons.search, size: 19),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.t('清除搜索'),
                      onPressed: onClearQuery,
                      icon: const Icon(LucideIcons.x, size: 17),
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        PopupMenuButton<_RuleSort>(
          key: const ValueKey('preview-sort'),
          tooltip: context.t('排序规则'),
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (context) => [
            for (final value in _RuleSort.values)
              PopupMenuItem(
                value: value,
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      child: value == sort
                          ? const Icon(LucideIcons.check, size: 17)
                          : null,
                    ),
                    Text(switch (value) {
                      _RuleSort.original => context.t('默认顺序'),
                      _RuleSort.sizeDesc => context.t('体积从大到小'),
                      _RuleSort.sizeAsc => context.t('体积从小到大'),
                      _RuleSort.name => context.t('名称 A–Z'),
                    }),
                  ],
                ),
              ),
          ],
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.arrowUpDown,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(sortLabel, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.chevronDown,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

const _summaryPalette = <Color>[
  Color(0xFF2F7BFF),
  Color(0xFF7C5CFF),
  Color(0xFF19A7C9),
  Color(0xFFF0A72E),
  Color(0xFFE45C8A),
  Color(0xFF5B708F),
  Color(0xFF8A63D2),
  Color(0xFF3E9BB8),
];

class _PreviewNotices extends StatelessWidget {
  const _PreviewNotices({required this.controller});

  final CleanController controller;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      radius: 11,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.lockProbeRunning)
            _PreviewNotice(
              icon: LucideIcons.lock,
              color: BroomColors.accent,
              text: context.tf('正在检测被占用的文件…（{checked} / {total}）', {
                'checked': formatCount(controller.lockProbeChecked),
                'total': formatCount(controller.lockProbeTotal),
              }),
            )
          else if (controller.possiblyLockedCount > 0)
            _PreviewNotice(
              icon: LucideIcons.lock,
              color: BroomColors.amber,
              text: context.tf('{count} 个文件可能正被占用，清理时会跳过', {
                'count': formatCount(controller.possiblyLockedCount),
              }),
            ),
          if (controller.previewReviewRuleCount > 0) ...[
            if (controller.lockProbeRunning ||
                controller.possiblyLockedCount > 0)
              const SizedBox(height: 6),
            _PreviewNotice(
              icon: LucideIcons.shield,
              color: BroomColors.inkMuted(context),
              text: context.tf('扫描结果包含 {count} 条需确认规则，默认未勾选。', {
                'count': controller.previewReviewRuleCount,
              }),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: BroomColors.inkMuted(context)),
          ),
        ),
      ],
    );
  }
}

class _ScanSummaryCard extends StatelessWidget {
  const _ScanSummaryCard({
    required this.controller,
    required this.onShowIssues,
  });

  final CleanController controller;
  final VoidCallback onShowIssues;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = <String, ({int files, int bytes})>{};
    for (final result in controller.results) {
      final category = context.strings.ruleCategory(result.rule);
      final current = totals[category];
      totals[category] = (
        files: (current?.files ?? 0) + result.items.length,
        bytes: (current?.bytes ?? 0) + result.totalBytes,
      );
    }
    final categories = totals.entries.toList()
      ..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
    final totalBytes = categories.fold<int>(
      0,
      (total, entry) => total + entry.value.bytes,
    );
    final totalFiles = categories.fold<int>(
      0,
      (total, entry) => total + entry.value.files,
    );
    final elapsed = controller.scanElapsed;
    final persistenceLimited = controller.scanPersistenceNotice != null;
    final resultLimited = controller.scanTruncated || persistenceLimited;

    final totalColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t('可清理总量'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          formatBytes(totalBytes),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          context.tf('{files} 个文件 · 已检查 {scanned} 个文件', {
            'files': formatCount(totalFiles),
            'scanned': formatCount(controller.scanScannedFiles),
          }),
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (elapsed != null) ...[
          const SizedBox(height: 2),
          Text(
            context.tf('扫描用时 {duration}', {
              'duration': formatDuration(elapsed),
            }),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    final distribution = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t('分类体积占比'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 9,
            child: totalBytes <= 0
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : Row(
                    children: [
                      for (var index = 0; index < categories.length; index++)
                        Expanded(
                          flex: _summaryFlex(
                            categories[index].value.bytes,
                            totalBytes,
                          ),
                          child: ColoredBox(
                            color:
                                _summaryPalette[index % _summaryPalette.length],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 14,
          runSpacing: 5,
          children: [
            for (var index = 0; index < categories.length; index++)
              Tooltip(
                message: formatBytes(categories[index].value.bytes),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _summaryPalette[index % _summaryPalette.length],
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${categories[index].key} · '
                      '${_summaryPercent(categories[index].value.bytes, totalBytes)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );

    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              resultLimited ? LucideIcons.scissors : LucideIcons.circleCheck,
              size: 16,
              color: resultLimited ? scheme.tertiary : scheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                controller.scanTruncated
                    ? context.t('结果达到数量上限，可能不完整')
                    : persistenceLimited
                    ? context.t('持久化结果可能不完整')
                    : context.t('结果未截断'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: resultLimited
                      ? scheme.tertiary
                      : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          context.tf('已跳过 {count} 个无法读取的路径', {
            'count': formatCount(controller.scanDirectoryErrors),
          }),
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (controller.possiblyLockedCount > 0) ...[
          const SizedBox(height: 4),
          Text(
            context.tf('{count} 个文件可能被占用', {
              'count': formatCount(controller.possiblyLockedCount),
            }),
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.tertiary),
          ),
        ],
        if (controller.scanDirectoryErrors > 0)
          TextButton(
            onPressed: onShowIssues,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(context.t('查看问题明细')),
          ),
      ],
    );

    return Semantics(
      container: true,
      label: context.tf('扫描摘要：可清理 {bytes}，跳过 {skipped} 个路径', {
        'bytes': formatBytes(totalBytes),
        'skipped': formatCount(controller.scanDirectoryErrors),
      }),
      child: _SurfaceCard(
        padding: const EdgeInsets.fromLTRB(18, 15, 18, 15),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 820) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  totalColumn,
                  const SizedBox(height: 12),
                  distribution,
                  const SizedBox(height: 10),
                  status,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 225, child: totalColumn),
                const SizedBox(width: 22),
                Expanded(child: distribution),
                const SizedBox(width: 22),
                SizedBox(width: 205, child: status),
              ],
            );
          },
        ),
      ),
    );
  }

  static int _summaryFlex(int bytes, int totalBytes) {
    if (totalBytes <= 0) return 1;
    return (bytes / totalBytes * 1000).round().clamp(1, 1000).toInt();
  }

  static String _summaryPercent(int bytes, int totalBytes) {
    if (totalBytes <= 0) return '0%';
    final percent = bytes / totalBytes * 100;
    if (percent > 0 && percent < 1) return '<1%';
    return '${percent.round()}%';
  }
}

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({
    required this.category,
    required this.results,
    required this.controller,
    required this.shell,
  });

  final String category;
  final List<RuleResult> results;
  final CleanController controller;
  final SystemShell shell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final itemCount = results.fold<int>(
      0,
      (total, result) => total + result.items.length,
    );
    final bytes = results.fold<int>(
      0,
      (total, result) => total + result.totalBytes,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
            child: Row(
              children: [
                Icon(_categoryIcon(category), size: 16, color: scheme.primary),
                const SizedBox(width: 7),
                Text(category, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  context.tf('{count} 个文件 · {bytes}', {
                    'count': formatCount(itemCount),
                    'bytes': formatBytes(bytes),
                  }),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final result in results)
            _RuleResultCard(
              result: result,
              controller: controller,
              shell: shell,
            ),
        ],
      ),
    );
  }
}

class _RuleResultCard extends StatelessWidget {
  const _RuleResultCard({
    required this.result,
    required this.controller,
    required this.shell,
  });

  final RuleResult result;
  final CleanController controller;
  final SystemShell shell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bool? selection = controller.ruleSelectionValue(result.rule.id);
    final selected = selection == true;
    final selectedCount = controller.selectedCountForRule(result.rule.id);
    final rule = result.rule;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? Color.alphaBlend(
                scheme.primary.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.11
                      : 0.05,
                ),
                BroomColors.card(context),
              )
            : selection == null
            ? Color.alphaBlend(
                scheme.primary.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.06
                      : 0.03,
                ),
                BroomColors.card(context),
              )
            : BroomColors.card(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: 0.26)
                : selection == null
                ? scheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
        ),
        child: InkWell(
          onTap: () => controller.toggleRule(rule.id),
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
            child: Row(
              children: [
                MergeSemantics(
                  child: Semantics(
                    label: context.tf('选择规则 {name}', {
                      'name': context.strings.ruleTitle(rule),
                    }),
                    child: Checkbox(
                      value: selection,
                      tristate: true,
                      onChanged: (_) => controller.toggleRule(rule.id),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: BroomColors.block(context),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _ruleIcon(rule.id),
                    size: 20,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              context.strings.ruleTitle(rule),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (rule.risk == CleanRisk.review) ...[
                            const SizedBox(width: 8),
                            const RiskBadge(risk: CleanRisk.review),
                          ],
                          const SizedBox(width: 12),
                          Text(
                            formatBytes(result.totalBytes),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        selection == null
                            ? context.tf('已选 {selected} / {total} 个文件', {
                                'selected': formatCount(selectedCount),
                                'total': formatCount(result.items.length),
                              })
                            : context.tf('{count} 个文件 · {description}', {
                                'count': formatCount(result.items.length),
                                'description': context.strings.ruleDescription(
                                  rule,
                                ),
                              }),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      if (context.strings.ruleNote(rule) case final note?) ...[
                        const SizedBox(height: 3),
                        Text(
                          note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                      ],
                      if (controller.possiblyLockedCountForRule(rule.id)
                          case final lockedCount when lockedCount > 0) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              LucideIcons.lock,
                              size: 13,
                              color: scheme.tertiary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              context.tf('{count} 个文件可能被占用', {
                                'count': formatCount(lockedCount),
                              }),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.tertiary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RuleDetailPage(
                          controller: controller,
                          result: result,
                          shell: shell,
                        ),
                      ),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(context.t('查看')),
                      const SizedBox(width: 2),
                      const Icon(LucideIcons.chevronRight, size: 17),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CleanActionBar extends StatelessWidget {
  const _CleanActionBar({
    required this.controller,
    required this.allSelected,
    required this.onCleanRequested,
  });

  final CleanController controller;
  final bool allSelected;
  final VoidCallback onCleanRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(24),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tf('已选择 {count} 项', {
                    'count': formatCount(controller.selectedCount),
                  }),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  context.tf('预计暂存 {bytes}，释放隔离区后才会回收磁盘空间', {
                    'bytes': formatBytes(controller.selectedBytes),
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (controller.selectedPossiblyLockedCount > 0) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(LucideIcons.lock, size: 13, color: scheme.tertiary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          context.tf('已选文件中有 {count} 个可能被占用，清理时会跳过', {
                            'count': formatCount(
                              controller.selectedPossiblyLockedCount,
                            ),
                          }),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (controller.selectedReviewRuleCount > 0) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        LucideIcons.shield,
                        size: 13,
                        color: scheme.tertiary,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          context.tf('已选 {count} 条需确认规则，提交前需要额外确认', {
                            'count': controller.selectedReviewRuleCount,
                          }),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: allSelected
                    ? controller.clearRuleSelection
                    : controller.selectAllRules,
                child: Text(allSelected ? context.t('取消全选') : context.t('全选')),
              ),
              TextButton(
                onPressed: controller.hasSelection
                    ? controller.invertSelection
                    : null,
                child: Text(context.t('反选')),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: controller.selectedCount == 0
                    ? null
                    : onCleanRequested,
                icon: const Icon(LucideIcons.broom, size: 18),
                label: Text(
                  context.tf('清理 {count} 项', {
                    'count': formatCount(controller.selectedCount),
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CleaningView extends StatelessWidget {
  const _CleaningView({required this.controller});

  final CleanController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = controller.cleanProgress;
    final total = progress?.total ?? 0;
    final processed = progress?.processed ?? 0;
    final value = total == 0 ? null : processed / total;
    final current = progress?.currentPath;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: _SurfaceCard(
            padding: const EdgeInsets.fromLTRB(32, 34, 32, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 82,
                    height: 82,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primaryContainer.withValues(alpha: 0.55),
                    ),
                    child: Icon(
                      LucideIcons.archive,
                      size: 34,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  controller.cleanCancelRequested
                      ? context.t('正在停止清理…')
                      : context.t('正在移入隔离区'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  context.t('文件会保存在隔离区，完成后可以撤销。'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 22),
                Semantics(
                  label: context.t('清理进度'),
                  value: context.tf('{processed} / {total} 项', {
                    'processed': processed,
                    'total': total,
                  }),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: RepaintBoundary(
                      // Every processed file moves the bar; easing between
                      // reports keeps it from stepping while moves are quick.
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: value ?? 0),
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOut,
                        builder: (context, animated, _) =>
                            LinearProgressIndicator(
                              value: value == null ? null : animated,
                              minHeight: 8,
                              backgroundColor: scheme.surfaceContainerHighest,
                            ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      context.tf('{processed} / {total} 项', {
                        'processed': processed,
                        'total': total,
                      }),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      progress != null && progress.skipped > 0
                          ? context.tf('已移动 {moved} 项 · 已跳过 {skipped} 项', {
                              'moved': formatCount(progress.moved),
                              'skipped': formatCount(progress.skipped),
                            })
                          : context.tf('已移动 {count} 项 · {bytes}', {
                              'count': formatCount(progress?.moved ?? 0),
                              'bytes': formatBytes(progress?.movedBytes ?? 0),
                            }),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (current != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.file,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Tooltip(
                            message: current,
                            child: Text(
                              fileNameOf(current),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Center(
                  child: Tooltip(
                    message: context.t('停止清理（Esc）'),
                    child: OutlinedButton.icon(
                      onPressed: controller.cleanCancelRequested
                          ? null
                          : controller.cancelCleaning,
                      icon: const Icon(LucideIcons.circleStop, size: 17),
                      label: Text(
                        controller.cleanCancelRequested
                            ? context.t('正在停止…')
                            : context.t('停止清理'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneView extends StatelessWidget {
  const _DoneView({
    required this.controller,
    required this.onUndo,
    required this.onOpenQuarantine,
  });

  final CleanController controller;
  final Future<void> Function(String sessionId) onUndo;
  final VoidCallback onOpenQuarantine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = controller.lastReport;
    if (report == null) {
      return const SizedBox.shrink();
    }
    final noMoves = report.movedCount == 0;
    final title = report.cancelled
        ? context.t('清理已停止')
        : report.spaceExhausted
        ? context.t('磁盘空间不足，清理已暂停')
        : noMoves
        ? context.t('没有文件被移动')
        : context.t('清理完成');

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: _SurfaceCard(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.error case final error?)
                  _InlineBanner(
                    message: error,
                    isError: true,
                    onClose: controller.clearError,
                  ),
                Center(
                  child: Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: report.cancelled
                          ? scheme.tertiaryContainer.withValues(alpha: 0.5)
                          : report.spaceExhausted
                          ? scheme.errorContainer.withValues(alpha: 0.45)
                          : scheme.primaryContainer.withValues(alpha: 0.55),
                    ),
                    child: Icon(
                      report.cancelled
                          ? LucideIcons.pause
                          : report.spaceExhausted
                          ? LucideIcons.triangleAlert
                          : LucideIcons.check,
                      size: 36,
                      color: report.cancelled
                          ? scheme.onTertiaryContainer
                          : report.spaceExhausted
                          ? scheme.onErrorContainer
                          : scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  report.cancelled
                      ? context.t(
                          '已停止清理，已经移动的文件仍保存在隔离区中，'
                          '未处理的文件可以继续清理。',
                        )
                      : report.spaceExhausted
                      ? context.t(
                          '隔离区所在磁盘空间不足，已停止继续复制文件。'
                          '已移动的文件仍在隔离区，释放空间后可以继续清理。',
                        )
                      : noMoves
                      ? report.skippedCount > 0
                            ? context.t('没有文件移入隔离区；被占用或已不存在的文件已跳过。')
                            : context.t('没有文件成功移入隔离区，可以稍后重试。')
                      : context.t(
                          '文件已安全移动到隔离区，可随时恢复。'
                          '释放隔离区后才会回收磁盘空间。',
                        ),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.32,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _DoneStat(
                          label: context.t('已暂存'),
                          value: formatBytes(report.movedBytes),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 34,
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                      Expanded(
                        child: _DoneStat(
                          label: context.t('移入隔离区'),
                          value: context.tf('{count} 个文件', {
                            'count': formatCount(report.movedCount),
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                if (report.removedDirectoryCount > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tf('已清理 {count} 个空缓存目录。', {
                      'count': report.removedDirectoryCount,
                    }),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (report.skippedCount > 0) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              LucideIcons.lock,
                              size: 17,
                              color: scheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.tf('{count} 个文件已跳过', {
                                  'count': report.skippedCount,
                                }),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.t(
                            '这些文件可能正被其他程序占用，或已不存在。'
                            '它们保留在原处，没有被修改。',
                          ),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer.withValues(
                              alpha: 0.9,
                            ),
                            height: 1.45,
                          ),
                        ),
                        for (final skip in report.skips.take(3)) ...[
                          const SizedBox(height: 6),
                          Text(
                            '• ${fileNameOf(skip.path)}：${skip.reason}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        ],
                        if (report.skips.length > 3)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              context.tf('还有 {count} 条未显示…', {
                                'count': report.skips.length - 3,
                              }),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSecondaryContainer.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (report.failureCount > 0) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer.withValues(alpha: 0.32),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: scheme.tertiary.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              LucideIcons.triangleAlert,
                              size: 17,
                              color: scheme.onTertiaryContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.tf('{count} 个文件清理失败。', {
                                  'count': report.failureCount,
                                }),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.t('请检查文件权限、磁盘空间或路径状态后重试。'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onTertiaryContainer.withValues(
                              alpha: 0.9,
                            ),
                            height: 1.45,
                          ),
                        ),
                        for (final failure in report.failures.take(3)) ...[
                          const SizedBox(height: 6),
                          Text(
                            '• ${fileNameOf(failure.path)}：${failure.reason}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onTertiaryContainer.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        ],
                        if (report.failures.length > 3)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              context.tf('还有 {count} 条未显示…', {
                                'count': report.failures.length - 3,
                              }),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onTertiaryContainer.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (!noMoves || controller.canResumeLastReport)
                      OutlinedButton.icon(
                        onPressed: onOpenQuarantine,
                        icon: controller.canResumeLastReport
                            ? const Icon(LucideIcons.circlePlay, size: 18)
                            : const Icon(LucideIcons.archive, size: 18),
                        label: Text(
                          controller.canResumeLastReport
                              ? context.t('继续清理')
                              : context.t('管理隔离区'),
                        ),
                      ),
                    if (controller.canUndoLastReport)
                      OutlinedButton.icon(
                        onPressed: controller.undoBusy
                            ? null
                            : () => onUndo(report.sessionId!),
                        icon: const Icon(LucideIcons.undo2, size: 18),
                        label: Text(context.t('撤销本次清理')),
                      ),
                    Tooltip(
                      message: context.t('返回首页（Alt+← 或 Esc）'),
                      child: FilledButton.icon(
                        onPressed: controller.returnHome,
                        icon: const Icon(LucideIcons.house, size: 18),
                        label: Text(context.t('返回首页')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneStat extends StatelessWidget {
  const _DoneStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(30),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: child,
    );
  }
}

class _BusyDialog extends StatelessWidget {
  const _BusyDialog({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Flexible(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _UndoResultDialog extends StatelessWidget {
  const _UndoResultDialog({required this.report});

  final UndoReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strings = context.strings;
    final title = report.sessionRemoved
        ? strings.t('撤销完成')
        : strings.t('部分文件已恢复');

    return AlertDialog(
      icon: Icon(
        report.sessionRemoved ? LucideIcons.undo2 : LucideIcons.info,
        size: 30,
        color: scheme.primary,
      ),
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.tf('已恢复 {count} 个文件（{bytes}）。', {
              'count': report.restoredCount,
              'bytes': formatBytes(report.restoredBytes),
            }),
          ),
          if (report.conflictCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              strings.tf(
                '{count} 个文件的原位置已有新文件，已跳过。'
                '可在隔离区重新恢复并选择保留两者或覆盖。',
                {'count': report.conflictCount},
              ),
            ),
          ],
          if (report.integrityFailureCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              strings.tf('{count} 个文件未通过完整性校验，已跳过恢复，仍保留在隔离区。', {
                'count': report.integrityFailureCount,
              }),
            ),
          ],
          if (report.failureCount > report.integrityFailureCount) ...[
            const SizedBox(height: 8),
            Text(
              strings.tf('{count} 个文件恢复失败。', {
                'count': report.failureCount - report.integrityFailureCount,
              }),
            ),
          ],
          if (report.metadataFailureCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              strings.tf('{count} 个文件的内容已恢复，但时间戳、只读属性或 ACL 未能完全还原。', {
                'count': report.metadataFailureCount,
              }),
            ),
          ],
          if (report.recreatedDirectoryCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              strings.tf('已重建 {count} 个空缓存目录。', {
                'count': report.recreatedDirectoryCount,
              }),
            ),
          ],
          if (report.directoryFailureCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              strings.tf('{count} 个空目录未能重建。', {
                'count': report.directoryFailureCount,
              }),
            ),
          ],
          if (!report.sessionRemoved) ...[
            const SizedBox(height: 10),
            Text(
              strings.t('未能恢复的文件仍保留在隔离区中。'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.t('知道了')),
        ),
      ],
    );
  }
}

List<({String category, List<RuleResult> results})> _groupResults(
  List<RuleResult> results,
  BroomStrings strings,
) {
  final groups = <String, List<RuleResult>>{};
  for (final result in results) {
    groups.putIfAbsent(strings.ruleCategory(result.rule), () => []).add(result);
  }
  return [
    for (final entry in groups.entries)
      (category: entry.key, results: entry.value),
  ];
}

IconData _categoryIcon(String category) {
  final lower = category.toLowerCase();
  if (category.contains('残留') || lower.contains('leftover')) {
    return LucideIcons.packageX;
  }
  if (category.contains('浏览器') || lower.contains('browser')) {
    return LucideIcons.globe;
  }
  if (category.contains('日志') || lower.contains('log')) {
    return LucideIcons.receiptText;
  }
  if (category.contains('缩略图') || lower.contains('thumbnail')) {
    return LucideIcons.image;
  }
  if (category.contains('GPU') || lower.contains('graphics')) {
    return LucideIcons.cpu;
  }
  if (category.contains('应用') || lower.contains('app cache')) {
    return LucideIcons.layoutGrid;
  }
  if (category.contains('开发') || lower.contains('developer')) {
    return LucideIcons.code;
  }
  return LucideIcons.folder;
}

IconData _ruleIcon(String ruleId) {
  if (ruleId.startsWith('browser')) return LucideIcons.globe;
  if (ruleId.startsWith('dev')) return LucideIcons.terminal;
  if (ruleId.startsWith('app')) return LucideIcons.layoutGrid;
  if (ruleId.startsWith('gpu')) return LucideIcons.cpu;
  if (ruleId.startsWith('logs')) return LucideIcons.receiptText;
  return switch (ruleId) {
    'windows.user_temp' => LucideIcons.folderOpen,
    'windows.crash_dumps' => LucideIcons.bug,
    'windows.wer_reports' => LucideIcons.circleAlert,
    'windows.thumbnail_icon_cache' => LucideIcons.image,
    _ => LucideIcons.trash2,
  };
}
