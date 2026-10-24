import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/models/cleaner_rule.dart';
import '../core/platform/linux_system_maintenance.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'format.dart';
import 'glass_ui.dart';
import 'linux_system_cache_confirm_dialog.dart';
import 'linux_system_cache_controller.dart';
import 'linux_system_operation_ui.dart';

class LinuxSystemCachePage extends StatefulWidget {
  const LinuxSystemCachePage({super.key, required this.controller});

  final LinuxSystemCacheController controller;

  @override
  State<LinuxSystemCachePage> createState() => _LinuxSystemCachePageState();
}

class _LinuxSystemCachePageState extends State<LinuxSystemCachePage> {
  LinuxSystemCacheController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(controller.probe());
  }

  Future<void> _confirmClean() async {
    final operations = controller.selectedOperations;
    if (operations.isEmpty) return;
    final confirmed = await showLinuxSystemCacheConfirmDialog(
      context,
      operations: operations,
    );
    if (!confirmed || !mounted) return;
    await controller.cleanSelected();
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
            actions: const [
              Padding(
                padding: EdgeInsets.only(right: 20),
                child: RiskBadge(risk: CleanRisk.review),
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
    if (controller.probing || !controller.probed) {
      return const _ProbeView();
    }
    final availability = controller.availability;
    if (availability == null || !availability.isAvailable) {
      return _UnavailableView(controller: controller);
    }
    return switch (controller.phase) {
      LinuxSystemCachePhase.cleaning => _CleaningView(controller: controller),
      LinuxSystemCachePhase.done => _DoneView(controller: controller),
      LinuxSystemCachePhase.idle => _SelectionView(
        controller: controller,
        onCleanRequested: _confirmClean,
      ),
    };
  }
}

class _ProbeView extends StatelessWidget {
  const _ProbeView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            context.t('正在检测系统助手…'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnavailableView extends StatelessWidget {
  const _UnavailableView({required this.controller});

  final LinuxSystemCacheController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final reason =
        controller.unavailableReason ??
        LinuxSystemUnavailableReason.helperFailed;
    final detail = controller.unavailableDetail;

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
        GlassCard(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconTile(
                    icon: LucideIcons.shieldAlert,
                    size: 44,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          linuxUnavailableTitle(reason, strings),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          linuxUnavailableDescription(reason, strings),
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
              if (detail != null && detail.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    detail,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onErrorContainer,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: controller.isBusy ? null : controller.refresh,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: Text(context.t('重新检测')),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _BoundaryNote(),
      ],
    );
  }
}

class _SelectionView extends StatelessWidget {
  const _SelectionView({
    required this.controller,
    required this.onCleanRequested,
  });

  final LinuxSystemCacheController controller;
  final VoidCallback onCleanRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final capabilities = controller.availableOperations;

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
              const _ReviewWarning(),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer.withValues(
                              alpha: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(
                            LucideIcons.database,
                            size: 22,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.t('Linux 系统缓存'),
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                context.t(
                                  '通过一次 Polkit 授权，调用系统助手清理包管理器缓存、'
                                  '系统级 Flatpak 运行时、Snap 旧版本与 systemd journal。'
                                  '默认不勾选任何操作。',
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.45,
                                ),
                              ),
                              if (controller.capabilities
                                  case final capabilities?) ...[
                                const SizedBox(height: 5),
                                Text(
                                  context.tf('系统助手版本 {version}', {
                                    'version': capabilities.helperVersion,
                                  }),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: BroomColors.inkFaint(context),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (capabilities.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                LucideIcons.packageCheck,
                                size: 38,
                                color: scheme.primary,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                context.t('当前系统没有可用的系统清理操作'),
                                style: theme.textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                context.t(
                                  '系统助手已安装，但没有找到 APT、DNF、pacman、zypper、'
                                  'Flatpak、Snap 或 journalctl。',
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      for (final capability in capabilities)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _OperationCard(
                            operation: capability.operation,
                            selected: controller.isSelected(
                              capability.operation,
                            ),
                            onToggle: () => controller.toggleOperation(
                              capability.operation,
                            ),
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
          child: Container(
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
                        context.tf('已选择 {count} 项操作', {
                          'count': controller.selectedCount,
                        }),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        context.t('执行前会请求一次管理员授权'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: controller.selectedCount == 0
                      ? null
                      : controller.clearSelection,
                  child: Text(context.t('取消全选')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: controller.selectedCount == 0
                      ? null
                      : onCleanRequested,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                    disabledBackgroundColor: scheme.error.withValues(
                      alpha: 0.12,
                    ),
                  ),
                  icon: const Icon(LucideIcons.trash2, size: 18),
                  label: Text(
                    strings.tf('清理 {count} 项', {
                      'count': controller.selectedCount,
                    }),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({
    required this.operation,
    required this.selected,
    required this.onToggle,
  });

  final LinuxSystemOperation operation;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;

    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.24 : 0.3,
            )
          : BroomColors.block(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('linux-system-operation-${operation.id}'),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: selected,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
              ),
              Container(
                margin: const EdgeInsets.only(top: 2, right: 11),
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  linuxOperationIcon(operation),
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      linuxOperationTitle(operation, strings),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      linuxOperationDescription(operation, strings),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      linuxOperationNote(operation, strings),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                        height: 1.4,
                      ),
                    ),
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
                '系统级操作直接调用包管理器与系统工具，不经过隔离区，也没有撤销入口；'
                '确认前请先看清每一项会影响什么。',
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
                'Broom 只通过 pkexec 提交固定的操作名称，不接受路径、命令或自由文本；'
                '助手只执行白名单中的系统工具。已安装的应用、个人文件、用户 journal 与普通日志不受影响。',
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

class _CleaningView extends StatelessWidget {
  const _CleaningView({required this.controller});

  final LinuxSystemCacheController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        AnalysisProgressCard(
          icon: LucideIcons.shieldCheck,
          title: context.t('正在等待授权并清理…'),
          description: context.t(
            '请在 Polkit 对话框中确认授权。授权后助手会逐项执行；'
            '取消授权不会做任何更改。',
          ),
          stats: [
            AnalysisProgressStat(
              label: context.t('请求操作'),
              value: formatCount(controller.selectedCount),
            ),
            AnalysisProgressStat(label: context.t('授权方式'), value: 'Polkit'),
            AnalysisProgressStat(
              label: context.t('隔离区'),
              value: context.t('不使用'),
            ),
          ],
          onCancel: null,
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
                    '请保持此窗口打开。包缓存或旧版本较多时可能需要几分钟；'
                    '如果操作被其他包管理任务占用，助手会返回“忙碌”而不会等待。',
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

  final LinuxSystemCacheController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = controller.lastReport;
    if (report == null) return const SizedBox.shrink();

    final failedCount = report.operations.where((result) {
      return result.status != LinuxSystemOperationStatus.ok;
    }).length;
    final totalFreed = report.operations.fold<int>(
      0,
      (total, result) => total + (result.freedBytes ?? 0),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
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
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: failedCount == 0
                        ? scheme.primaryContainer.withValues(alpha: 0.55)
                        : scheme.errorContainer.withValues(alpha: 0.5),
                  ),
                  child: Icon(
                    failedCount == 0
                        ? LucideIcons.check
                        : LucideIcons.triangleAlert,
                    size: 33,
                    color: failedCount == 0 ? scheme.primary : scheme.error,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                failedCount == 0 ? context.t('清理完成') : context.t('部分操作未完成'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 5),
              Text(
                failedCount == 0
                    ? context.t('系统助手已执行所选操作，结果如下。')
                    : context.t('系统助手已逐项返回结果，失败或忙碌的操作没有假装成功。'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (totalFreed > 0) ...[
                const SizedBox(height: 14),
                Text(
                  context.tf('共释放约 {bytes}', {
                    'bytes': formatBytes(totalFreed),
                  }),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              for (final result in report.operations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ResultCard(result: result),
                ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.refresh,
                    icon: const Icon(LucideIcons.refreshCw, size: 17),
                    label: Text(context.t('重新检测')),
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

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final LinuxSystemOperationResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final isOk = result.status == LinuxSystemOperationStatus.ok;
    final color = isOk
        ? scheme.primary
        : result.status == LinuxSystemOperationStatus.busy
        ? BroomColors.warning
        : scheme.error;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: BroomColors.block(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOk
              ? scheme.outlineVariant.withValues(alpha: 0.5)
              : color.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isOk ? LucideIcons.circleCheck : LucideIcons.circleAlert,
            size: 19,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        linuxOperationTitle(result.operation, strings),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        linuxOperationStatusLabel(result.status, strings),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (result.message.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    result.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
                if (result.freedBytes case final bytes? when bytes > 0) ...[
                  const SizedBox(height: 3),
                  Text(
                    context.tf('释放 {bytes}', {'bytes': formatBytes(bytes)}),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
