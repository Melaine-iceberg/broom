import 'package:flutter/material.dart';

import '../core/clean/clean_history_store.dart';
import '../core/models/clean_history_models.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'format.dart';
import 'glass_ui.dart';

class CleanHistoryPage extends StatefulWidget {
  const CleanHistoryPage({
    super.key,
    required this.store,
    this.ruleTitles = const {},
  });

  final CleanHistoryStore store;
  final Map<String, String> ruleTitles;

  @override
  State<CleanHistoryPage> createState() => _CleanHistoryPageState();
}

class _CleanHistoryPageState extends State<CleanHistoryPage> {
  List<CleanHistoryRecord> _records = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = trf('无法读取清理历史：{error}', {'error': error});
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

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
            Text(context.t('清理历史')),
            const SizedBox(height: 1),
            Text(
              context.t('记录每次清理的时间、规则、数量与结果'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: context.t('刷新'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
            children: [
              if (_error case final error?) ...[
                AnalysisBanner(
                  message: error,
                  isError: true,
                  onClose: () => setState(() => _error = null),
                ),
                const SizedBox(height: 12),
              ],
              if (_loading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
              ],
              if (!_loading && _records.isEmpty)
                const _EmptyHistory()
              else
                for (final record in _records) ...[
                  _HistoryCard(record: record, ruleTitles: widget.ruleTitles),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 8),
              Text(
                context.t(
                  '历史记录独立于隔离区：恢复或永久释放文件不会删除这里的记录。'
                  '最多保留最近 200 次清理。',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.record, required this.ruleTitles});

  final CleanHistoryRecord record;
  final Map<String, String> ruleTitles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (:label, :color, :background) = switch (record.outcome) {
      CleanHistoryOutcome.completed => (
        label: context.t('已完成'),
        color: scheme.onPrimaryContainer,
        background: scheme.primaryContainer,
      ),
      CleanHistoryOutcome.partial => (
        label: context.t('部分完成'),
        color: scheme.onTertiaryContainer,
        background: scheme.tertiaryContainer,
      ),
      CleanHistoryOutcome.cancelled => (
        label: context.t('已取消'),
        color: scheme.onTertiaryContainer,
        background: scheme.tertiaryContainer,
      ),
      CleanHistoryOutcome.failed => (
        label: context.t('失败'),
        color: scheme.onErrorContainer,
        background: scheme.errorContainer,
      ),
    };

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.history_rounded,
                  size: 19,
                  color: scheme.primary,
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
                            formatDateTime(record.completedAt.toLocal()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: background.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.tf('计划 {count} 个文件（{bytes}）', {
                        'count': formatCount(record.plannedCount),
                        'bytes': formatBytes(record.plannedBytes),
                      }),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _HistoryMetric(
                icon: Icons.inventory_2_outlined,
                label: context.tf('暂存 {count} 个文件（{bytes}）', {
                  'count': formatCount(record.movedCount),
                  'bytes': formatBytes(record.movedBytes),
                }),
              ),
              if (record.skippedCount > 0)
                _HistoryMetric(
                  icon: Icons.lock_outline_rounded,
                  label: context.tf('跳过 {count} 个', {
                    'count': formatCount(record.skippedCount),
                  }),
                ),
              if (record.failureCount > 0)
                _HistoryMetric(
                  icon: Icons.warning_amber_rounded,
                  label: context.tf('失败 {count} 个', {
                    'count': formatCount(record.failureCount),
                  }),
                ),
              if (record.remainingCount > 0)
                _HistoryMetric(
                  icon: Icons.play_circle_outline_rounded,
                  label: context.tf('未处理 {count} 个', {
                    'count': formatCount(record.remainingCount),
                  }),
                ),
            ],
          ),
          if (record.rules.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final rule in record.rules.take(5))
                  _RuleChip(
                    label:
                        ruleTitles[rule.ruleId] ??
                        context.tf('规则 {rule}', {'rule': rule.ruleId}),
                    count: rule.fileCount,
                  ),
                if (record.rules.length > 5)
                  _RuleChip(
                    label: context.tf('另有 {count} 条规则', {
                      'count': record.rules.length - 5,
                    }),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HistoryMetric extends StatelessWidget {
  const _HistoryMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleChip extends StatelessWidget {
  const _RuleChip({required this.label, this.count});

  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        count == null ? label : '$label · $count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: GlassCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
        child: Center(
          child: Column(
            children: [
              const IconTile(icon: Icons.history_rounded, size: 46, radius: 14),
              const SizedBox(height: 13),
              Text(
                context.t('还没有清理历史'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  context.t('完成一次清理后，这里会保留一条记录；恢复或永久释放隔离区不会删除历史。'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BroomColors.inkMuted(context),
                    height: 1.55,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
