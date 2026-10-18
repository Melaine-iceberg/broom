import 'package:flutter/material.dart';

import '../core/models/cleaner_rule.dart';
import 'format.dart';

class RiskBadge extends StatelessWidget {
  const RiskBadge({super.key, required this.risk});

  final CleanRisk risk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (:label, :background, :foreground, :border) = switch (risk) {
      CleanRisk.safe => (
        label: 'SAFE · 可撤销',
        background: scheme.primaryContainer.withValues(alpha: 0.35),
        foreground: scheme.onPrimaryContainer,
        border: scheme.primary.withValues(alpha: 0.16),
      ),
      CleanRisk.review => (
        label: 'REVIEW · 需确认',
        background: scheme.tertiaryContainer.withValues(alpha: 0.45),
        foreground: scheme.onTertiaryContainer,
        border: scheme.tertiary.withValues(alpha: 0.18),
      ),
      CleanRisk.info => (
        label: 'INFO · 只读',
        background: scheme.secondaryContainer.withValues(alpha: 0.4),
        foreground: scheme.onSecondaryContainer,
        border: scheme.secondary.withValues(alpha: 0.16),
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.25,
          height: 1.2,
        ),
      ),
    );
  }
}

class ReadOnlyHint extends StatelessWidget {
  const ReadOnlyHint({
    super.key,
    required this.message,
    this.icon = Icons.visibility_outlined,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
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
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: isError
            ? scheme.errorContainer.withValues(alpha: 0.62)
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

class FolderSelectionCard extends StatelessWidget {
  const FolderSelectionCard({
    super.key,
    required this.path,
    required this.onPick,
    this.enabled = true,
    this.label = '分析范围',
  });

  final String? path;
  final VoidCallback onPick;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPath = path != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              Icons.folder_open_rounded,
              size: 19,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Tooltip(
                  message: path ?? '',
                  child: Text(
                    path ?? '尚未选择文件夹',
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
            label: Text(hasPath ? '更改' : '选择文件夹'),
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
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer.withValues(alpha: 0.5),
            ),
            child: Icon(icon, size: 30, color: scheme.primary),
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
            label: Text(cancelRequested ? '正在停止…' : '停止分析'),
          ),
        ],
      ),
    );
  }
}
