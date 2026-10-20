import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/models/system_models.dart';
import '../l10n/broom_strings.dart';
import 'format.dart';

Future<bool> showSystemCacheConfirmDialog(
  BuildContext context, {
  required int fileCount,
  required int bytes,
  required List<SystemServiceSpec> services,
  bool includesWindowsOld = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => SystemCacheConfirmDialog(
      fileCount: fileCount,
      bytes: bytes,
      services: services,
      includesWindowsOld: includesWindowsOld,
    ),
  );
  return confirmed ?? false;
}

class SystemCacheConfirmDialog extends StatefulWidget {
  const SystemCacheConfirmDialog({
    super.key,
    required this.fileCount,
    required this.bytes,
    required this.services,
    this.includesWindowsOld = false,
  });

  final int fileCount;
  final int bytes;
  final List<SystemServiceSpec> services;
  final bool includesWindowsOld;

  @override
  State<SystemCacheConfirmDialog> createState() =>
      _SystemCacheConfirmDialogState();
}

class _SystemCacheConfirmDialogState extends State<SystemCacheConfirmDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final serviceLabels = widget.services
        .map(strings.serviceLabel)
        .join(strings.t('、'));

    return AlertDialog(
      icon: Icon(LucideIcons.trash2, size: 30, color: scheme.error),
      title: Text(context.t('永久删除系统缓存？')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tf('将永久删除 {count} 个文件（{bytes}）。', {
                'count': formatCount(widget.fileCount),
                'bytes': formatBytes(widget.bytes),
              }),
            ),
            const SizedBox(height: 10),
            Text(
              context.t(
                '这些系统缓存不会进入 Broom 隔离区，删除后无法撤销。'
                '更新与共享缓存会在需要时重新下载。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (widget.includesWindowsOld) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  context.t(
                    '所选内容包含 Windows.old。删除后将失去回滚到上一版本 Windows '
                    '的能力，并可能移除其中保留的旧用户配置文件副本、旧程序和系统设置，'
                    '且无法恢复。请先备份所需文件；当前系统的个人文件、还原点和更新历史不受影响。',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            if (widget.services.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                context.tf('清理期间将临时停止 {services}，完成或中止后自动恢复。', {
                  'services': serviceLabels,
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              context.t('不会删除当前 Windows、个人文件、系统还原点或更新历史。'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _acknowledged,
              onChanged: (value) =>
                  setState(() => _acknowledged = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(
                context.t('我明白系统缓存将被永久删除，且无法撤销'),
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
          child: Text(context.t('永久删除')),
        ),
      ],
    );
  }
}
