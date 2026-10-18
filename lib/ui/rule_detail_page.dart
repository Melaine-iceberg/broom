import 'package:flutter/material.dart';

import '../core/models/cleaner_rule.dart';
import '../core/models/scan_models.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'clean_controller.dart';
import 'format.dart';

class RuleDetailPage extends StatelessWidget {
  const RuleDetailPage({
    super.key,
    required this.controller,
    required this.result,
  });

  final CleanController controller;
  final RuleResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final rule = result.rule;
        final bool? selection = controller.ruleSelectionValue(rule.id);
        final selectedCount = controller.selectedCountForRule(rule.id);
        final selectedBytes = controller.selectedBytesForRule(rule.id);
        final lockedCount = controller.possiblyLockedCountForRule(rule.id);

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: context.t('返回'),
            ),
            toolbarHeight: 68,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.strings.ruleTitle(rule)),
                const SizedBox(height: 1),
                Text(
                  lockedCount > 0
                      ? context.tf('{count} 个文件 · {bytes} · {locked} 个可能被占用', {
                          'count': formatCount(result.items.length),
                          'bytes': formatBytes(result.totalBytes),
                          'locked': formatCount(lockedCount),
                        })
                      : context.tf('{count} 个文件 · {bytes}', {
                          'count': formatCount(result.items.length),
                          'bytes': formatBytes(result.totalBytes),
                        }),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: RiskBadge(risk: rule.risk),
              ),
              if (rule.audit != null)
                IconButton(
                  key: ValueKey('rule-audit-${rule.id}'),
                  onPressed: () => _showRuleAudit(context, rule),
                  icon: const Icon(Icons.policy_outlined),
                  tooltip: context.t('规则审计'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 6, 28, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 17,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.strings.ruleDescription(rule),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    height: 1.5,
                                  ),
                                ),
                                if (context.strings.ruleNote(rule)
                                    case final note?) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    note,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                                if (lockedCount > 0) ...[
                                  const SizedBox(height: 6),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.lock_outline_rounded,
                                        size: 14,
                                        color: scheme.tertiary,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          context.t(
                                            '标记为“可能被占用”的文件仍可勾选；'
                                            '清理时会跳过被占用的文件并单独报告。',
                                          ),
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: scheme.tertiary,
                                                height: 1.4,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            context.t('按大小排序'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            key: const ValueKey('rule-select-all'),
                            value: selection,
                            tristate: true,
                            onChanged: (_) => controller.toggleRule(rule.id),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            context.tf(
                              '已选 {selected} / {total} 个文件 · {bytes}',
                              {
                                'selected': formatCount(selectedCount),
                                'total': formatCount(result.items.length),
                                'bytes': formatBytes(selectedBytes),
                              },
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: controller.isRuleSelected(rule.id)
                                ? () =>
                                      controller.setRuleSelected(rule.id, false)
                                : () =>
                                      controller.setRuleSelected(rule.id, true),
                            child: Text(
                              controller.isRuleSelected(rule.id)
                                  ? context.t('取消全选')
                                  : context.t('全选'),
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                controller.invertRuleSelection(rule.id),
                            child: Text(context.t('反选')),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: result.items.length,
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            indent: 62,
                            endIndent: 16,
                            color: scheme.outlineVariant.withValues(alpha: 0.4),
                          ),
                          itemBuilder: (context, index) {
                            final item = result.items[index];
                            return _FileRow(
                              key: ValueKey('rule-file-${item.path}'),
                              item: item,
                              selected: controller.isItemSelected(item.path),
                              onChanged: () => controller.toggleItem(item.path),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> _showRuleAudit(BuildContext context, CleanerRule rule) {
  final audit = rule.audit;
  if (audit == null) return Future.value();
  final strings = context.strings;
  final positive = audit.samples.where((sample) => sample.inScope).length;
  final negative = audit.samples.length - positive;

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.policy_outlined, size: 30),
      title: Text(
        strings.tf('{rule} · 规则审计', {'rule': strings.ruleTitle(rule)}),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    strings.t('风险等级'),
                    style: Theme.of(dialogContext).textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 10),
                  RiskBadge(risk: rule.risk),
                ],
              ),
              const SizedBox(height: 18),
              _AuditSection(
                title: strings.t('评审说明'),
                body: strings.auditReviewNotes(audit),
              ),
              const SizedBox(height: 16),
              _AuditSection(
                title: strings.t('反向证据'),
                body: strings.auditReverseEvidence(audit),
              ),
              const SizedBox(height: 16),
              _AuditSection(
                title: strings.t('回归样例'),
                body: strings.tf('正例 {positive} 个 · 反例 {negative} 个', {
                  'positive': positive,
                  'negative': negative,
                }),
                footer: strings.t('内置样例由规则审计测试逐条校验。'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(strings.t('知道了')),
        ),
      ],
    ),
  );
}

class _AuditSection extends StatelessWidget {
  const _AuditSection({required this.title, required this.body, this.footer});

  final String title;
  final String body;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(body, style: theme.textTheme.bodySmall?.copyWith(height: 1.5)),
        if (footer case final footer?) ...[
          const SizedBox(height: 4),
          Text(
            footer,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onChanged,
  });

  final JunkItem item;
  final bool selected;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onChanged,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (_) => onChanged(),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 2),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                item.possiblyLocked
                    ? Icons.lock_outline_rounded
                    : Icons.insert_drive_file_outlined,
                size: 17,
                color: item.possiblyLocked
                    ? scheme.tertiary
                    : scheme.onSurfaceVariant,
              ),
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
                          fileNameOf(item.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (item.possiblyLocked) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: context.t('可能正被其他程序占用，清理时会跳过'),
                          child: Icon(
                            Icons.lock_outline_rounded,
                            size: 14,
                            color: scheme.tertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Tooltip(
                    message: item.path,
                    child: Text(
                      item.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatBytes(item.size),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatDate(item.modified),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
