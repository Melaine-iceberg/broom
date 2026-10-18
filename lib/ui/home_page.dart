import 'package:flutter/material.dart';

import '../core/analysis/analysis_service.dart';
import '../core/models/clean_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/shell/system_shell.dart';
import 'analysis_widgets.dart';
import 'clean_controller.dart';
import 'duplicate_finder_page.dart';
import 'exclusions_page.dart';
import 'format.dart';
import 'large_files_page.dart';
import 'quarantine_page.dart';
import 'recycle_bin_page.dart';
import 'rule_detail_page.dart';
import 'system_cache_controller.dart';
import 'system_cache_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.shell,
    required this.analysisRunnerFactory,
    this.systemCacheController,
    this.analysisInitialDirectory,
    this.analysisExcludedPaths = const [],
    this.startInSystemCache = false,
  });

  final CleanController controller;
  final SystemShell shell;
  final SystemCacheController? systemCacheController;
  final AnalysisRunner Function() analysisRunnerFactory;
  final String? analysisInitialDirectory;
  final List<String> analysisExcludedPaths;
  final bool startInSystemCache;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CleanController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.startInSystemCache && widget.systemCacheController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openSystemCache();
      });
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.cleaning_services_rounded, size: 30),
          title: const Text('移入隔离区？'),
          content: Text(
            '将暂存 $count 个文件，共 ${formatBytes(bytes)}。\n\n'
            '文件会先移动到 Broom 的隔离区，磁盘空间不会立即释放。'
            '你可以随时恢复，或在隔离区中永久释放。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('暂存 $count 项'),
            ),
          ],
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
      builder: (_) => const _BusyDialog(message: '正在恢复文件…'),
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
          title: const Text('撤销失败'),
          content: Text('$failure'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
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
        builder: (_) =>
            QuarantinePage(service: controller.quarantine, shell: widget.shell),
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
}

class _IdleView extends StatelessWidget {
  const _IdleView({
    required this.controller,
    required this.onOpenQuarantine,
    required this.onOpenRecycleBin,
    required this.onOpenDuplicateFinder,
    required this.onOpenLargeFiles,
    required this.onOpenExclusions,
    this.onOpenSystemCache,
  });

  final CleanController controller;
  final VoidCallback onOpenQuarantine;
  final VoidCallback onOpenRecycleBin;
  final VoidCallback onOpenDuplicateFinder;
  final VoidCallback onOpenLargeFiles;
  final VoidCallback onOpenExclusions;
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
        _Hero(controller: controller),
        if (controller.pendingSessions.isNotEmpty) ...[
          const SizedBox(height: 14),
          _QuarantineCard(controller: controller, onOpen: onOpenQuarantine),
        ],
        const SizedBox(height: 20),
        _ToolsSection(
          onOpenSystemCache: onOpenSystemCache,
          onOpenRecycleBin: onOpenRecycleBin,
          onOpenDuplicateFinder: onOpenDuplicateFinder,
          onOpenLargeFiles: onOpenLargeFiles,
        ),
        const SizedBox(height: 22),
        _ScopeSection(
          rules: controller.platform.rules,
          scopes: controller.ruleExclusionScopes,
          exclusionCount: controller.exclusionCount,
          onOpenExclusions: onOpenExclusions,
        ),
        const SizedBox(height: 14),
        const _SafetyNote(),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.controller});

  final CleanController controller;

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
          final copy = _HeroCopy(controller: controller);
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
  const _HeroCopy({required this.controller});

  final CleanController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.monitor_outlined,
              size: 14,
              color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Text(
              'WINDOWS · SAFE 级清理',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '把没用的缓存，\n轻轻扫走。',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: 36,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '先扫描预览，再把 Safe 级缓存移入隔离区。\n随时可以撤销，不用担心误删。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: controller.isBusy ? null : controller.scan,
          icon: const Icon(Icons.search_rounded, size: 20),
          label: const Text('开始扫描'),
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
                '不会触碰文档、照片、程序和系统文件',
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
          child: _FloatingTag(icon: Icons.folder_open_outlined, label: '临时文件'),
        ),
        Positioned(
          bottom: 22,
          left: 0,
          child: _FloatingTag(icon: Icons.public_rounded, label: '浏览器缓存'),
        ),
        Positioned(
          bottom: 4,
          right: 28,
          child: _FloatingTag(icon: Icons.restore_rounded, label: '可撤销'),
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
                      '隔离区暂存了 ${formatBytes(controller.pendingBytes)}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatCount(controller.pendingFileCount)} 个文件 · '
                      '$sessions 次清理。磁盘空间尚未释放，'
                      '恢复或永久释放后才会改变。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: onOpen, child: const Text('管理')),
            ],
          ),
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
            Text('分析与审阅', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(
              '按风险等级区分',
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
                      title: '系统级缓存',
                      description: '清理 Windows 更新与传递优化的下载缓存，需要管理员权限。',
                      onTap: onOpenSystemCache!,
                    ),
                  ),
                SizedBox(
                  width: width,
                  child: _ToolCard(
                    key: const ValueKey('tool-recycle-bin'),
                    icon: Icons.delete_forever_rounded,
                    risk: CleanRisk.review,
                    title: '回收站',
                    description: '查看所有磁盘的回收站占用，确认后可永久清空。',
                    onTap: onOpenRecycleBin,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ToolCard(
                    key: const ValueKey('tool-duplicate-files'),
                    icon: Icons.content_copy_rounded,
                    risk: CleanRisk.info,
                    title: '重复文件',
                    description: '按内容比对找出相同的文件，结果只读、不自动选择。',
                    onTap: onOpenDuplicateFinder,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ToolCard(
                    key: const ValueKey('tool-large-files'),
                    icon: Icons.sd_storage_rounded,
                    risk: CleanRisk.info,
                    title: '大文件分析',
                    description: '按体积从大到小列出文件，帮你定位空间去向。',
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
  });

  final List<CleanerRule> rules;
  final Map<String, RuleExclusionScope> scopes;
  final int exclusionCount;
  final VoidCallback onOpenExclusions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = <String, List<CleanerRule>>{};
    for (final rule in rules) {
      groups.putIfAbsent(rule.category, () => []).add(rule);
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
              Text('本次扫描范围', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('open-exclusions'),
                onPressed: onOpenExclusions,
                icon: const Icon(Icons.block_rounded, size: 15),
                label: Text(
                  exclusionCount == 0 ? '排除列表' : '排除列表 · $exclusionCount',
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
                      '排除优先于规则：被排除的目录及其子目录不会参与扫描。',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (final entry in groups.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Row(
                        children: [
                          Icon(
                            _categoryIcon(entry.key),
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              entry.key,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final rule in entry.value)
                          Tooltip(
                            message: _scopeTooltip(rule, scopes[rule.id]),
                            child: _RuleChip(
                              rule: rule,
                              scope: scopes[rule.id] ?? RuleExclusionScope.none,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _scopeTooltip(CleanerRule rule, RuleExclusionScope? scope) {
    return switch (scope) {
      RuleExclusionScope.all => '${rule.description}\n此规则的所有目录都在排除列表中。',
      RuleExclusionScope.partial => '${rule.description}\n此规则的部分目录已被排除。',
      _ => rule.description,
    };
  }
}

class _RuleChip extends StatelessWidget {
  const _RuleChip({required this.rule, required this.scope});

  final CleanerRule rule;
  final RuleExclusionScope scope;

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
            rule.title,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface,
            ),
          ),
          if (excluded) ...[
            const SizedBox(width: 6),
            Text(
              scope == RuleExclusionScope.all ? '已排除' : '部分排除',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onTertiaryContainer,
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
            '清理前先预览；清理时文件会移动到隔离区，可随时撤销。'
            '所有扫描都在本机完成，不会上传任何文件。',
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
    this.onClose,
  });

  final String message;
  final bool isError;
  final VoidCallback? onClose;

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
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
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
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 17),
              visualDensity: VisualDensity.compact,
              tooltip: '关闭',
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
                  '正在扫描',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  controller.scanningRuleTitle ?? '正在准备扫描目录…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (progress != null && progress.jobCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '第 ${progress.jobIndex + 1} / ${progress.jobCount} 组',
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
                        label: '已检查',
                        value: formatCount(progress?.scannedFiles ?? 0),
                      ),
                    ),
                    _statDivider(scheme),
                    Expanded(
                      child: _ProgressStat(
                        label: '发现文件',
                        value: formatCount(progress?.foundFiles ?? 0),
                      ),
                    ),
                    _statDivider(scheme),
                    Expanded(
                      child: _ProgressStat(
                        label: '已找到',
                        value: formatBytes(progress?.foundBytes ?? 0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Center(
                  child: TextButton(
                    onPressed: controller.cancelScan,
                    child: const Text('取消扫描'),
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
    final allSelected =
        controller.results.isNotEmpty &&
        controller.results.every(
          (result) => controller.isRuleSelected(result.rule.id),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.error case final error?)
          _InlineBanner(
            message: error,
            isError: true,
            onClose: controller.clearError,
          ),
        if (controller.scanDirectoryErrors > 0)
          _InlineBanner(
            message: '有 ${controller.scanDirectoryErrors} 个目录无法读取，已自动跳过。',
          ),
        if (controller.scanTruncated)
          _InlineBanner(message: '文件数量超过单次扫描上限，预览与清理仅包含已找到的部分。'),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('扫描结果', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                    controller.results.isEmpty
                        ? '没有发现可清理的文件'
                        : '发现 ${formatCount(totalItems)} 个文件 · '
                              '${formatBytes(totalBytes)}，请选择要清理的内容。',
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
              label: const Text('重新扫描'),
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
                      Text('没有发现可清理的内容', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(
                        '系统看起来很干净。关闭正在使用的浏览器或开发工具后，可以再扫描一次。',
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
                        label: const Text('再扫描一次'),
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
                for (final group in _groupResults(controller.results))
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
                  '${formatCount(itemCount)} 个文件 · ${formatBytes(bytes)}',
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
    final selected = controller.isRuleSelected(result.rule.id);
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
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected
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
                  value: selected,
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
                              rule.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
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
                        '${formatCount(result.items.length)} 个文件 · '
                        '${rule.description}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      if (rule.note case final note?) ...[
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
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RuleDetailPage(
                          rule: rule,
                          items: result.items,
                          totalBytes: result.totalBytes,
                        ),
                      ),
                    );
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('查看'),
                      SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded, size: 17),
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
                  '已选择 ${formatCount(controller.selectedCount)} 项',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '预计暂存 ${formatBytes(controller.selectedBytes)}，'
                  '释放隔离区后才会回收磁盘空间',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: allSelected
                ? controller.clearRuleSelection
                : controller.selectAllRules,
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: controller.selectedCount == 0 ? null : onCleanRequested,
            icon: const Icon(Icons.cleaning_services_rounded, size: 18),
            label: Text('清理 ${formatCount(controller.selectedCount)} 项'),
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
                  controller.cleanCancelRequested ? '正在停止清理…' : '正在移入隔离区',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  '文件会保存在隔离区，完成后可以撤销。',
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
                      '$processed / $total 项',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '已移动 ${formatCount(progress?.moved ?? 0)} 项 · '
                      '${formatBytes(progress?.movedBytes ?? 0)}',
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
                      controller.cleanCancelRequested ? '正在停止…' : '停止清理',
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
        ? '清理已停止'
        : noMoves
        ? '没有文件被移动'
        : '清理完成';

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
                      ? '已停止清理，已经移动的文件仍保存在隔离区中。'
                      : noMoves
                      ? '没有文件成功移入隔离区，可以稍后重试。'
                      : '文件已安全移动到隔离区，可随时恢复。'
                            '释放隔离区后才会回收磁盘空间。',
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
                          label: '已暂存',
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
                          label: '移入隔离区',
                          value: '${formatCount(report.movedCount)} 个文件',
                        ),
                      ),
                    ],
                  ),
                ),
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
                                '${report.failureCount} 个文件未能清理，'
                                '可能被程序占用，或已被加入排除列表。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
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
                              '还有 ${report.failures.length - 3} 条未显示…',
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
                    if (!noMoves)
                      OutlinedButton.icon(
                        onPressed: onOpenQuarantine,
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: const Text('管理隔离区'),
                      ),
                    if (controller.canUndoLastReport)
                      OutlinedButton.icon(
                        onPressed: controller.undoBusy
                            ? null
                            : () => onUndo(report.sessionId!),
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: const Text('撤销本次清理'),
                      ),
                    FilledButton.icon(
                      onPressed: controller.returnHome,
                      icon: const Icon(Icons.home_outlined, size: 18),
                      label: const Text('返回首页'),
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
    final title = report.sessionRemoved ? '撤销完成' : '部分文件已恢复';

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
            '已恢复 ${report.restoredCount} 个文件'
            '（${formatBytes(report.restoredBytes)}）。',
          ),
          if (report.conflictCount > 0) ...[
            const SizedBox(height: 8),
            Text('${report.conflictCount} 个文件的原位置已有新文件，已跳过，不会覆盖。'),
          ],
          if (report.failureCount > 0) ...[
            const SizedBox(height: 8),
            Text('${report.failureCount} 个文件恢复失败。'),
          ],
          if (!report.sessionRemoved) ...[
            const SizedBox(height: 10),
            Text(
              '未能恢复的文件仍保留在隔离区中。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}

List<({String category, List<RuleResult> results})> _groupResults(
  List<RuleResult> results,
) {
  final groups = <String, List<RuleResult>>{};
  for (final result in results) {
    groups.putIfAbsent(result.rule.category, () => []).add(result);
  }
  return [
    for (final entry in groups.entries)
      (category: entry.key, results: entry.value),
  ];
}

IconData _categoryIcon(String category) {
  if (category.contains('浏览器')) return Icons.public_rounded;
  if (category.contains('开发')) return Icons.code_rounded;
  return Icons.memory_rounded;
}

IconData _ruleIcon(String ruleId) {
  if (ruleId.startsWith('browser')) return Icons.public_rounded;
  if (ruleId.startsWith('dev')) return Icons.terminal_rounded;
  return switch (ruleId) {
    'windows.user_temp' => Icons.folder_open_outlined,
    'windows.crash_dumps' => Icons.bug_report_outlined,
    'windows.wer_reports' => Icons.error_outline_rounded,
    _ => Icons.delete_outline_rounded,
  };
}
