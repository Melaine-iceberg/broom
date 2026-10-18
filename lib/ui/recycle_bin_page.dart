import 'package:flutter/material.dart';

import '../core/models/cleaner_rule.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'format.dart';

class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key, required this.shell});

  final SystemShell shell;

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  RecycleBinSnapshot? _snapshot;
  String? _error;
  bool _loading = true;
  bool _emptying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _loading = true);
    }
    try {
      final snapshot = await widget.shell.queryRecycleBin();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
        _loading = false;
      });
    } on SystemShellException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = context.tf('无法读取回收站：{error}', {'error': error});
        _loading = false;
      });
    }
  }

  Future<void> _confirmEmpty() async {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.isEmpty || _emptying) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _EmptyRecycleBinDialog(snapshot: snapshot),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _emptying = true;
      _error = null;
    });
    try {
      await widget.shell.emptyRecycleBin();
      await _load(showLoading: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.t('回收站已清空。'))));
    } on SystemShellException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = context.tf('清空回收站失败：{error}', {'error': error}));
    } finally {
      if (mounted) {
        setState(() => _emptying = false);
      }
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
            Text(context.t('回收站')),
            const SizedBox(height: 1),
            Text(
              context.t('Windows 系统回收站 · 永久清空'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 20),
            child: Center(child: RiskBadge(risk: CleanRisk.review)),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
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
              const _ReviewWarning(),
              const SizedBox(height: 14),
              _RecycleBinCard(
                snapshot: _snapshot,
                loading: _loading,
                emptying: _emptying,
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _loading || _emptying
                        ? null
                        : () => _load(showLoading: false),
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: Text(context.t('刷新')),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed:
                        _snapshot == null || _snapshot!.isEmpty || _emptying
                        ? null
                        : _confirmEmpty,
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                      disabledBackgroundColor: scheme.error.withValues(
                        alpha: 0.12,
                      ),
                    ),
                    icon: _emptying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_forever_rounded, size: 19),
                    label: Text(
                      _emptying ? context.t('正在清空…') : context.t('清空回收站'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const _PolicyNote(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewWarning extends StatelessWidget {
  const _ReviewWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.tertiary.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 19,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.t(
                '回收站清理属于 Review 级操作：清空后无法恢复，文件不会进入 Broom 隔离区，'
                '也没有撤销入口。请确认里面的内容不再需要。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecycleBinCard extends StatelessWidget {
  const _RecycleBinCard({
    required this.snapshot,
    required this.loading,
    required this.emptying,
  });

  final RecycleBinSnapshot? snapshot;
  final bool loading;
  final bool emptying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final empty = snapshot?.isEmpty ?? false;

    return Container(
      padding: const EdgeInsets.fromLTRB(26, 26, 26, 24),
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
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  (empty ? scheme.primaryContainer : scheme.tertiaryContainer)
                      .withValues(alpha: 0.5),
            ),
            child: Icon(
              empty
                  ? Icons.delete_sweep_outlined
                  : Icons.delete_forever_rounded,
              size: 32,
              color: empty ? scheme.primary : scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 16),
          if (loading && snapshot == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else if (snapshot == null)
            Column(
              children: [
                Text(context.t('无法读取回收站'), style: theme.textTheme.titleMedium),
                const SizedBox(height: 5),
                Text(
                  context.t('可以稍后重试，或检查系统是否允许访问回收站。'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          else ...[
            Text(
              empty
                  ? context.t('回收站是空的')
                  : context.tf('回收站中有 {count} 个项目', {
                      'count': formatCount(snapshot!.itemCount),
                    }),
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              empty
                  ? context.t('没有需要清空的内容。')
                  : context.tf('占用约 {bytes}，统计范围包含所有磁盘。', {
                      'bytes': formatBytes(snapshot!.totalBytes),
                    }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (emptying) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: const LinearProgressIndicator(minHeight: 6),
            ),
            const SizedBox(height: 8),
            Text(
              context.t('正在通知 Windows 清空回收站…'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PolicyNote extends StatelessWidget {
  const _PolicyNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 17,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Text(context.t('Broom 的处理边界'), style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.t(
              '缓存清理使用 Broom 自己的隔离区，可以撤销。回收站由 Windows 管理，'
              'Broom 只读取统计并调用系统清空命令，不读取其中的文件内容。',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyRecycleBinDialog extends StatefulWidget {
  const _EmptyRecycleBinDialog({required this.snapshot});

  final RecycleBinSnapshot snapshot;

  @override
  State<_EmptyRecycleBinDialog> createState() => _EmptyRecycleBinDialogState();
}

class _EmptyRecycleBinDialogState extends State<_EmptyRecycleBinDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AlertDialog(
      icon: Icon(Icons.delete_forever_rounded, size: 30, color: scheme.error),
      title: Text(context.t('永久清空回收站？')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tf('将永久删除 {count} 个项目（{bytes}）。', {
              'count': formatCount(widget.snapshot.itemCount),
              'bytes': formatBytes(widget.snapshot.totalBytes),
            }),
          ),
          const SizedBox(height: 10),
          Text(
            context.t('此操作覆盖所有磁盘上的回收站内容，无法撤销，也不会进入 Broom 隔离区。'),
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
              context.t('我明白清空后无法恢复'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
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
          child: Text(context.t('永久清空')),
        ),
      ],
    );
  }
}
