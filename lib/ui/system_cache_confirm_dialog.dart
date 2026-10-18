import 'package:flutter/material.dart';

import '../core/models/system_models.dart';
import '../l10n/broom_strings.dart';
import 'format.dart';

Future<bool> showSystemCacheConfirmDialog(
  BuildContext context, {
  required int fileCount,
  required int bytes,
  required List<SystemServiceSpec> services,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => SystemCacheConfirmDialog(
      fileCount: fileCount,
      bytes: bytes,
      services: services,
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
  });

  final int fileCount;
  final int bytes;
  final List<SystemServiceSpec> services;

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
      icon: Icon(Icons.delete_forever_rounded, size: 30, color: scheme.error),
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
                '这些缓存不会进入 Broom 隔离区，删除后无法撤销。'
                'Windows 会在需要时重新下载更新或共享内容。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
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
              context.t('不会删除 Windows 更新历史、系统设置或 Windows.old。'),
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
