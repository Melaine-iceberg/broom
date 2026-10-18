import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/clean/quarantine_service.dart';
import '../core/models/clean_models.dart';
import '../core/shell/system_shell.dart';
import 'analysis_widgets.dart';
import 'format.dart';

class QuarantinePage extends StatefulWidget {
  const QuarantinePage({super.key, required this.service, required this.shell});

  final QuarantineService service;
  final SystemShell shell;

  @override
  State<QuarantinePage> createState() => _QuarantinePageState();
}

class _QuarantinePageState extends State<QuarantinePage> {
  List<QuarantineSessionInfo> _sessions = const [];
  DiskSpaceSnapshot? _disk;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  int get _pendingBytes =>
      _sessions.fold<int>(0, (total, session) => total + session.pendingBytes);

  int get _pendingFiles =>
      _sessions.fold<int>(0, (total, session) => total + session.pendingCount);

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
      final sessions = await widget.service.listSessions();
      DiskSpaceSnapshot? disk;
      try {
        final root = p.windows.rootPrefix(widget.service.quarantineRoot);
        disk = await widget.shell.queryDiskSpace(
          root.isEmpty ? widget.service.quarantineRoot : root,
        );
      } catch (_) {
        disk = null;
      }
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _disk = disk;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '无法读取隔离区：$error';
        _loading = false;
      });
    }
  }

  Future<void> _restoreAll(QuarantineSessionInfo session) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.undo(session.id);
      await _load(showLoading: false);
      if (!mounted) return;
      _showMessage(_restoreMessage(report));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '恢复失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge(QuarantineSessionInfo session) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PurgeConfirmDialog(
        title: '永久释放这次清理？',
        fileCount: session.pendingCount,
        bytes: session.pendingBytes,
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.purgeSession(session.id);
      await _load(showLoading: false);
      if (!mounted) return;
      _showMessage(_purgeMessage(report));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '释放失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeAll() async {
    if (_busy || _sessions.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PurgeConfirmDialog(
        title: '永久释放整个隔离区？',
        fileCount: _pendingFiles,
        bytes: _pendingBytes,
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.purgeAllSessions();
      await _load(showLoading: false);
      if (!mounted) return;
      _showMessage(_purgeMessage(report));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '释放失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSession(QuarantineSessionInfo session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            QuarantineSessionPage(service: widget.service, session: session),
      ),
    );
    if (!mounted) return;
    await _load(showLoading: false);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
          tooltip: '返回',
        ),
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('隔离区'),
            const SizedBox(height: 1),
            Text(
              '恢复文件，或永久释放磁盘空间',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loading || _busy
                ? null
                : () => _load(showLoading: false),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
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
              _SummaryCard(
                pendingBytes: _pendingBytes,
                pendingFiles: _pendingFiles,
                sessionCount: _sessions.length,
                disk: _disk,
                busy: _busy,
                onPurgeAll: _sessions.isEmpty ? null : _purgeAll,
              ),
              if (_loading) ...[
                const SizedBox(height: 18),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  Icon(Icons.restore_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text('待处理清理', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (_sessions.isNotEmpty)
                    Text(
                      '${formatCount(_sessions.length)} 次会话',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (!_loading && _sessions.isEmpty)
                const _EmptyState()
              else
                for (final session in _sessions) ...[
                  _SessionCard(
                    session: session,
                    busy: _busy,
                    onOpen: () => _openSession(session),
                    onRestore: () => _restoreAll(session),
                    onPurge: () => _purge(session),
                  ),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 12),
              const _PolicyNote(),
            ],
          ),
        ),
      ),
    );
  }
}

class QuarantineSessionPage extends StatefulWidget {
  const QuarantineSessionPage({
    super.key,
    required this.service,
    required this.session,
  });

  final QuarantineService service;
  final QuarantineSessionInfo session;

  @override
  State<QuarantineSessionPage> createState() => _QuarantineSessionPageState();
}

class _QuarantineSessionPageState extends State<QuarantineSessionPage> {
  List<QuarantineEntry> _entries = const [];
  final Set<String> _selected = <String>{};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  int get _remainingCount => _entries.where((entry) => entry.restorable).length;

  int get _remainingBytes => _entries
      .where((entry) => entry.restorable)
      .fold<int>(0, (total, entry) => total + entry.size);

  int get _selectableCount => _entries
      .where((entry) => entry.restorable && !entry.originalExists)
      .length;

  int get _selectedBytes => _entries
      .where((entry) => _selected.contains(entry.storedName))
      .fold<int>(0, (total, entry) => total + entry.size);

  bool _canSelect(QuarantineEntry entry) =>
      entry.restorable && !entry.originalExists;

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
      final entries = await widget.service.listEntries(widget.session.id);
      entries.sort((a, b) {
        int rank(QuarantineEntry entry) {
          if (entry.restored) return 3;
          if (!entry.present) return 2;
          if (entry.originalExists) return 1;
          return 0;
        }

        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        return a.originalPath.compareTo(b.originalPath);
      });
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _selected.removeWhere(
          (name) => !entries.any(
            (entry) => entry.storedName == name && _canSelect(entry),
          ),
        );
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '无法读取隔离区文件：$error';
        _loading = false;
      });
    }
  }

  void _toggle(String storedName) {
    setState(() {
      if (!_selected.add(storedName)) {
        _selected.remove(storedName);
      }
    });
  }

  void _toggleAll() {
    final selectable = _entries
        .where(_canSelect)
        .map((entry) => entry.storedName)
        .toSet();
    setState(() {
      if (_selected.length == selectable.length && selectable.isNotEmpty) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(selectable);
      }
    });
  }

  Future<void> _restoreSelected() async {
    if (_busy || _selected.isEmpty) return;
    await _restore(storedNames: {..._selected});
  }

  Future<void> _restoreAll() async {
    if (_busy) return;
    await _restore();
  }

  Future<void> _restore({Set<String>? storedNames}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.undo(
        widget.session.id,
        storedNames: storedNames,
      );
      if (!mounted) return;
      await _showRestoreResult(report);
      if (!mounted) return;
      if (report.sessionRemoved) {
        Navigator.of(context).pop();
        return;
      }
      await _load(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '恢复失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PurgeConfirmDialog(
        title: '永久释放剩余文件？',
        fileCount: _remainingCount,
        bytes: _remainingBytes,
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.purgeSession(widget.session.id);
      if (!mounted) return;
      if (report.complete) {
        Navigator.of(context).pop();
        return;
      }
      await _load(showLoading: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已释放 ${report.removedCount} 个文件，'
            '${report.failureCount} 个文件释放失败。',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '释放失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRestoreResult(UndoReport report) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          report.restoredCount > 0
              ? Icons.restore_rounded
              : Icons.info_outline_rounded,
          size: 30,
        ),
        title: Text(
          report.restoredCount > 0
              ? '已恢复 ${report.restoredCount} 个文件'
              : '没有文件恢复',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('共 ${formatBytes(report.restoredBytes)} 已放回原位置。'),
            if (report.conflictCount > 0) ...[
              const SizedBox(height: 8),
              Text('${report.conflictCount} 个文件的原位置已有新内容，已跳过，不会覆盖。'),
            ],
            if (report.failureCount > 0) ...[
              const SizedBox(height: 8),
              Text('${report.failureCount} 个文件恢复失败，仍保留在隔离区。'),
            ],
            if (!report.sessionRemoved) ...[
              const SizedBox(height: 8),
              Text(
                '仍有文件保留在隔离区，可稍后重试。',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = formatDateTime(widget.session.createdAt.toLocal());
    final allSelected =
        _selectableCount > 0 && _selected.length == _selectableCount;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: '返回',
        ),
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('隔离区文件'),
            const SizedBox(height: 1),
            Text(
              '清理于 $date',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loading || _busy
                ? null
                : () => _load(showLoading: false),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error case final error?) ...[
                  AnalysisBanner(
                    message: error,
                    isError: true,
                    onClose: () => setState(() => _error = null),
                  ),
                  const SizedBox(height: 12),
                ],
                _SessionDetailHeader(
                  pendingCount: _remainingCount,
                  pendingBytes: _remainingBytes,
                  busy: _busy,
                  onPurge: _purge,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _entries.isEmpty
                      ? const _EmptyEntries()
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final entry = _entries[index];
                            return _EntryTile(
                              entry: entry,
                              selected: _selected.contains(entry.storedName),
                              enabled: _canSelect(entry) && !_busy,
                              onToggle: () => _toggle(entry.storedName),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                _SessionActionBar(
                  selectedCount: _selected.length,
                  selectedBytes: _selectedBytes,
                  busy: _busy,
                  allSelected: allSelected,
                  onToggleAll: _selectableCount == 0 ? null : _toggleAll,
                  onRestoreSelected: _selected.isEmpty || _busy
                      ? null
                      : _restoreSelected,
                  onRestoreAll: _remainingCount == 0 || _busy
                      ? null
                      : _restoreAll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.pendingBytes,
    required this.pendingFiles,
    required this.sessionCount,
    required this.disk,
    required this.busy,
    required this.onPurgeAll,
  });

  final int pendingBytes;
  final int pendingFiles;
  final int sessionCount;
  final DiskSpaceSnapshot? disk;
  final bool busy;
  final VoidCallback? onPurgeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(26, 26, 26, 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer.withValues(alpha: 0.7),
            scheme.surfaceContainerLow,
          ],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.035),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  Icons.restore_rounded,
                  size: 23,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pendingFiles == 0
                          ? '隔离区是空的'
                          : '隔离区暂存了 ${formatBytes(pendingBytes)}',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pendingFiles == 0
                          ? '清理过的文件会先放在这里，随时可以恢复。'
                          : '$pendingFiles 个文件 · $sessionCount 次清理。'
                                '文件仍占用磁盘空间，永久释放后才会腾出空间。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MetricChip(
                icon: Icons.inventory_2_outlined,
                label: '暂存占用',
                value: formatBytes(pendingBytes),
              ),
              _MetricChip(
                icon: Icons.restore_rounded,
                label: '待恢复',
                value: '${formatCount(pendingFiles)} 个文件',
              ),
              if (disk != null)
                _MetricChip(
                  icon: Icons.sd_storage_outlined,
                  label: '磁盘可用',
                  value: formatBytes(disk!.freeBytes),
                ),
            ],
          ),
          if (onPurgeAll != null) ...[
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onPurgeAll,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  disabledBackgroundColor: scheme.error.withValues(alpha: 0.12),
                ),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_forever_rounded, size: 19),
                label: const Text('全部永久释放'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(
            '$label ',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.busy,
    required this.onOpen,
    required this.onRestore,
    required this.onPurge,
  });

  final QuarantineSessionInfo session;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final partial = session.status == QuarantineStatus.partial;

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
        child: Column(
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
                    Icons.inventory_2_outlined,
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
                          Text(
                            formatDateTime(session.createdAt.toLocal()),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _StatusChip(partial: partial),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${formatCount(session.pendingCount)} 个文件 · '
                        '${formatBytes(session.pendingBytes)} 待处理',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onOpen,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('查看文件'),
                      SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded, size: 17),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onRestore,
                  icon: const Icon(Icons.restore_rounded, size: 17),
                  label: const Text('恢复全部'),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: busy ? null : onPurge,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  icon: const Icon(Icons.delete_forever_rounded, size: 17),
                  label: const Text('永久释放'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.partial});

  final bool partial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: (partial ? scheme.tertiaryContainer : scheme.primaryContainer)
            .withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        partial ? '部分可恢复' : '可恢复',
        style: theme.textTheme.labelSmall?.copyWith(
          color: partial
              ? scheme.onTertiaryContainer
              : scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SessionDetailHeader extends StatelessWidget {
  const _SessionDetailHeader({
    required this.pendingCount,
    required this.pendingBytes,
    required this.busy,
    required this.onPurge,
  });

  final int pendingCount;
  final int pendingBytes;
  final bool busy;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 15, 14, 15),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 19,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$pendingCount 个文件 · ${formatBytes(pendingBytes)} 仍在隔离区。'
              '恢复不会覆盖原位置已有文件；永久释放后无法找回。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: busy ? null : onPurge,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: const Icon(Icons.delete_forever_rounded, size: 17),
            label: const Text('永久删除剩余'),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  final QuarantineEntry entry;
  final bool selected;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (:label, :color) = switch (entry) {
      QuarantineEntry(restored: true) => (
        label: '已恢复',
        color: scheme.onSurfaceVariant,
      ),
      QuarantineEntry(present: false) => (label: '隔离文件缺失', color: scheme.error),
      QuarantineEntry(originalExists: true) => (
        label: '原位置已有文件',
        color: scheme.tertiary,
      ),
      _ => (label: '可恢复', color: scheme.primary),
    };

    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.22)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.2)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onToggle : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 9, 14, 9),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: enabled ? (_) => onToggle() : null,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.insert_drive_file_outlined,
                size: 18,
                color: enabled ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileNameOf(entry.originalPath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Tooltip(
                      message: entry.originalPath,
                      child: Text(
                        p.windows.dirname(entry.originalPath),
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
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatBytes(entry.size),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionActionBar extends StatelessWidget {
  const _SessionActionBar({
    required this.selectedCount,
    required this.selectedBytes,
    required this.busy,
    required this.allSelected,
    required this.onToggleAll,
    required this.onRestoreSelected,
    required this.onRestoreAll,
  });

  final int selectedCount;
  final int selectedBytes;
  final bool busy;
  final bool allSelected;
  final VoidCallback? onToggleAll;
  final VoidCallback? onRestoreSelected;
  final VoidCallback? onRestoreAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                selectedCount == 0 ? '未选择文件' : '已选 $selectedCount 个文件',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (selectedCount > 0)
                Text(
                  formatBytes(selectedBytes),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : onToggleAll,
                child: Text(allSelected ? '取消全选' : '全选可恢复'),
              ),
              OutlinedButton.icon(
                onPressed: onRestoreSelected,
                icon: const Icon(Icons.restore_rounded, size: 17),
                label: const Text('恢复选中'),
              ),
              FilledButton.icon(
                onPressed: onRestoreAll,
                icon: const Icon(Icons.restore_page_rounded, size: 17),
                label: const Text('恢复全部'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        children: [
          Icon(Icons.restore_rounded, size: 42, color: scheme.primary),
          const SizedBox(height: 12),
          Text('没有待处理的清理', style: theme.textTheme.titleMedium),
          const SizedBox(height: 5),
          Text(
            '完成一次清理后，文件会暂存在这里。你可以随时恢复它们，或永久释放空间。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyEntries extends StatelessWidget {
  const _EmptyEntries();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Text(
        '没有可显示的文件记录。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            Icons.lock_outline_rounded,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '隔离区文件只保存在本机。恢复时不会覆盖原位置后来新建的文件；'
            '永久释放是不可撤销的操作，页面会再次要求确认。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _PurgeConfirmDialog extends StatefulWidget {
  const _PurgeConfirmDialog({
    required this.title,
    required this.fileCount,
    required this.bytes,
  });

  final String title;
  final int fileCount;
  final int bytes;

  @override
  State<_PurgeConfirmDialog> createState() => _PurgeConfirmDialogState();
}

class _PurgeConfirmDialogState extends State<_PurgeConfirmDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, size: 30, color: scheme.error),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '将永久删除 ${widget.fileCount} 个文件，'
            '共 ${formatBytes(widget.bytes)}。',
          ),
          const SizedBox(height: 8),
          Text(
            '删除后无法恢复，也不会放回原位置。文件当前仍占用磁盘空间，'
            '释放后这部分空间才会真正回收。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            key: const ValueKey('purge-confirm-checkbox'),
            value: _acknowledged,
            onChanged: (value) =>
                setState(() => _acknowledged = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '我明白这些文件将被永久删除，且无法恢复',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('purge-confirm-button'),
          onPressed: _acknowledged
              ? () => Navigator.of(context).pop(true)
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
            disabledBackgroundColor: scheme.error.withValues(alpha: 0.12),
          ),
          child: const Text('永久释放'),
        ),
      ],
    );
  }
}

String _restoreMessage(UndoReport report) {
  final parts = <String>['已恢复 ${report.restoredCount} 个文件'];
  if (report.conflictCount > 0) {
    parts.add('${report.conflictCount} 个原位置已有文件，已跳过');
  }
  if (report.failureCount > 0) {
    parts.add('${report.failureCount} 个恢复失败');
  }
  return parts.join('；');
}

String _purgeMessage(QuarantinePurgeReport report) {
  if (report.complete) {
    return '已永久释放 ${report.removedCount} 个文件'
        '（${formatBytes(report.removedBytes)}）。';
  }
  return '已释放 ${report.removedCount} 个文件'
      '（${formatBytes(report.removedBytes)}），'
      '${report.failureCount} 个文件未能释放。';
}
