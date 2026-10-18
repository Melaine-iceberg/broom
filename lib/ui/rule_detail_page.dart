import 'package:flutter/material.dart';

import '../core/models/scan_models.dart';
import '../l10n/broom_strings.dart';
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
                  context.tf('{count} 个文件 · {bytes}', {
                    'count': formatCount(result.items.length),
                    'bytes': formatBytes(result.totalBytes),
                  }),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
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
                Icons.insert_drive_file_outlined,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileNameOf(item.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
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
