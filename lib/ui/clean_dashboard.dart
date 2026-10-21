import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/models/cleaner_rule.dart';
import '../l10n/broom_strings.dart';
import 'clean_controller.dart';
import 'format.dart';
import 'glass_ui.dart';
import 'settings_controller.dart';

/// The dashboard-style landing page for the cleaning section.
class CleanDashboard extends StatelessWidget {
  const CleanDashboard({
    super.key,
    required this.controller,
    required this.settingsController,
    required this.onOpenQuarantine,
    required this.onOpenRecycleBin,
    required this.onOpenDuplicateFinder,
    required this.onOpenLargeFiles,
    required this.scopeSection,
    this.onOpenSystemCache,
  });

  final CleanController controller;
  final SettingsController settingsController;
  final VoidCallback onOpenQuarantine;
  final VoidCallback onOpenRecycleBin;
  final VoidCallback onOpenDuplicateFinder;
  final VoidCallback onOpenLargeFiles;
  final Widget scopeSection;
  final VoidCallback? onOpenSystemCache;

  @override
  Widget build(BuildContext context) {
    // The shared grouping always includes the runtime leftover category, so
    // the enabled/total statistic matches the toggles in the scope section.
    final categories = controller.scanCategories;
    final enabledCategoryCount = categories
        .where((category) => settingsController.isCategoryEnabled(category.key))
        .length;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        PageHeading(
          title: context.t('清理'),
          subtitle: context.t('扫描缓存和临时文件，预览确认后再移入隔离区。'),
        ),
        const SizedBox(height: 20),
        if (controller.error case final error?)
          _DashboardBanner(
            message: error,
            isError: true,
            onClose: controller.clearError,
          ),
        if (controller.notice case final notice?)
          _DashboardBanner(message: notice, onClose: controller.clearNotice),
        LayoutBuilder(
          builder: (context, constraints) {
            final scan = _ScanHero(
              controller: controller,
              enabledCategories: enabledCategoryCount,
              totalCategories: categories.length,
              ruleCount: controller.rules.length,
              leftoverEnabled: settingsController.isCategoryEnabled(
                leftoverCategoryKey,
              ),
              exclusionCount: controller.exclusionCount,
            );
            final lastScan = _LastScanCard(controller: controller);
            final quarantine = _QuarantineCard(
              controller: controller,
              onOpen: onOpenQuarantine,
            );
            if (constraints.maxWidth < 820) {
              if (constraints.maxWidth < 540) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    scan,
                    const SizedBox(height: 14),
                    lastScan,
                    const SizedBox(height: 14),
                    quarantine,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  scan,
                  const SizedBox(height: 14),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: lastScan),
                        const SizedBox(width: 14),
                        Expanded(child: quarantine),
                      ],
                    ),
                  ),
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 21, child: scan),
                  const SizedBox(width: 16),
                  Expanded(flex: 10, child: lastScan),
                  const SizedBox(width: 16),
                  Expanded(flex: 10, child: quarantine),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        scopeSection,
        const SizedBox(height: 26),
        _ToolsSection(
          onOpenSystemCache: onOpenSystemCache,
          onOpenRecycleBin: onOpenRecycleBin,
          onOpenDuplicateFinder: onOpenDuplicateFinder,
          onOpenLargeFiles: onOpenLargeFiles,
        ),
      ],
    );
  }
}

class _DashboardBanner extends StatelessWidget {
  const _DashboardBanner({
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
    final foreground = isError ? scheme.error : BroomColors.inkMuted(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
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
            isError ? LucideIcons.circleAlert : LucideIcons.info,
            size: 17,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foreground,
                height: 1.45,
              ),
            ),
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              tooltip: context.t('关闭'),
              icon: const Icon(LucideIcons.x),
            ),
        ],
      ),
    );
  }
}

class _ScanHero extends StatelessWidget {
  const _ScanHero({
    required this.controller,
    required this.enabledCategories,
    required this.totalCategories,
    required this.ruleCount,
    required this.leftoverEnabled,
    required this.exclusionCount,
  });

  final CleanController controller;
  final int enabledCategories;
  final int totalCategories;
  final int ruleCount;
  final bool leftoverEnabled;
  final int exclusionCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = controller.lastScanSummary;

    return GlassCard(
      key: const ValueKey('scan-hero'),
      padding: EdgeInsets.zero,
      radius: 30,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: Stack(
          children: [
            Positioned(
              right: -82,
              top: -108,
              child: IgnorePointer(
                child: Transform.rotate(
                  angle: -0.18,
                  child: Container(
                    width: 276,
                    height: 276,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(88),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          scheme.primary.withValues(
                            alpha: BroomColors.isDark(context) ? 0.2 : 0.13,
                          ),
                          scheme.primary.withValues(alpha: 0.015),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 58,
              bottom: 34,
              child: IgnorePointer(
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.24),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BroomCardHeader(
                    icon: LucideIcons.radar,
                    title: context.t('扫描'),
                    trailing: StatusChip(
                      label: context.t('准备就绪'),
                      tone: BroomColors.success,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              summary == null
                                  ? context.t('还没有扫描记录')
                                  : context.t('上次扫描结果'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: BroomColors.inkMuted(context),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 5),
                            CardFigure(
                              summary == null
                                  ? '—'
                                  : formatBytes(summary.foundBytes),
                              size: 40,
                              color: summary == null
                                  ? BroomColors.inkFaint(context)
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              summary == null
                                  ? context.t('完成扫描后，可在这里快速回到结果。')
                                  : context.tf('{count} 个文件 · {time}', {
                                      'count': formatCount(summary.foundFiles),
                                      'time': formatDateTime(
                                        summary.completedAt.toLocal(),
                                      ),
                                    }),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: BroomColors.inkMuted(context),
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      _ScanAction(
                        busy: controller.isBusy,
                        onTap: controller.scan,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 22,
                    runSpacing: 10,
                    children: [
                      _HeroCell(
                        label: context.t('启用类别'),
                        value: '$enabledCategories/$totalCategories',
                      ),
                      _HeroCell(label: context.t('扫描规则'), value: '$ruleCount'),
                      _HeroCell(
                        label: context.t('卸载残留'),
                        value: leftoverEnabled
                            ? '${controller.leftoverDetectedCount}'
                            : context.t('已关闭'),
                      ),
                      _HeroCell(
                        label: context.t('排除目录'),
                        value: '$exclusionCount',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroCell extends StatelessWidget {
  const _HeroCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 17,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: BroomColors.ink(context),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.2,
            fontWeight: FontWeight.w500,
            color: BroomColors.inkMuted(context),
          ),
        ),
      ],
    );
  }
}

class _ScanAction extends StatefulWidget {
  const _ScanAction({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  State<_ScanAction> createState() => _ScanActionState();
}

class _ScanActionState extends State<_ScanAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = !widget.busy;

    return Tooltip(
      message: context.t('开始扫描（F5）'),
      preferBelow: false,
      verticalOffset: -6,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: context.t('开始扫描'),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? widget.onTap : null,
            child: AnimatedScale(
              scale: _hovered && enabled ? 1.035 : 1,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: enabled
                            ? const [Color(0xFF54AAFF), Color(0xFF007AFF)]
                            : [
                                scheme.onSurface.withValues(alpha: 0.2),
                                scheme.onSurface.withValues(alpha: 0.12),
                              ],
                      ),
                      boxShadow: enabled
                          ? [
                              BoxShadow(
                                color: scheme.primary.withValues(
                                  alpha: _hovered ? 0.4 : 0.3,
                                ),
                                blurRadius: _hovered ? 34 : 26,
                                spreadRadius: -4,
                                offset: const Offset(0, 12),
                              ),
                            ]
                          : null,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned(
                          top: 10,
                          left: 22,
                          right: 22,
                          child: Container(
                            height: 28,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withValues(alpha: 0.28),
                                  Colors.white.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Icon(
                          widget.busy
                              ? LucideIcons.hourglass
                              : LucideIcons.sparkles,
                          size: 34,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.t('开始扫描'),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? scheme.primary
                          : BroomColors.inkFaint(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
    final sessions = controller.pendingSessions.length;
    final unfinished = controller.unfinishedSessions.length;
    final hasItems = controller.pendingFileCount > 0 || sessions > 0;

    return GlassCard(
      key: const ValueKey('quarantine-card'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BroomCardHeader(
                icon: LucideIcons.archive,
                title: context.t('隔离区'),
                trailing: unfinished > 0
                    ? StatusChip(
                        label: '$unfinished',
                        tone: BroomColors.warning,
                      )
                    : Icon(
                        LucideIcons.arrowUpRight,
                        size: 16,
                        color: BroomColors.inkFaint(context),
                      ),
              ),
              const SizedBox(height: 18),
              if (hasItems)
                CardFigure(formatBytes(controller.pendingBytes), size: 30)
              else
                Text(
                  context.t('隔离区为空'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 5),
              Text(
                hasItems
                    ? context.tf('{files} 个文件 · {sessions} 次清理', {
                        'files': formatCount(controller.pendingFileCount),
                        'sessions': sessions,
                      })
                    : context.t('清理的文件会先暂存在这里，可随时恢复。'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: BroomColors.inkMuted(context),
                  height: 1.45,
                ),
              ),
              if (unfinished > 0) ...[
                const SizedBox(height: 5),
                Text(
                  context.tf('{count} 次清理未正常结束', {'count': unfinished}),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: BroomColors.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onOpen,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: Icon(
                hasItems ? LucideIcons.archive : LucideIcons.arrowRight,
                size: 15,
              ),
              label: Text(hasItems ? context.t('管理') : context.t('打开')),
            ),
          ),
        ],
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
    final summary = controller.lastScanSummary;
    final stale = controller.lastScanStale;

    return GlassCard(
      key: const ValueKey('last-scan-card'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BroomCardHeader(
                icon: LucideIcons.history,
                title: context.t('上次扫描'),
                trailing: stale
                    ? StatusChip(
                        label: context.t('规则已更新'),
                        tone: BroomColors.warning,
                        dot: false,
                      )
                    : null,
              ),
              const SizedBox(height: 18),
              if (summary == null)
                Text(
                  context.t('还没有扫描记录'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                CardFigure(formatBytes(summary.foundBytes), size: 30),
              const SizedBox(height: 5),
              Text(
                summary == null
                    ? context.t('完成扫描后，可在这里快速回到结果。')
                    : context.tf('{count} 个文件 · {time}', {
                        'count': formatCount(summary.foundFiles),
                        'time': formatDateTime(summary.completedAt.toLocal()),
                      }),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: BroomColors.inkMuted(context),
                  height: 1.45,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (summary != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('restore-last-scan'),
                onPressed: controller.restoringLastScan
                    ? null
                    : controller.restoreLastScan,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: controller.restoringLastScan
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.arrowRight, size: 15),
                label: Text(context.t('查看')),
              ),
            )
          else
            const SizedBox(height: 32),
        ],
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
    final specs =
        <
          ({
            String key,
            IconData icon,
            String title,
            String description,
            VoidCallback onTap,
          })
        >[
          if (onOpenSystemCache != null)
            (
              key: 'tool-system-cache',
              icon: LucideIcons.database,
              title: context.t('系统级缓存'),
              description: context.t('Windows 更新与旧系统文件 · 需要管理员权限'),
              onTap: onOpenSystemCache!,
            ),
          (
            key: 'tool-recycle-bin',
            icon: LucideIcons.trash2,
            title: context.t('回收站'),
            description: context.t('查看各磁盘回收站占用'),
            onTap: onOpenRecycleBin,
          ),
          (
            key: 'tool-duplicate-files',
            icon: LucideIcons.copy,
            title: context.t('重复文件'),
            description: context.t('按文件内容查找重复项'),
            onTap: onOpenDuplicateFinder,
          ),
          (
            key: 'tool-large-files',
            icon: LucideIcons.hardDrive,
            title: context.t('大文件分析'),
            description: context.t('按体积排序，定位空间占用'),
            onTap: onOpenLargeFiles,
          ),
        ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(title: context.t('工具')),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 840
                ? 4
                : constraints.maxWidth >= 540
                ? 2
                : 1;
            const gap = 16.0;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final spec in specs)
                  SizedBox(
                    width: width,
                    height: 150,
                    child: _ToolCard(
                      key: ValueKey(spec.key),
                      icon: spec.icon,
                      title: spec.title,
                      description: spec.description,
                      onTap: spec.onTap,
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
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 17, 18, 16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: icon, size: 40, radius: 12),
              const Spacer(),
              Icon(
                LucideIcons.arrowUpRight,
                size: 16,
                color: BroomColors.inkFaint(context),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              height: 1.4,
              color: BroomColors.inkMuted(context),
            ),
          ),
        ],
      ),
    );
  }
}
