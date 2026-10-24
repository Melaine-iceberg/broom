import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/platform/linux_system_maintenance.dart';
import '../l10n/broom_strings.dart';
import 'linux_system_operation_ui.dart';

Future<bool> showLinuxSystemCacheConfirmDialog(
  BuildContext context, {
  required List<LinuxSystemOperation> operations,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => LinuxSystemCacheConfirmDialog(operations: operations),
  );
  return confirmed ?? false;
}

class LinuxSystemCacheConfirmDialog extends StatefulWidget {
  const LinuxSystemCacheConfirmDialog({super.key, required this.operations});

  final List<LinuxSystemOperation> operations;

  @override
  State<LinuxSystemCacheConfirmDialog> createState() =>
      _LinuxSystemCacheConfirmDialogState();
}

class _LinuxSystemCacheConfirmDialogState
    extends State<LinuxSystemCacheConfirmDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final hasPackageCache = widget.operations.any(
      (operation) =>
          operation == LinuxSystemOperation.aptCache ||
          operation == LinuxSystemOperation.dnfPackages ||
          operation == LinuxSystemOperation.pacmanCache ||
          operation == LinuxSystemOperation.zypperCache,
    );
    final hasRuntimeCleanup = widget.operations.any(
      (operation) =>
          operation == LinuxSystemOperation.flatpakUnused ||
          operation == LinuxSystemOperation.snapRevisions,
    );
    final hasJournal = widget.operations.contains(
      LinuxSystemOperation.journal7d,
    );

    return AlertDialog(
      icon: Icon(LucideIcons.trash2, size: 30, color: scheme.error),
      title: Text(context.t('清理系统缓存？')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('将通过一次 Polkit 授权执行以下操作：')),
            const SizedBox(height: 8),
            for (final operation in widget.operations)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      linuxOperationIcon(operation),
                      size: 15,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        linuxOperationTitle(operation, strings),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Text(
              context.t(
                '这些系统缓存会被永久删除，不进入 Broom 隔离区，也无法撤销。'
                '请保持网络与包管理器空闲；系统助手会拒绝执行未列出的操作。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (hasPackageCache) ...[
              const SizedBox(height: 8),
              Text(
                context.t('已下载的安装包会被删除，之后重新安装或升级时需要重新下载；已安装软件不会被卸载。'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            if (hasRuntimeCleanup) ...[
              const SizedBox(height: 8),
              Text(
                context.t(
                  '未使用的 Flatpak 运行时与已禁用的 Snap 旧修订会被删除；'
                  '当前使用的版本和应用数据不受影响，但被删除的旧版本无法回退。',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            if (hasJournal) ...[
              const SizedBox(height: 8),
              Text(
                context.t(
                  '超过 7 天的归档日志会被删除，当前 journal 与最近 7 天的日志会保留；已删除日志无法恢复。',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 10),
            CheckboxListTile(
              key: const ValueKey('acknowledge-linux-system-cache'),
              value: _acknowledged,
              onChanged: (value) =>
                  setState(() => _acknowledged = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(
                context.t('我明白这些系统缓存将被永久删除，且无法撤销'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          onPressed: _acknowledged
              ? () => Navigator.of(context).pop(true)
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
            disabledBackgroundColor: scheme.error.withValues(alpha: 0.12),
          ),
          child: Text(context.t('请求授权并清理')),
        ),
      ],
    );
  }
}
