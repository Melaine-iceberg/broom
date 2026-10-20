import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/models/quarantine_policy_models.dart';
import '../l10n/broom_strings.dart';
import 'format.dart';

Future<QuarantineRetentionPolicy?> showQuarantinePolicyDialog(
  BuildContext context, {
  required QuarantineRetentionPolicy policy,
}) {
  return showDialog<QuarantineRetentionPolicy>(
    context: context,
    builder: (_) => _QuarantinePolicyDialog(initialPolicy: policy),
  );
}

class _QuarantinePolicyDialog extends StatefulWidget {
  const _QuarantinePolicyDialog({required this.initialPolicy});

  final QuarantineRetentionPolicy initialPolicy;

  @override
  State<_QuarantinePolicyDialog> createState() =>
      _QuarantinePolicyDialogState();
}

class _QuarantinePolicyDialogState extends State<_QuarantinePolicyDialog> {
  static const _gib = 1024 * 1024 * 1024;

  late bool _enabled = widget.initialPolicy.enabled;
  late int _days = widget.initialPolicy.retentionDays;
  late int _maxBytes = widget.initialPolicy.maxBytes;
  late bool _acknowledged = widget.initialPolicy.enabled;

  bool get _canSave => !_enabled || _acknowledged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dayOptions = ({
      7,
      14,
      30,
      60,
      90,
      widget.initialPolicy.retentionDays,
    }.toList()..sort());
    final byteOptions = ({
      1 * _gib,
      2 * _gib,
      5 * _gib,
      10 * _gib,
      20 * _gib,
      widget.initialPolicy.maxBytes,
    }.toList()..sort());

    return AlertDialog(
      icon: Icon(LucideIcons.clock, size: 30, color: scheme.tertiary),
      title: Text(context.t('隔离区保留策略')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('retention-enabled-switch'),
                value: _enabled,
                onChanged: (value) {
                  setState(() {
                    _enabled = value;
                    if (!value || !widget.initialPolicy.enabled) {
                      _acknowledged = false;
                    }
                  });
                },
                contentPadding: EdgeInsets.zero,
                title: Text(context.t('自动永久释放旧会话')),
                subtitle: Text(context.t('Broom 会在启动时和保存后按以下规则处理；默认关闭。')),
              ),
              if (_enabled) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  key: const ValueKey('retention-days-dropdown'),
                  initialValue: _days,
                  decoration: InputDecoration(
                    labelText: context.t('保留最近'),
                    suffixText: context.t('天'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final days in dayOptions)
                      DropdownMenuItem(value: days, child: Text('$days')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _days = value);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: const ValueKey('retention-size-dropdown'),
                  initialValue: _maxBytes,
                  decoration: InputDecoration(
                    labelText: context.t('隔离区占用上限'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final bytes in byteOptions)
                      DropdownMenuItem(
                        value: bytes,
                        child: Text(formatBytes(bytes)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _maxBytes = value);
                  },
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.triangleAlert,
                        size: 18,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.t(
                            '超过保留天数或占用上限的旧会话会被永久删除，'
                            '不进入回收站，也无法恢复。容量超限时从最旧的会话开始释放。',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                CheckboxListTile(
                  key: const ValueKey('retention-acknowledge-checkbox'),
                  value: _acknowledged,
                  onChanged: (value) =>
                      setState(() => _acknowledged = value ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: Text(
                    context.t('我明白自动清理会永久删除隔离区文件，且无法恢复'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 6),
                Text(
                  context.t(
                    '关闭后，Broom 不会自动删除任何隔离区文件；'
                    '你仍可手动恢复或永久释放。',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey('retention-save-button'),
          onPressed: _canSave
              ? () => Navigator.of(context).pop(
                  QuarantineRetentionPolicy(
                    enabled: _enabled,
                    retentionDays: _days,
                    maxBytes: _maxBytes,
                  ),
                )
              : null,
          child: Text(context.t('保存并应用')),
        ),
      ],
    );
  }
}
