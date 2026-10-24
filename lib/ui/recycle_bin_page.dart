import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/models/cleaner_rule.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'format.dart';
import 'glass_ui.dart';

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
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: context.t('返回'),
        ),
        toolbarHeight: 76,
        title: Text(context.t('回收站')),
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
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            children: [
              if (_error case final error?) ...[
                AnalysisBanner(
                  message: error,
                  isError: true,
                  onClose: () => setState(() => _error = null),
                ),
                const SizedBox(height: 10),
              ],
              const _ReviewWarning(),
              const SizedBox(height: 12),
              _RecycleBinCard(
                snapshot: _snapshot,
                loading: _loading,
                emptying: _emptying,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _loading || _emptying
                        ? null
                        : () => _load(showLoading: false),
                    icon: const Icon(LucideIcons.refreshCw, size: 17),
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
                        : const Icon(LucideIcons.trash2, size: 19),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              LucideIcons.triangleAlert,
              size: 15,
              color: BroomColors.warning,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.t('清空后无法恢复，文件不会进入隔离区，也没有撤销入口。'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.inkMuted(context),
                height: 1.5,
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
    final empty = snapshot?.isEmpty ?? false;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconTile(
                icon: empty ? LucideIcons.trash2 : LucideIcons.trash2,
                size: 44,
                color: empty ? BroomColors.accent : BroomColors.amber,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (loading && snapshot == null)
                      Text(
                        context.t('正在读取回收站…'),
                        style: theme.textTheme.titleSmall,
                      )
                    else if (snapshot == null)
                      Text(
                        context.t('无法读取回收站'),
                        style: theme.textTheme.titleSmall,
                      )
                    else
                      Text(
                        empty
                            ? context.t('回收站是空的')
                            : context.tf('回收站中有 {count} 个项目', {
                                'count': formatCount(snapshot!.itemCount),
                              }),
                        style: theme.textTheme.titleMedium,
                      ),
                    const SizedBox(height: 3),
                    Text(
                      loading && snapshot == null
                          ? context.t('正在查询用户回收站与可访问磁盘的回收站占用。')
                          : snapshot == null
                          ? context.t('可以稍后重试，或检查系统是否允许访问回收站。')
                          : empty
                          ? context.t('没有需要清空的内容。')
                          : context.tf('占用约 {bytes} · 包含用户回收站与可访问磁盘', {
                              'bytes': formatBytes(snapshot!.totalBytes),
                            }),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: BroomColors.inkMuted(context),
                      ),
                    ),
                  ],
                ),
              ),
              if (loading && snapshot == null)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (emptying) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: const LinearProgressIndicator(minHeight: 4),
            ),
            const SizedBox(height: 6),
            Text(
              context.t('正在通知系统清空回收站…'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.inkMuted(context),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              LucideIcons.shieldCheck,
              size: 13,
              color: BroomColors.inkFaint(context),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              context.t(
                '缓存清理使用 Broom 自己的隔离区，可以撤销。回收站由桌面环境管理，'
                'Broom 只读取统计并调用系统清空命令，不读取其中的文件内容。',
              ),
              style: theme.textTheme.labelSmall?.copyWith(
                color: BroomColors.inkFaint(context),
                height: 1.55,
              ),
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
      icon: Icon(LucideIcons.trash2, size: 30, color: scheme.error),
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
            context.t('此操作覆盖用户回收站及可访问磁盘上的回收站内容，无法撤销，也不会进入 Broom 隔离区。'),
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
