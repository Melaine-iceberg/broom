import 'package:flutter/material.dart';

import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'clean_controller.dart';
import 'glass_ui.dart';

class ExclusionsPage extends StatefulWidget {
  const ExclusionsPage({
    super.key,
    required this.controller,
    required this.shell,
  });

  final CleanController controller;
  final SystemShell shell;

  @override
  State<ExclusionsPage> createState() => _ExclusionsPageState();
}

class _ExclusionsPageState extends State<ExclusionsPage> {
  bool _busy = false;

  CleanController get controller => widget.controller;

  Future<void> _pickAndAdd() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await widget.shell.pickFolder();
      if (path == null || !mounted) return;
      final error = await controller.addExclusion(path);
      if (!mounted) return;
      if (error != null) {
        _showMessage(error, isError: true);
      } else {
        _showMessage(context.tf('已排除：{path}', {'path': path}));
      }
    } on SystemShellException catch (error) {
      if (mounted) _showMessage(error.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String path) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final error = await controller.removeExclusion(path);
      if (!mounted) return;
      _showMessage(error ?? context.t('已移除排除项'), isError: error != null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded, size: 30),
        title: Text(context.t('重置排除列表？')),
        content: Text(
          context.t(
            '保存的排除项会被清空，文件夹本身不会受到影响。'
            '之后这些目录会重新参与扫描。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.t('重置')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final error = await controller.resetExclusions();
      if (!mounted) return;
      _showMessage(error ?? context.t('排除列表已重置'), isError: error != null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: isError
              ? Theme.of(context).colorScheme.errorContainer
              : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final paths = controller.exclusions.paths;
        final loadError = controller.exclusionError;

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: context.t('返回'),
            ),
            toolbarHeight: 76,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.t('排除列表')),
                const SizedBox(height: 1),
                Text(
                  paths.isEmpty
                      ? context.t('没有排除项')
                      : context.tf('{count} 个目录不参与扫描', {'count': paths.length}),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 6, 28, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _InfoCard(scheme: scheme, theme: theme),
                    if (loadError != null) ...[
                      const SizedBox(height: 12),
                      _LoadErrorBanner(
                        message: loadError,
                        onReset: _busy ? null : _reset,
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Icon(
                          Icons.block_rounded,
                          size: 19,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 9),
                        Text(
                          context.t('排除项'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${paths.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          key: const ValueKey('add-exclusion'),
                          onPressed: _busy || loadError != null
                              ? null
                              : _pickAndAdd,
                          icon: _busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.add_rounded, size: 18),
                          label: Text(context.t('添加文件夹')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: BroomColors.card(context),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: BroomColors.cardShadow(context),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: paths.isEmpty
                            ? _EmptyState(
                                hasError: loadError != null,
                                onReset: _busy ? null : _reset,
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                itemCount: paths.length,
                                separatorBuilder: (context, index) => Divider(
                                  height: 1,
                                  indent: 58,
                                  endIndent: 12,
                                  color: scheme.outlineVariant.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                itemBuilder: (context, index) {
                                  final path = paths[index];
                                  return _ExclusionRow(
                                    path: path,
                                    onRemove: _busy
                                        ? null
                                        : () => _remove(path),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.t('排除只影响 Broom 的扫描、清理与撤销校验，不会移动或删除任何文件。'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.t(
                '排除优先于所有 Safe 规则。被排除目录及其子目录不会出现在扫描结果中，'
                '清理与撤销也会再次校验。规则根目录位于排除项之下时，该规则不会参与扫描。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadErrorBanner extends StatelessWidget {
  const _LoadErrorBanner({required this.message, required this.onReset});

  final String message;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.error.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.tf('{message}\n为避免清理被排除的目录，扫描已暂停。请重置排除列表后重试。', {
                'message': message,
              }),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onErrorContainer, height: 1.45),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('reset-exclusions'),
            onPressed: onReset,
            child: Text(context.t('重置')),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasError, required this.onReset});

  final bool hasError;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasError
                  ? Icons.report_gmailerrorred_rounded
                  : Icons.folder_off_outlined,
              size: 38,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              hasError ? context.t('排除列表无法读取') : context.t('尚未添加排除项'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 5),
            Text(
              hasError
                  ? context.t('重置后可以重新添加排除目录。')
                  : context.t('选择一个不希望 Broom 触碰的文件夹。'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (hasError) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
                label: Text(context.t('重置排除列表')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExclusionRow extends StatelessWidget {
  const _ExclusionRow({required this.path, required this.onRemove});

  final String path;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.folder_off_outlined,
              size: 17,
              color: scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Tooltip(
              message: path,
              child: Text(
                path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: onRemove,
            tooltip: context.t('移除排除项'),
            icon: const Icon(Icons.close_rounded, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
