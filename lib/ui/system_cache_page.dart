import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/models/clean_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/system_models.dart';
import '../l10n/broom_strings.dart';
import '../platform/window_chrome.dart';
import 'analysis_widgets.dart';
import 'format.dart';
import 'glass_ui.dart';
import 'system_cache_confirm_dialog.dart';
import 'system_cache_controller.dart';

class SystemCachePage extends StatefulWidget {
  const SystemCachePage({super.key, required this.controller});

  final SystemCacheController controller;

  @override
  State<SystemCachePage> createState() => _SystemCachePageState();
}

class _SystemCachePageState extends State<SystemCachePage> {
  SystemCacheController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(controller.checkAccess());
  }

  Future<void> _elevate() async {
    final launched = await controller.relaunchElevated();
    if (!launched || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.t('已启动管理员窗口，正在切换…'))));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    await WindowChrome.instance.close();
  }

  Future<void> _confirmClean() async {
    if (controller.selectedCount == 0) return;
    final confirmed = await showSystemCacheConfirmDialog(
      context,
      fileCount: controller.selectedCount,
      bytes: controller.selectedBytes,
      services: controller.selectedServices,
      includesWindowsOld: controller.selectedResults.any(
        (result) => result.rule.location == SystemCacheLocation.windowsOld,
      ),
    );
    if (confirmed && mounted) {
      await controller.cleanSelected();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: context.t('返回'),
            ),
            toolbarHeight: 76,
            title: Text(context.t('系统级缓存')),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (controller.isElevated) ...[
                      const _AdminChip(),
                      const SizedBox(width: 8),
                    ],
                    const RiskBadge(risk: CleanRisk.review),
                  ],
                ),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: _buildBody(context),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    if (controller.checkingAccess) {
      return const _AccessLoading();
    }
    if (!controller.isElevated) {
      return _AdminGate(controller: controller, onElevate: _elevate);
    }

    return switch (controller.phase) {
      SystemCachePhase.idle => _IdleView(
        controller: controller,
        onScan: controller.scan,
      ),
      SystemCachePhase.scanning => _ScanningView(controller: controller),
      SystemCachePhase.preview => _PreviewView(
        controller: controller,
        onCleanRequested: _confirmClean,
      ),
      SystemCachePhase.cleaning => _CleaningView(controller: controller),
      SystemCachePhase.done => _DoneView(controller: controller),
    };
  }
}

class _AccessLoading extends StatelessWidget {
  const _AccessLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            context.t('正在检查管理员权限…'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminGate extends StatelessWidget {
  const _AdminGate({required this.controller, required this.onElevate});

  final SystemCacheController controller;
  final Future<void> Function() onElevate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        if (controller.error case final error?) ...[
          AnalysisBanner(
            message: error,
            isError: true,
            onClose: controller.clearError,
          ),
          const SizedBox(height: 10),
        ],
        if (controller.notice case final notice?) ...[
          AnalysisBanner(message: notice, onClose: controller.clearNotice),
          const SizedBox(height: 10),
        ],
        const _ReviewWarning(),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const IconTile(
                    icon: LucideIcons.database,
                    size: 42,
                    color: BroomColors.amber,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.t('需要管理员权限'),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.t(
                            '系统级缓存位于受保护的系统位置。Broom 会通过 Windows UAC '
                            '以管理员身份重新启动，只在新的管理员窗口中进行扫描和清理。',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BroomColors.inkMuted(context),
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (controller.accessError case final accessError?) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: scheme.error.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Text(
                    accessError,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: controller.relaunching ? null : onElevate,
                    icon: controller.relaunching
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.shieldCheck, size: 17),
                    label: Text(
                      controller.relaunching
                          ? context.t('正在请求授权…')
                          : context.t('以管理员身份重新启动'),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.relaunching
                        ? null
                        : controller.checkAccess,
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
                    label: Text(context.t('重新检测')),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      context.t('重启后不会自动扫描或删除任何内容。'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: BroomColors.inkFaint(context),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _RuleOverview(rules: controller.platform.rules),
        const SizedBox(height: 12),
        const _BoundaryNote(),
      ],
    );
  }
}

class _AdminChip extends StatelessWidget {
  const _AdminChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.shieldCheck,
            size: 12,
            color: scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            context.t('管理员'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewWarning extends StatelessWidget {
  const _ReviewWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              LucideIcons.triangleAlert,
              size: 15,
              color: BroomColors.warning,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.t(
                '系统级缓存不会经过隔离区，也没有撤销入口；Windows.old 还会失去系统回滚能力。'
                '如正在安装 Windows 更新，建议完成后再清理。',
              ),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.inkMuted(context),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleOverview extends StatelessWidget {
  const _RuleOverview({required this.rules});

  final List<SystemCacheRule> rules;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.folderOpen,
                size: 15,
                color: BroomColors.inkMuted(context),
              ),
              const SizedBox(width: 7),
              Text(context.t('可清理的系统缓存'), style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(
                context.tf('{count} 项', {'count': rules.length}),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: BroomColors.inkFaint(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var index = 0; index < rules.length; index++) ...[
            if (index > 0) const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      _ruleIcon(rules[index].id),
                      size: 15,
                      color: BroomColors.inkMuted(context),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.strings.systemRuleTitle(rules[index]),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: BroomColors.ink(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.strings.systemRuleDescription(rules[index]),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: BroomColors.inkMuted(context),
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BoundaryNote extends StatelessWidget {
  const _BoundaryNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              LucideIcons.shieldCheck,
              size: 13,
              color: BroomColors.inkFaint(context),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              context.t(
                'Broom 只通过 Windows 原生 API 定位缓存目录，不接受任意路径输入，'
                '只处理这些目录内的普通文件；当前系统、更新历史与系统还原点不在处理范围内。',
              ),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.inkFaint(context),
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView({required this.controller, required this.onScan});

  final SystemCacheController controller;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        if (controller.error case final error?) ...[
          AnalysisBanner(
            message: error,
            isError: true,
            onClose: controller.clearError,
          ),
          const SizedBox(height: 12),
        ],
        if (controller.notice case final notice?) ...[
          AnalysisBanner(message: notice, onClose: controller.clearNotice),
          const SizedBox(height: 12),
        ],
        const _ReviewWarning(),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(26, 26, 26, 24),
          decoration: BoxDecoration(
            color: BroomColors.card(context),
            borderRadius: BorderRadius.circular(28),
            boxShadow: BroomColors.cardShadow(context),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      LucideIcons.database,
                      size: 23,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.t('系统级缓存'),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.t(
                            '扫描 Windows 更新、传递优化缓存与 Windows.old，'
                            '确认后永久删除以释放磁盘空间。',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              for (final rule in controller.platform.rules) ...[
                _SystemRuleCard(rule: rule),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: controller.isBusy ? null : onScan,
                icon: const Icon(LucideIcons.search, size: 19),
                label: Text(context.t('扫描系统缓存')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _BoundaryNote(),
      ],
    );
  }
}

class _SystemRuleCard extends StatelessWidget {
  const _SystemRuleCard({
    required this.rule,
    this.result,
    this.lockedCount = 0,
    this.selected = false,
    this.onToggle,
  });

  final SystemCacheRule rule;
  final SystemRuleResult? result;
  final int lockedCount;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectable = onToggle != null;

    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.24 : 0.3,
            )
          : BroomColors.block(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 13, 14, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectable)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onToggle?.call(),
                  visualDensity: VisualDensity.compact,
                ),
              Container(
                margin: const EdgeInsets.only(top: 2, right: 12),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            context.strings.systemRuleTitle(rule),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (result != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            formatBytes(result!.totalBytes),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.strings.systemRuleCategory(rule),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      result == null
                          ? context.strings.systemRuleDescription(rule)
                          : context.tf('{count} 个文件 · {description}', {
                              'count': formatCount(result!.items.length),
                              'description': context.strings
                                  .systemRuleDescription(rule),
                            }),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 7),
                    _PathLine(
                      path: result != null && result!.roots.isNotEmpty
                          ? result!.roots.join(' · ')
                          : rule.displayPath,
                    ),
                    if (context.strings.systemRuleNote(rule)
                        case final note?) ...[
                      const SizedBox(height: 5),
                      Text(
                        note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.85,
                          ),
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (lockedCount > 0) ...[
                      const SizedBox(height: 5),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _PathLine extends StatelessWidget {
  const _PathLine({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        Icon(
          LucideIcons.folder,
          size: 13,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Tooltip(
            message: path,
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                fontFamily: 'Consolas',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScanningView extends StatelessWidget {
  const _ScanningView({required this.controller});

  final SystemCacheController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.scanProgress;
    final ruleId = progress?.ruleId;
    final scanningRule = ruleId == null
        ? null
        : controller.platform.rules
              .where((rule) => rule.id == ruleId)
              .firstOrNull;
    final scanningTitle = scanningRule == null
        ? null
        : context.strings.systemRuleTitle(scanningRule);
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        AnalysisProgressCard(
          icon: LucideIcons.database,
          title: context.t('正在扫描系统缓存'),
          description: scanningTitle == null
              ? context.t('正在准备系统缓存目录…')
              : context.tf('正在读取 {name}…', {'name': scanningTitle}),
          stats: [
            AnalysisProgressStat(
              label: context.t('已检查文件'),
              value: formatCount(progress?.scannedFiles ?? 0),
            ),
            AnalysisProgressStat(
              label: context.t('发现文件'),
              value: formatCount(progress?.foundFiles ?? 0),
            ),
            AnalysisProgressStat(
              label: context.t('已找到'),
              value: formatBytes(progress?.foundBytes ?? 0),
            ),
          ],
          onCancel: controller.cancelScan,
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

  final SystemCacheController controller;
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
            children: [
              if (controller.error case final error?) ...[
                AnalysisBanner(
                  message: error,
                  isError: true,
                  onClose: controller.clearError,
                ),
                const SizedBox(height: 12),
              ],
              if (controller.notice case final notice?) ...[
                AnalysisBanner(
                  message: notice,
                  onClose: controller.clearNotice,
                ),
                const SizedBox(height: 12),
              ],
              if (controller.scanDirectoryErrors > 0) ...[
                AnalysisBanner(
                  message: context.tf('有 {count} 个目录无法读取，已自动跳过。', {
                    'count': controller.scanDirectoryErrors,
                  }),
                ),
                const SizedBox(height: 12),
              ],
              if (controller.scanTruncated) ...[
                AnalysisBanner(
                  message: context.t('文件数量超过单次扫描上限，预览与清理仅包含已找到的部分。'),
                ),
                const SizedBox(height: 12),
              ],
              if (controller.lockProbeRunning) ...[
                AnalysisBanner(
                  message: context.tf('正在检测被占用的文件…（{checked} / {total}）', {
                    'checked': formatCount(controller.lockProbeChecked),
                    'total': formatCount(controller.lockProbeTotal),
                  }),
                ),
                const SizedBox(height: 12),
              ] else if (controller.results.any(
                (result) =>
                    controller.possiblyLockedCountForRule(result.rule.id) > 0,
              )) ...[
                AnalysisBanner(
                  message: context.tf('有 {count} 个文件可能正被其他程序占用，清理时会跳过并单独报告。', {
                    'count': formatCount(
                      controller.results.fold<int>(
                        0,
                        (total, result) =>
                            total +
                            controller.possiblyLockedCountForRule(
                              result.rule.id,
                            ),
                      ),
                    ),
                  }),
                ),
                const SizedBox(height: 12),
              ],
              const _ReviewWarning(),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
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
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.t('扫描结果'),
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                controller.results.isEmpty
                                    ? context.t('没有发现可清理的系统缓存')
                                    : context.tf(
                                        '发现 {count} 个文件 · {bytes}。'
                                        '默认不勾选，请选择要永久删除的内容。',
                                        {
                                          'count': formatCount(totalItems),
                                          'bytes': formatBytes(totalBytes),
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
                        OutlinedButton.icon(
                          onPressed: controller.scan,
                          icon: const Icon(LucideIcons.refreshCw, size: 17),
                          label: Text(context.t('重新扫描')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (controller.results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 26),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                LucideIcons.circleCheck,
                                size: 40,
                                color: scheme.primary,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                context.t('系统缓存看起来很干净'),
                                style: theme.textTheme.titleSmall,
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      for (final result in controller.results)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _SystemRuleCard(
                            rule: result.rule,
                            result: result,
                            lockedCount: controller.possiblyLockedCountForRule(
                              result.rule.id,
                            ),
                            selected: controller.isRuleSelected(result.rule.id),
                            onToggle: () =>
                                controller.toggleRule(result.rule.id),
                          ),
                        ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _BoundaryNote(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 28, 28),
          child: _ActionBar(
            controller: controller,
            allSelected: allSelected,
            onCleanRequested: onCleanRequested,
          ),
        ),
      ],
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.controller,
    required this.allSelected,
    required this.onCleanRequested,
  });

  final SystemCacheController controller;
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
                  context.tf('将永久删除 {bytes}', {
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
              ],
            ),
          ),
          TextButton(
            onPressed: allSelected
                ? controller.clearRuleSelection
                : controller.selectAllRules,
            child: Text(allSelected ? context.t('取消全选') : context.t('全选')),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: controller.selectedCount == 0 ? null : onCleanRequested,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              disabledBackgroundColor: scheme.error.withValues(alpha: 0.12),
            ),
            icon: const Icon(LucideIcons.trash2, size: 18),
            label: Text(
              context.tf('永久删除 {count} 项', {
                'count': formatCount(controller.selectedCount),
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _CleaningView extends StatelessWidget {
  const _CleaningView({required this.controller});

  final SystemCacheController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = controller.cleanProgress;
    final stage = controller.cleanStage;
    final total = progress?.total ?? 0;
    final processed = progress?.processed ?? 0;
    final stageLabel = switch (stage) {
      SystemCleanStage.stoppingServices => context.t('正在临时停止 Windows 服务…'),
      SystemCleanStage.restartingServices => context.t('正在恢复 Windows 服务…'),
      SystemCleanStage.deleting => context.t('正在永久删除系统缓存…'),
      null => context.t('正在清理系统缓存…'),
    };
    final description = switch (stage) {
      SystemCleanStage.stoppingServices => context.t(
        '停止 Windows Update、BITS 或传递优化服务，避免缓存文件被占用。',
      ),
      SystemCleanStage.restartingServices => context.t('删除已完成，正在把刚才停止的服务恢复运行。'),
      SystemCleanStage.deleting => context.t('删除的系统缓存不会进入隔离区，也无法撤销。'),
      null => context.t('请稍候…'),
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        AnalysisProgressCard(
          icon: LucideIcons.trash2,
          title: controller.cleanCancelRequested
              ? context.t('正在停止清理…')
              : stageLabel,
          description: description,
          progress: stage == SystemCleanStage.deleting && total > 0
              ? processed / total
              : null,
          stats: [
            AnalysisProgressStat(
              label: context.t('已处理'),
              value: '$processed / $total',
            ),
            AnalysisProgressStat(
              label: context.t('已删除文件'),
              value: formatCount(progress?.deleted ?? 0),
            ),
            AnalysisProgressStat(
              label: context.t('已释放'),
              value: formatBytes(progress?.deletedBytes ?? 0),
            ),
          ],
          currentPath: progress?.currentPath,
          onCancel: stage == SystemCleanStage.deleting
              ? controller.cancelCleaning
              : null,
          cancelRequested: controller.cleanCancelRequested,
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer.withValues(alpha: 0.32),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.tertiary.withValues(alpha: 0.14)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.info,
                size: 18,
                color: scheme.onTertiaryContainer,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  context.t(
                    '请保持此窗口打开，直到服务恢复完成。'
                    '即使中止清理，Broom 也会尝试重新启动刚才停止的服务。',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onTertiaryContainer,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DoneView extends StatelessWidget {
  const _DoneView({required this.controller});

  final SystemCacheController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = controller.lastReport;
    if (report == null) return const SizedBox.shrink();

    final title = report.cancelled
        ? context.t('清理已停止')
        : report.deletedCount == 0
        ? context.t('没有文件被删除')
        : context.t('清理完成');

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(30, 30, 30, 24),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: report.cancelled
                        ? scheme.tertiaryContainer.withValues(alpha: 0.5)
                        : scheme.primaryContainer.withValues(alpha: 0.55),
                  ),
                  child: Icon(
                    report.cancelled ? LucideIcons.pause : LucideIcons.check,
                    size: 34,
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
                    ? context.t('已停止继续删除，相关 Windows 服务已尝试恢复运行。')
                    : context.t('系统缓存已永久删除，不会进入隔离区。'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _DoneStat(
                        label: context.t('已释放'),
                        value: formatBytes(report.deletedBytes),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 34,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    Expanded(
                      child: _DoneStat(
                        label: context.t('永久删除'),
                        value: context.tf('{count} 个文件', {
                          'count': formatCount(report.deletedCount),
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              if (report.skippedCount > 0) ...[
                const SizedBox(height: 14),
                _IssuePanel(
                  icon: LucideIcons.lock,
                  title: context.tf('{count} 个文件已跳过', {
                    'count': report.skippedCount,
                  }),
                  body: context.t('这些文件可能正被系统占用，或已不存在。它们保留在原处，没有被修改。'),
                  failures: report.skips,
                  isServiceIssue: false,
                ),
              ],
              if (report.failureCount > 0) ...[
                const SizedBox(height: 14),
                _IssuePanel(
                  icon: LucideIcons.triangleAlert,
                  title: context.tf('{count} 个文件删除失败', {
                    'count': report.failureCount,
                  }),
                  body: context.t('请检查访问权限、磁盘状态或服务占用情况后重试。'),
                  failures: report.failures,
                  isServiceIssue: false,
                ),
              ],
              if (report.serviceIssues.isNotEmpty) ...[
                const SizedBox(height: 14),
                _IssuePanel(
                  icon: LucideIcons.fileLock2,
                  title: context.t('部分 Windows 服务未能恢复'),
                  body: context.t('请手动启动对应服务，或重启 Windows 以恢复。问题详情：'),
                  failures: [
                    for (final issue in report.serviceIssues)
                      CleanFailure(
                        path: context.t('Windows 服务'),
                        reason: issue,
                      ),
                  ],
                  isServiceIssue: true,
                ),
              ],
              const SizedBox(height: 22),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.scan,
                    icon: const Icon(LucideIcons.refreshCw, size: 17),
                    label: Text(context.t('重新扫描')),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      controller.returnToIdle();
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(LucideIcons.arrowLeft, size: 18),
                    label: Text(context.t('返回首页')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IssuePanel extends StatelessWidget {
  const _IssuePanel({
    required this.icon,
    required this.title,
    required this.body,
    required this.failures,
    required this.isServiceIssue,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<CleanFailure> failures;
  final bool isServiceIssue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: scheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onTertiaryContainer.withValues(alpha: 0.9),
              height: 1.5,
            ),
          ),
          for (final failure in failures.take(3)) ...[
            const SizedBox(height: 5),
            Text(
              isServiceIssue
                  ? '• ${failure.reason}'
                  : '• ${fileNameOf(failure.path)}${context.t('：')}${failure.reason}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onTertiaryContainer.withValues(alpha: 0.85),
              ),
            ),
          ],
          if (failures.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                context.tf('还有 {count} 条未显示…', {'count': failures.length - 3}),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onTertiaryContainer.withValues(alpha: 0.75),
                ),
              ),
            ),
        ],
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

IconData _ruleIcon(String ruleId) {
  return switch (ruleId) {
    'windows.update_cache' => LucideIcons.download,
    'windows.delivery_optimization' => LucideIcons.network,
    'windows.old' => LucideIcons.history,
    _ => LucideIcons.database,
  };
}
