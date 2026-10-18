import 'dart:async';

import 'package:flutter/material.dart';

import '../core/analysis/analysis_service.dart';
import '../core/clean/quarantine_retention_service.dart';
import '../core/models/clean_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/scan_models.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'clean_controller.dart';
import 'duplicate_finder_page.dart';
import 'exclusions_page.dart';
import 'format.dart';
import 'large_files_page.dart';
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
    this.quarantineRetention,
    this.analysisInitialDirectory,
    this.analysisExcludedPaths = const [],
    this.startInSystemCache = false,
    this.ruleUpdates,
  });

  final CleanController controller;
  final SettingsController settingsController;
  final SystemShell shell;
  final SystemCacheController? systemCacheController;
  final QuarantineRetentionService? quarantineRetention;
  final AnalysisRunner Function() analysisRunnerFactory;
  final String? analysisInitialDirectory;
  final List<String> analysisExcludedPaths;
  final bool startInSystemCache;
  final RuleUpdateController? ruleUpdates;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CleanController get controller => widget.controller;

  bool _startupPromptScheduled = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_maybeScheduleUnfinishedPrompt);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeScheduleUnfinishedPrompt(),
    );
    if (widget.startInSystemCache && widget.systemCacheController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openSystemCache();
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(_maybeScheduleUnfinishedPrompt);
    super.dispose();
  }

  void _maybeScheduleUnfinishedPrompt() {
    if (!mounted || _startupPromptScheduled) return;
    if (!controller.initialized || widget.startInSystemCache) return;
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
          Icons.restore_rounded,
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
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scheme.surface, scheme.surfaceContainerLowest],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 20, 28, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [Expanded(child: _buildBody(context))],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (controller.phase) {
      case CleanPhase.idle:
        return _IdleView(
          controller: controller,
          onOpenQuarantine: _openQuarantine,
          onOpenSystemCache: widget.systemCacheController == null
              ? null
              : _openSystemCache,
          onOpenRecycleBin: _openRecycleBin,
          onOpenDuplicateFinder: _openDuplicateFinder,
          onOpenLargeFiles: _openLargeFiles,
          onOpenExclusions: _openExclusions,
          onOpenSettings: _openSettings,
          isRuleEnabled: widget.settingsController.isRuleEnabled,
          settingsController: widget.settingsController,
        );
      case CleanPhase.scanning:
        return _ScanningView(controller: controller);
      case CleanPhase.preview:
        return _PreviewView(
          controller: controller,
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
            icon: const Icon(Icons.cleaning_services_rounded, size: 30),
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
                          '所选内容包含 {count} 条 Review 规则。它们默认不会勾选，'
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
                        strings.t('我了解 Review 规则的影响，并仍要清理所选内容'),
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
          icon: const Icon(Icons.error_outline_rounded, size: 30),
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

  Future<void> _openQuarantine() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuarantinePage(
          service: controller.quarantine,
          shell: widget.shell,
          retention: widget.quarantineRetention,
        ),
      ),
    );
    if (!mounted) return;
    await controller.refreshQuarantine();
  }

  Future<void> _openSystemCache() {
    final systemController = widget.systemCacheController;
    if (systemController == null) return Future<void>.value();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SystemCachePage(controller: systemController),
      ),
    );
  }

  Future<void> _openRecycleBin() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecycleBinPage(shell: widget.shell),
      ),
    );
  }

  Future<void> _openDuplicateFinder() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DuplicateFinderPage(
          shell: widget.shell,
          runnerFactory: widget.analysisRunnerFactory,
          initialDirectory: widget.analysisInitialDirectory,
          excludedPaths: widget.analysisExcludedPaths,
        ),
      ),
    );
  }

  Future<void> _openLargeFiles() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LargeFilesPage(
          shell: widget.shell,
          runnerFactory: widget.analysisRunnerFactory,
          initialDirectory: widget.analysisInitialDirectory,
          excludedPaths: widget.analysisExcludedPaths,
        ),
      ),
    );
  }

  Future<void> _openExclusions() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExclusionsPage(controller: controller, shell: widget.shell),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          settings: widget.settingsController,
          cleanController: controller,
          shell: widget.shell,
          retention: widget.quarantineRetention,
          ruleUpdates: widget.ruleUpdates,
        ),
      ),
    );
    if (!mounted) return;
    await controller.refreshRuleExclusionScopes();
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
    required this.onOpenSettings,
    required this.isRuleEnabled,
    required this.settingsController,
    this.onOpenSystemCache,
  });

  final CleanController controller;
  final VoidCallback onOpenQuarantine;
  final VoidCallback onOpenRecycleBin;
  final VoidCallback onOpenDuplicateFinder;
  final VoidCallback onOpenLargeFiles;
  final VoidCallback onOpenExclusions;
  final VoidCallback onOpenSettings;
  final bool Function(String ruleId) isRuleEnabled;
  final SettingsController settingsController;
  final VoidCallback? onOpenSystemCache;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (controller.error case final error?)
          _InlineBanner(
            message: error,
            isError: true,
            onClose: controller.clearError,
          ),
        if (controller.notice case final notice?)
          _InlineBanner(message: notice, onClose: controller.clearNotice),
        _Hero(controller: controller, onOpenSettings: onOpenSettings),
        if (controller.pendingSessions.isNotEmpty) ...[
          const SizedBox(height: 14),
          _QuarantineCard(controller: controller, onOpen: onOpenQuarantine),
        ],
        if (controller.lastScanSummary != null) ...[
          const SizedBox(height: 14),
          _LastScanCard(controller: controller),
        ],
        const SizedBox(height: 20),
        _ToolsSection(
          onOpenSystemCache: onOpenSystemCache,
          onOpenRecycleBin: onOpenRecycleBin,
          onOpenDuplicateFinder: onOpenDuplicateFinder,
          onOpenLargeFiles: onOpenLargeFiles,
        ),
        const SizedBox(height: 22),
        ListenableBuilder(
          listenable: settingsController,
          builder: (context, _) => _ScopeSection(
            rules: controller.platform.rules,
            scopes: controller.ruleExclusionScopes,
            exclusionCount: controller.exclusionCount,
            onOpenExclusions: onOpenExclusions,
            isRuleEnabled: isRuleEnabled,
            settings: settingsController,
          ),
        ),
        const SizedBox(height: 14),
        const _SafetyNote(),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.controller, required this.onOpenSettings});

  final CleanController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer.withValues(alpha: 0.92),
            scheme.secondaryContainer.withValues(alpha: 0.55),
            scheme.surfaceContainerLow,
          ],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.12)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final copy = _HeroCopy(
            controller: controller,
            onOpenSettings: onOpenSettings,
          );
          final artwork = const SizedBox(
            width: 236,
            height: 196,
            child: _HeroArtwork(),
          );

          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copy,
                const SizedBox(height: 16),
                Center(child: artwork),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: 24),
              artwork,
            ],
          );
        },
      ),
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({required this.controller, required this.onOpenSettings});

  final CleanController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.monitor_outlined,
              size: 14,
              color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Text(
              context.t('WINDOWS · SAFE + REVIEW 级清理'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            IconButton(
              key: const ValueKey('open-settings'),
              onPressed: onOpenSettings,
              tooltip: context.t('设置'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.settings_outlined, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          context.t('把没用的缓存，\n轻轻扫走。'),
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: 36,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          context.t(
            '先扫描预览：Safe 缓存默认勾选，Review 缓存需手动选择。\n'
            '所有内容都会先移入隔离区，随时可以撤销。',
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: controller.isBusy ? null : controller.scan,
          icon: const Icon(Icons.search_rounded, size: 20),
          label: Text(context.t('开始扫描')),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                context.t('不会触碰文档、照片、程序和系统文件'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroArtwork extends StatelessWidget {
  const _HeroArtwork();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 186,
          height: 186,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface.withValues(alpha: 0.55),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.12)),
          ),
        ),
        Container(
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary.withValues(alpha: 0.11),
          ),
        ),
        Icon(Icons.cleaning_services_rounded, size: 54, color: scheme.primary),
        Positioned(
          top: 8,
          right: 8,
          child: _FloatingTag(
            icon: Icons.folder_open_outlined,
            label: context.t('临时文件'),
          ),
        ),
        Positioned(
          bottom: 22,
          left: 0,
          child: _FloatingTag(
            icon: Icons.public_rounded,
            label: context.t('浏览器缓存'),
          ),
        ),
        Positioned(
          bottom: 4,
          right: 28,
          child: _FloatingTag(
            icon: Icons.restore_rounded,
            label: context.t('可撤销'),
          ),
        ),
      ],
    );
  }
}

class _FloatingTag extends StatelessWidget {
  const _FloatingTag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuarantineCard extends StatelessWidget {
  const _QuarantineCard({required this.controller, required this.onOpen});

  final CleanController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sessions = controller.pendingSessions.length;
    final unfinished = controller.unfinishedSessions.length;

    return Material(
      key: const ValueKey('quarantine-card'),
      color: scheme.tertiaryContainer.withValues(alpha: 0.42),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.tertiary.withValues(alpha: 0.16)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: scheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tf('隔离区暂存了 {bytes}', {
                        'bytes': formatBytes(controller.pendingBytes),
                      }),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.tf(
                        '{files} 个文件 · {sessions} 次清理{unfinished}。'
                        '磁盘空间尚未释放，恢复或永久释放后才会改变。',
                        {
                          'files': formatCount(controller.pendingFileCount),
                          'sessions': sessions,
                          'unfinished': unfinished > 0
                              ? context.tf('，其中 {count} 次未正常结束', {
                                  'count': unfinished,
                                })
                              : '',
                        },
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: onOpen, child: Text(context.t('管理'))),
            ],
          ),
        ),
      ),
    );
  }
}

class _LastScanCard extends StatelessWidget {
  const _LastScanCard({required this.controller});

  final CleanController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = controller.lastScanSummary!;
    final stale = controller.lastScanStale;

    return Material(
      key: const ValueKey('last-scan-card'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.history_rounded,
                size: 19,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          context.tf('上次扫描 · {time}', {
                            'time': formatDateTime(
                              summary.completedAt.toLocal(),
                            ),
                          }),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (stale) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.tertiaryContainer.withValues(
                              alpha: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            context.t('规则已变化'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onTertiaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    context.tf('{count} 个文件 · {bytes} · {issues} 个扫描问题', {
                      'count': formatCount(summary.foundFiles),
                      'bytes': formatBytes(summary.foundBytes),
                      'issues': formatCount(summary.issueCount),
                    }),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              key: const ValueKey('restore-last-scan'),
              onPressed: controller.restoringLastScan
                  ? null
                  : controller.restoreLastScan,
              child: controller.restoringLastScan
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.t('查看结果')),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolsSection extends StatelessWidget {
  const _ToolsSection({
    required this.onOpenRecycleBin,
    required this.onOpenDuplicateFinder,
    required this.onOpenLargeFiles,
    this.onOpenSystemCache,
  });

  final VoidCallback onOpenRecycleBin;
  final VoidCallback onOpenDuplicateFinder;
  final VoidCallback onOpenLargeFiles;
  final VoidCallback? onOpenSystemCache;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Text(context.t('分析与审阅'), style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(
              context.t('按风险等级区分'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 10.0;
            final hasSystemCache = onOpenSystemCache != null;
            final columns = constraints.maxWidth >= (hasSystemCache ? 720 : 860)
                ? (hasSystemCache ? 2 : 3)
                : 1;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                if (onOpenSystemCache != null)
                  SizedBox(
                    width: width,
                    child: _ToolCard(
                      key: const ValueKey('tool-system-cache'),
                      icon: Icons.admin_panel_settings_outlined,
                      risk: CleanRisk.review,
                      title: context.t('系统级缓存'),
                      description: context.t(
                        '清理 Windows 更新、传递优化与 Windows.old，需要管理员权限。',
                      ),
                      onTap: onOpenSystemCache!,
                    ),
                  ),
                SizedBox(
                  width: width,
                  child: _ToolCard(
                    key: const ValueKey('tool-recycle-bin'),
                    icon: Icons.delete_forever_rounded,
                    risk: CleanRisk.review,
                    title: context.t('回收站'),
                    description: context.t('查看所有磁盘的回收站占用，确认后可永久清空。'),
                    onTap: onOpenRecycleBin,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ToolCard(
                    key: const ValueKey('tool-duplicate-files'),
                    icon: Icons.content_copy_rounded,
                    risk: CleanRisk.info,
                    title: context.t('重复文件'),
                    description: context.t('按内容比对找出相同的文件，结果只读、不自动选择。'),
                    onTap: onOpenDuplicateFinder,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ToolCard(
                    key: const ValueKey('tool-large-files'),
                    icon: Icons.sd_storage_rounded,
                    risk: CleanRisk.info,
                    title: context.t('大文件分析'),
                    description: context.t('按体积从大到小列出文件，帮你定位空间去向。'),
                    onTap: onOpenLargeFiles,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    super.key,
    required this.icon,
    required this.risk,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final CleanRisk risk;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 12, 15),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        RiskBadge(risk: risk),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopeSection extends StatelessWidget {
  const _ScopeSection({
    required this.rules,
    required this.scopes,
    required this.exclusionCount,
    required this.onOpenExclusions,
    required this.isRuleEnabled,
    required this.settings,
  });

  final List<CleanerRule> rules;
  final Map<String, RuleExclusionScope> scopes;
  final int exclusionCount;
  final VoidCallback onOpenExclusions;
  final bool Function(String ruleId) isRuleEnabled;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final groups = <String, List<CleanerRule>>{};
    for (final rule in rules) {
      groups.putIfAbsent(strings.ruleCategory(rule), () => []).add(rule);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.travel_explore_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Text(context.t('本次扫描范围'), style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('open-exclusions'),
                onPressed: onOpenExclusions,
                icon: const Icon(Icons.block_rounded, size: 15),
                label: Text(
                  exclusionCount == 0
                      ? context.t('排除列表')
                      : '${context.t('排除列表')} · $exclusionCount',
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
              ),
            ],
          ),
          if (exclusionCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.t('排除优先于规则：被排除的目录及其子目录不会参与扫描。'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              context.t('勾选类别决定本次扫描范围；关闭的类别不会解析目录或访问磁盘。'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final entry in groups.entries)
            _buildCategoryRow(
              context,
              theme,
              scheme,
              strings,
              entry.key,
              entry.value,
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
    String categoryLabel,
    List<CleanerRule> categoryRules,
  ) {
    final categoryKey = ruleCategoryKey(categoryRules.first);
    final enabled = settings.isCategoryEnabled(categoryKey);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 178,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: Checkbox(
                      key: ValueKey('scan-category-$categoryKey'),
                      value: enabled,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (value) => settings.setCategoryEnabled(
                        categoryKey,
                        value ?? false,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _categoryIcon(categoryLabel),
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          categoryLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: enabled
                                ? scheme.onSurfaceVariant
                                : scheme.onSurfaceVariant.withValues(
                                    alpha: 0.55,
                                  ),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (!enabled)
                          Text(
                            context.t('本次跳过'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Opacity(
              opacity: enabled ? 1 : 0.45,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final rule in categoryRules)
                    Tooltip(
                      message: _scopeTooltip(
                        strings,
                        rule,
                        scopes[rule.id],
                        isRuleEnabled(rule.id),
                      ),
                      child: _RuleChip(
                        rule: rule,
                        scope: scopes[rule.id] ?? RuleExclusionScope.none,
                        enabled: isRuleEnabled(rule.id),
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
        ? '$description\n${strings.t('Review 级规则默认不勾选，需要在预览中手动选择。')}'
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
    final scheme = theme.colorScheme;
    final excluded = scope != RuleExclusionScope.none;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: excluded
            ? scheme.tertiaryContainer.withValues(alpha: 0.32)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(9),
        border: excluded
            ? Border.all(color: scheme.tertiary.withValues(alpha: 0.2))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _ruleIcon(rule.id),
            size: 13,
            color: excluded
                ? scheme.onTertiaryContainer
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            context.strings.ruleTitle(rule),
            style: theme.textTheme.labelSmall?.copyWith(
              color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
          if (rule.risk == CleanRisk.review) ...[
            const SizedBox(width: 6),
            Text(
              'REVIEW',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.tertiary,
                fontWeight: FontWeight.w700,
                fontSize: 9,
                letterSpacing: 0.3,
              ),
            ),
          ],
          if (excluded) ...[
            const SizedBox(width: 6),
            Text(
              scope == RuleExclusionScope.all
                  ? context.t('已排除')
                  : context.t('部分排除'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (!enabled) ...[
            const SizedBox(width: 6),
            Text(
              context.t('已关闭'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            Icons.lock_outline_rounded,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            context.t(
              '清理前先预览；清理时文件会移动到隔离区，可随时撤销。'
              '所有扫描都在本机完成，不会上传任何文件。',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
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
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: isError
            ? scheme.errorContainer.withValues(alpha: 0.65)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? scheme.error.withValues(alpha: 0.2)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isError
                ? Icons.error_outline_rounded
                : (icon ?? Icons.info_outline_rounded),
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
          ?action,
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 17),
              visualDensity: VisualDensity.compact,
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
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                        ),
                        Icon(
                          Icons.travel_explore_rounded,
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: const LinearProgressIndicator(minHeight: 7),
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
                                  Icons.insert_drive_file_outlined,
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
                  child: TextButton(
                    onPressed: controller.cancelScan,
                    child: Text(context.t('取消扫描')),
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

class _PreviewView extends StatelessWidget {
  const _PreviewView({
    required this.controller,
    required this.onCleanRequested,
  });

  final CleanController controller;
  final VoidCallback onCleanRequested;

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

    return Column(
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
          _InlineBanner(icon: Icons.save_outlined, message: notice),
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
        if (controller.lockProbeRunning)
          _InlineBanner(
            icon: Icons.lock_outline_rounded,
            message: context.tf('正在检测被占用的文件…（{checked} / {total}）', {
              'checked': formatCount(controller.lockProbeChecked),
              'total': formatCount(controller.lockProbeTotal),
            }),
          )
        else if (controller.possiblyLockedCount > 0)
          _InlineBanner(
            icon: Icons.lock_outline_rounded,
            message: context.tf('有 {count} 个文件可能正被其他程序占用，清理时会跳过并单独报告。', {
              'count': formatCount(controller.possiblyLockedCount),
            }),
          ),
        if (controller.previewReviewRuleCount > 0)
          _InlineBanner(
            icon: Icons.shield_outlined,
            message: context.tf(
              '扫描结果包含 {count} 条 Review 规则，默认未勾选。'
              '勾选后仍需额外确认；文件同样会进入隔离区并可撤销，'
              '但可能带来重新下载或首次启动变慢。',
              {'count': controller.previewReviewRuleCount},
            ),
          ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.t('扫描结果'), style: theme.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                    controller.results.isEmpty
                        ? context.t('没有发现可清理的文件')
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
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: controller.scan,
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text(context.t('重新扫描')),
            ),
          ],
        ),
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
                        Icons.check_circle_outline_rounded,
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
                      FilledButton.tonalIcon(
                        onPressed: controller.scan,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(context.t('再扫描一次')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else ...[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 6),
              children: [
                for (final group in _groupResults(
                  controller.results,
                  context.strings,
                ))
                  _ResultGroup(
                    category: group.category,
                    results: group.results,
                    controller: controller,
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
          icon: const Icon(Icons.report_problem_outlined, size: 30),
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
    ScanErrorKind.accessDenied => Icons.lock_outline_rounded,
    ScanErrorKind.pathTooLong => Icons.straighten_rounded,
    ScanErrorKind.notFound => Icons.search_off_rounded,
    ScanErrorKind.deviceNotReady => Icons.usb_off_rounded,
    ScanErrorKind.networkUnavailable => Icons.wifi_off_rounded,
    ScanErrorKind.writeProtected => Icons.lock_clock_outlined,
    ScanErrorKind.diskFull => Icons.sd_card_alert_outlined,
    ScanErrorKind.unsupported => Icons.extension_off_outlined,
    ScanErrorKind.sharingViolation => Icons.sync_problem_rounded,
    ScanErrorKind.invalidName => Icons.short_text_rounded,
    ScanErrorKind.ioError => Icons.error_outline_rounded,
    ScanErrorKind.other => Icons.help_outline_rounded,
  };
}

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({
    required this.category,
    required this.results,
    required this.controller,
  });

  final String category;
  final List<RuleResult> results;
  final CleanController controller;

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
            _RuleResultCard(result: result, controller: controller),
        ],
      ),
    );
  }
}

class _RuleResultCard extends StatelessWidget {
  const _RuleResultCard({required this.result, required this.controller});

  final RuleResult result;
  final CleanController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bool? selection = controller.ruleSelectionValue(result.rule.id);
    final selected = selection == true;
    final selectedCount = controller.selectedCountForRule(result.rule.id);
    final rule = result.rule;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 0.24
                    : 0.3,
              )
            : selection == null
            ? scheme.primaryContainer.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 0.12
                    : 0.14,
              )
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selection != false
                ? scheme.primary.withValues(alpha: 0.18)
                : scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: InkWell(
          onTap: () => controller.toggleRule(rule.id),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
            child: Row(
              children: [
                Checkbox(
                  value: selection,
                  tristate: true,
                  onChanged: (_) => controller.toggleRule(rule.id),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 2),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    _ruleIcon(rule.id),
                    size: 19,
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
                              Icons.lock_outline_rounded,
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
                        ),
                      ),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(context.t('查看')),
                      const SizedBox(width: 2),
                      const Icon(Icons.chevron_right_rounded, size: 17),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
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
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 13,
                        color: scheme.tertiary,
                      ),
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
                        Icons.shield_outlined,
                        size: 13,
                        color: scheme.tertiary,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          context.tf('已选 {count} 条 Review 规则，提交前需要额外确认', {
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
                icon: const Icon(Icons.cleaning_services_rounded, size: 18),
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
                      Icons.cleaning_services_rounded,
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 8,
                    backgroundColor: scheme.surfaceContainerHighest,
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
                          Icons.insert_drive_file_outlined,
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
                  child: OutlinedButton.icon(
                    onPressed: controller.cleanCancelRequested
                        ? null
                        : controller.cancelCleaning,
                    icon: const Icon(Icons.stop_circle_outlined, size: 17),
                    label: Text(
                      controller.cleanCancelRequested
                          ? context.t('正在停止…')
                          : context.t('停止清理'),
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
                          : scheme.primaryContainer.withValues(alpha: 0.55),
                    ),
                    child: Icon(
                      report.cancelled
                          ? Icons.pause_rounded
                          : Icons.check_rounded,
                      size: 36,
                      color: report.cancelled
                          ? scheme.onTertiaryContainer
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
                              Icons.lock_outline_rounded,
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
                              Icons.warning_amber_rounded,
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
                            ? const Icon(
                                Icons.play_circle_outline_rounded,
                                size: 18,
                              )
                            : const Icon(Icons.inventory_2_outlined, size: 18),
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
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: Text(context.t('撤销本次清理')),
                      ),
                    FilledButton.icon(
                      onPressed: controller.returnHome,
                      icon: const Icon(Icons.home_outlined, size: 18),
                      label: Text(context.t('返回首页')),
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.035),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
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
        report.sessionRemoved
            ? Icons.restore_rounded
            : Icons.info_outline_rounded,
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
  if (category.contains('浏览器') || lower.contains('browser')) {
    return Icons.public_rounded;
  }
  if (category.contains('日志') || lower.contains('log')) {
    return Icons.receipt_long_outlined;
  }
  if (category.contains('缩略图') || lower.contains('thumbnail')) {
    return Icons.image_outlined;
  }
  if (category.contains('GPU') || lower.contains('graphics')) {
    return Icons.memory_rounded;
  }
  if (category.contains('应用') || lower.contains('app cache')) {
    return Icons.apps_rounded;
  }
  if (category.contains('开发') || lower.contains('developer')) {
    return Icons.code_rounded;
  }
  return Icons.folder_outlined;
}

IconData _ruleIcon(String ruleId) {
  if (ruleId.startsWith('browser')) return Icons.public_rounded;
  if (ruleId.startsWith('dev')) return Icons.terminal_rounded;
  if (ruleId.startsWith('app')) return Icons.apps_rounded;
  if (ruleId.startsWith('gpu')) return Icons.memory_rounded;
  if (ruleId.startsWith('logs')) return Icons.receipt_long_outlined;
  return switch (ruleId) {
    'windows.user_temp' => Icons.folder_open_outlined,
    'windows.crash_dumps' => Icons.bug_report_outlined,
    'windows.wer_reports' => Icons.error_outline_rounded,
    'windows.thumbnail_icon_cache' => Icons.image_outlined,
    _ => Icons.delete_outline_rounded,
  };
}
