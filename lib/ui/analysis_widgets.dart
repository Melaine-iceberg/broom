import 'package:flutter/material.dart';

import '../core/models/cleaner_rule.dart';
import '../l10n/broom_strings.dart';
import 'format.dart';
import 'glass_ui.dart';

class RiskBadge extends StatelessWidget {
  const RiskBadge({super.key, required this.risk});

  final CleanRisk risk;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (risk) {
      CleanRisk.safe => (
        Icons.undo_rounded,
        context.t('可撤销'),
        BroomColors.inkMuted(context),
      ),
      CleanRisk.review => (
        Icons.shield_outlined,
        context.t('需确认'),
        BroomColors.warning,
      ),
      CleanRisk.info => (
        Icons.visibility_outlined,
        context.t('只读'),
        BroomColors.inkMuted(context),
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class AnalysisBanner extends StatelessWidget {
  const AnalysisBanner({
    super.key,
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
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
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
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 15),
              tooltip: context.t('关闭'),
            ),
        ],
      ),
    );
  }
}

class FolderSelectionCard extends StatelessWidget {
  const FolderSelectionCard({
    super.key,
    required this.path,
    required this.onPick,
    this.enabled = true,
    this.label,
  });

  final String? path;
  final VoidCallback onPick;
  final bool enabled;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPath = path != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(24),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: BroomColors.block(context),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.folder_open_rounded,
              size: 21,
              color: BroomColors.inkMuted(context),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label ?? context.t('分析范围'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Tooltip(
                  message: path ?? '',
                  child: Text(
                    path ?? context.t('尚未选择文件夹'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: hasPath
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: enabled ? onPick : null,
            icon: const Icon(Icons.drive_folder_upload_outlined, size: 16),
            label: Text(hasPath ? context.t('更改') : context.t('选择文件夹')),
          ),
        ],
      ),
    );
  }
}

class AnalysisProgressStat {
  const AnalysisProgressStat({required this.label, required this.value});

  final String label;
  final String value;
}

class AnalysisProgressCard extends StatelessWidget {
  const AnalysisProgressCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.stats,
    required this.onCancel,
    this.progress,
    this.currentPath,
    this.cancelRequested = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<AnalysisProgressStat> stats;
  final VoidCallback? onCancel;
  final double? progress;
  final String? currentPath;
  final bool cancelRequested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(30, 34, 30, 26),
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(28),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.1),
            ),
            child: Icon(icon, size: 28, color: scheme.primary),
          ),
          const SizedBox(height: 18),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 5),
          Text(
            description,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              for (var index = 0; index < stats.length; index++) ...[
                if (index > 0)
                  Container(
                    width: 1,
                    height: 30,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        stats[index].value,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        stats[index].label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (currentPath != null && currentPath!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
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
                      message: currentPath!,
                      child: Text(
                        fileNameOf(currentPath!),
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
          const SizedBox(height: 18),
          TextButton.icon(
            onPressed: cancelRequested ? null : onCancel,
            icon: const Icon(Icons.stop_circle_outlined, size: 17),
            label: Text(
              cancelRequested ? context.t('正在停止…') : context.t('停止分析'),
            ),
          ),
        ],
      ),
    );
  }
}
