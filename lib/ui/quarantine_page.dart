import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/clean/quarantine_retention_service.dart';
import '../core/clean/quarantine_service.dart';
import '../core/models/clean_models.dart';
import '../core/models/quarantine_policy_models.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'format.dart';
import 'quarantine_policy_dialog.dart';

class QuarantinePage extends StatefulWidget {
  const QuarantinePage({
    super.key,
    required this.service,
    required this.shell,
    this.retention,
  });

  final QuarantineService service;
  final SystemShell shell;
  final QuarantineRetentionService? retention;

  @override
  State<QuarantinePage> createState() => _QuarantinePageState();
}

class _QuarantinePageState extends State<QuarantinePage> {
  List<QuarantineSessionInfo> _sessions = const [];
  DiskSpaceSnapshot? _disk;
  QuarantineRetentionPolicy? _policy;
  QuarantineRetentionReport? _lastRetentionReport;
  String? _policyError;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  CleanProgress? _resumeProgress;
  bool _resumeCancelRequested = false;

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
      QuarantineRetentionPolicy? policy;
      QuarantineRetentionReport? retentionReport;
      String? policyError;
      final retention = widget.retention;
      if (retention != null) {
        await retention.ensureInitialized();
        policy = retention.policy;
        retentionReport = retention.lastReport;
        policyError = retention.loadError;
      }

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
        _policy = policy;
        _lastRetentionReport = retentionReport;
        _policyError = policyError;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = trf('无法读取隔离区：{error}', {'error': error});
        _loading = false;
      });
    }
  }

  Future<void> _restoreAll(QuarantineSessionInfo session) async {
    if (_busy) return;

    UndoConflictPolicy policy;
    try {
      final entries = await widget.service.listEntries(session.id);
      final conflicts = entries
          .where((entry) => entry.restorable && entry.originalExists)
          .length;
      if (!mounted) return;
      final choice = await _askConflictPolicy(context, conflicts);
      if (choice == null || !mounted) return;
      policy = choice;
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = trf('恢复失败：{error}', {'error': error}));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.undo(
        session.id,
        conflictPolicy: policy,
      );
      await _load(showLoading: false);
      if (!mounted) return;
      _showMessage(_restoreMessage(report));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = trf('恢复失败：{error}', {'error': error}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resume(QuarantineSessionInfo session) async {
    if (_busy || !session.resumable) return;
    if (!await _confirmResume(context, session.remainingCount)) return;
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _resumeCancelRequested = false;
      _resumeProgress = CleanProgress(
        moved: 0,
        processed: 0,
        total: session.remainingCount,
        movedBytes: 0,
      );
    });
    try {
      final report = await widget.service.resumeClean(
        session.id,
        onProgress: (progress) {
          if (mounted) setState(() => _resumeProgress = progress);
        },
        isCancelled: () => _resumeCancelRequested,
      );
      await _load(showLoading: false);
      if (!mounted) return;
      _showMessage(_resumeMessage(report));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = trf('继续清理失败：{error}', {'error': error}));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _resumeProgress = null;
        });
      }
    }
  }

  Future<void> _purge(QuarantineSessionInfo session) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PurgeConfirmDialog(
        title: context.t('永久释放这次清理？'),
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
      setState(() => _error = trf('释放失败：{error}', {'error': error}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeAll() async {
    if (_busy || _sessions.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PurgeConfirmDialog(
        title: context.t('永久释放整个隔离区？'),
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
      setState(() => _error = trf('释放失败：{error}', {'error': error}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editPolicy() async {
    final retention = widget.retention;
    if (retention == null || _busy) return;

    await retention.ensureInitialized();
    if (!mounted) return;
    final updated = await showQuarantinePolicyDialog(
      context,
      policy: retention.policy ?? QuarantineRetentionPolicy.defaults,
    );
    if (updated == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await retention.save(updated);
      await _load(showLoading: false);
      if (!mounted) return;
      if (report == null || !report.didPurge) {
        _showMessage(
          updated.enabled ? context.t('保留策略已保存。') : context.t('自动永久释放已关闭。'),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = trf('无法保存保留策略：{error}', {'error': error}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _dismissRetentionReport() {
    widget.retention?.clearLastReport();
    setState(() => _lastRetentionReport = null);
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
          tooltip: context.t('返回'),
        ),
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('隔离区')),
            const SizedBox(height: 1),
            Text(
              context.t('恢复文件，或永久释放磁盘空间'),
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
              if (_policyError case final message?) ...[
                AnalysisBanner(
                  message: context.tf('保留策略读取失败，自动永久释放已停用：{error}', {
                    'error': message,
                  }),
                  isError: true,
                ),
                const SizedBox(height: 12),
              ],
              if (_lastRetentionReport case final report?
                  when report.didPurge) ...[
                AnalysisBanner(
                  message: _retentionReportMessage(report),
                  onClose: _dismissRetentionReport,
                ),
                const SizedBox(height: 12),
              ],
              if (_resumeProgress case final progress?) ...[
                _ResumeProgressCard(
                  progress: progress,
                  stopping: _resumeCancelRequested,
                  onStop: () => setState(() => _resumeCancelRequested = true),
                ),
                const SizedBox(height: 12),
              ],
              _SummaryCard(
                pendingBytes: _pendingBytes,
                pendingFiles: _pendingFiles,
                sessionCount: _sessions.length,
                resumableSessions: _sessions
                    .where((session) => session.resumable)
                    .length,
                disk: _disk,
                policy: _policy,
                busy: _busy,
                onEditPolicy: widget.retention == null ? null : _editPolicy,
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
                  Text(context.t('待处理清理'), style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (_sessions.isNotEmpty)
                    Text(
                      context.tf('{count} 次会话', {
                        'count': formatCount(_sessions.length),
                      }),
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
                    onResume: session.resumable ? () => _resume(session) : null,
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
  late QuarantineSessionInfo _session;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  CleanProgress? _resumeProgress;
  bool _resumeCancelRequested = false;

  int get _restorableCount =>
      _entries.where((entry) => entry.restorable).length;

  int get _selectableCount => _restorableCount;

  int get _pendingCount =>
      _entries.where((entry) => !entry.restored && entry.present).length;

  int get _pendingBytes => _entries
      .where((entry) => !entry.restored && entry.present)
      .fold<int>(0, (total, entry) => total + entry.size);

  int get _integrityFailureCount => _entries
      .where((entry) => !entry.restored && entry.integrityFailure != null)
      .length;

  int get _selectedBytes => _entries
      .where((entry) => _selected.contains(entry.storedName))
      .fold<int>(0, (total, entry) => total + entry.size);

  bool _canSelect(QuarantineEntry entry) => entry.restorable;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _loading = true);
    }
    try {
      final session = await widget.service.getSession(widget.session.id);
      final entries = await widget.service.listEntries(widget.session.id);
      entries.sort((a, b) {
        int rank(QuarantineEntry entry) {
          if (entry.restored) return 4;
          if (!entry.present) return 3;
          if (entry.integrityFailure != null) return 2;
          if (entry.originalExists) return 1;
          return 0;
        }

        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        return a.originalPath.compareTo(b.originalPath);
      });
      if (!mounted) return;
      setState(() {
        _session = session;
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
        _error = trf('无法读取隔离区文件：{error}', {'error': error});
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

  Future<void> _resume() async {
    if (_busy || !_session.resumable) return;
    if (!await _confirmResume(context, _session.remainingCount)) return;
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _resumeCancelRequested = false;
      _resumeProgress = CleanProgress(
        moved: 0,
        processed: 0,
        total: _session.remainingCount,
        movedBytes: 0,
      );
    });
    try {
      final report = await widget.service.resumeClean(
        _session.id,
        onProgress: (progress) {
          if (mounted) setState(() => _resumeProgress = progress);
        },
        isCancelled: () => _resumeCancelRequested,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_resumeMessage(report))));
      if (report.sessionId == null) {
        Navigator.of(context).pop();
        return;
      }
      await _load(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = trf('继续清理失败：{error}', {'error': error}));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _resumeProgress = null;
        });
      }
    }
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
    final conflicts = _entries
        .where(
          (entry) =>
              entry.restorable &&
              entry.originalExists &&
              (storedNames == null || storedNames.contains(entry.storedName)),
        )
        .length;
    final policy = await _askConflictPolicy(context, conflicts);
    if (policy == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.service.undo(
        widget.session.id,
        storedNames: storedNames,
        conflictPolicy: policy,
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
      setState(() => _error = trf('恢复失败：{error}', {'error': error}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purge() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PurgeConfirmDialog(
        title: context.t('永久释放剩余文件？'),
        fileCount: _pendingCount,
        bytes: _pendingBytes,
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
            trf('已释放 {removed} 个文件，{failed} 个文件释放失败。', {
              'removed': report.removedCount,
              'failed': report.failureCount,
            }),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = trf('释放失败：{error}', {'error': error}));
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
              ? context.tf('已恢复 {count} 个文件', {'count': report.restoredCount})
              : context.t('没有文件恢复'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tf('共 {bytes} 已放回原位置。', {
                'bytes': formatBytes(report.restoredBytes),
              }),
            ),
            if (report.keptBothCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                context.tf('{count} 个文件以新名称恢复，原位置的文件保持不变。', {
                  'count': report.keptBothCount,
                }),
              ),
            ],
            if (report.overwrittenCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                context.tf('{count} 个文件已覆盖原位置内容。', {
                  'count': report.overwrittenCount,
                }),
              ),
            ],
            if (report.conflictCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                context.tf(
                  '{count} 个文件的原位置已有新内容，本次已跳过。'
                  '可再次恢复并选择“保留两者”或“覆盖”。',
                  {'count': report.conflictCount},
                ),
              ),
            ],
            if (report.integrityFailureCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                context.tf(
                  '{count} 个文件未通过完整性校验，'
                  '已跳过恢复，仍保留在隔离区。',
                  {'count': report.integrityFailureCount},
                ),
              ),
            ],
            if (report.failureCount > report.integrityFailureCount) ...[
              const SizedBox(height: 8),
              Text(
                context.tf('{count} 个文件恢复失败，仍保留在隔离区。', {
                  'count': report.failureCount - report.integrityFailureCount,
                }),
              ),
            ],
            if (report.metadataFailureCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                context.tf('{count} 个文件的内容已恢复，但时间戳、只读属性或 ACL 未能完全还原。', {
                  'count': report.metadataFailureCount,
                }),
              ),
            ],
            if (!report.sessionRemoved) ...[
              const SizedBox(height: 8),
              Text(
                context.t('仍有文件保留在隔离区，可稍后重试。'),
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
            child: Text(context.t('知道了')),
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
          tooltip: context.t('返回'),
        ),
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t('隔离区文件')),
            const SizedBox(height: 1),
            Text(
              context.tf('清理于 {date}', {'date': date}),
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
            tooltip: context.t('刷新'),
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
                if (_integrityFailureCount > 0) ...[
                  AnalysisBanner(
                    message: context.tf(
                      '{count} 个隔离文件未通过完整性校验，'
                      '已禁止恢复。可以永久释放这些文件。',
                      {'count': _integrityFailureCount},
                    ),
                    isError: true,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_resumeProgress case final progress?) ...[
                  _ResumeProgressCard(
                    progress: progress,
                    stopping: _resumeCancelRequested,
                    onStop: () => setState(() => _resumeCancelRequested = true),
                  ),
                  const SizedBox(height: 12),
                ] else if (!_loading && _session.resumable) ...[
                  _ResumeBanner(
                    remainingCount: _session.remainingCount,
                    busy: _busy,
                    onResume: _resume,
                  ),
                  const SizedBox(height: 12),
                ],
                _SessionDetailHeader(
                  pendingCount: _pendingCount,
                  pendingBytes: _pendingBytes,
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
                  onRestoreAll: _restorableCount == 0 || _busy
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
    required this.resumableSessions,
    required this.disk,
    required this.policy,
    required this.busy,
    required this.onEditPolicy,
    required this.onPurgeAll,
  });

  final int pendingBytes;
  final int pendingFiles;
  final int sessionCount;
  final int resumableSessions;
  final DiskSpaceSnapshot? disk;
  final QuarantineRetentionPolicy? policy;
  final bool busy;
  final VoidCallback? onEditPolicy;
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
                          ? context.t('隔离区是空的')
                          : context.tf('隔离区暂存了 {bytes}', {
                              'bytes': formatBytes(pendingBytes),
                            }),
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pendingFiles == 0
                          ? context.t('清理过的文件会先放在这里，随时可以恢复。')
                          : context.tf(
                              '{files} 个文件 · {sessions} 次清理。'
                              '文件仍占用磁盘空间，永久释放后才会腾出空间。',
                              {'files': pendingFiles, 'sessions': sessionCount},
                            ),
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
                label: context.t('暂存占用'),
                value: formatBytes(pendingBytes),
              ),
              _MetricChip(
                icon: Icons.restore_rounded,
                label: context.t('待处理'),
                value: context.tf('{count} 个文件', {
                  'count': formatCount(pendingFiles),
                }),
              ),
              if (resumableSessions > 0)
                _MetricChip(
                  icon: Icons.play_circle_outline_rounded,
                  label: context.t('可继续清理'),
                  value: context.tf('{count} 次', {
                    'count': formatCount(resumableSessions),
                  }),
                ),
              if (disk != null)
                _MetricChip(
                  icon: Icons.sd_storage_outlined,
                  label: context.t('磁盘可用'),
                  value: formatBytes(disk!.freeBytes),
                ),
            ],
          ),
          if (policy case final policy?) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.52),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_delete_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      policy.enabled
                          ? context.tf('自动永久释放：保留 {days} 天 · 上限 {bytes}', {
                              'days': policy.retentionDays,
                              'bytes': formatBytes(policy.maxBytes),
                            })
                          : context.t('自动永久释放未开启'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (onEditPolicy != null)
                    TextButton(
                      key: const ValueKey('retention-policy-button'),
                      onPressed: busy ? null : onEditPolicy,
                      child: Text(
                        policy.enabled ? context.t('调整策略') : context.t('设置策略'),
                      ),
                    ),
                ],
              ),
            ),
          ],
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
                label: Text(context.t('全部永久释放')),
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
    required this.onResume,
    required this.onRestore,
    required this.onPurge,
  });

  final QuarantineSessionInfo session;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback? onResume;
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
                          _StatusChip(
                            partial: partial,
                            resumable: session.resumable,
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        session.resumable
                            ? context.tf(
                                '{files} 个文件已暂存 · 还有 {remaining} 个未处理',
                                {
                                  'files': formatCount(session.pendingCount),
                                  'remaining': formatCount(
                                    session.remainingCount,
                                  ),
                                },
                              )
                            : context.tf('{files} 个文件 · {bytes} 待处理', {
                                'files': formatCount(session.pendingCount),
                                'bytes': formatBytes(session.pendingBytes),
                              }),
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(context.t('查看文件')),
                      const SizedBox(width: 2),
                      const Icon(Icons.chevron_right_rounded, size: 17),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 2,
              children: [
                if (onResume != null)
                  TextButton.icon(
                    key: const ValueKey('resume-clean-button'),
                    onPressed: busy ? null : onResume,
                    icon: const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 17,
                    ),
                    label: Text(context.t('继续清理')),
                  ),
                TextButton.icon(
                  onPressed: busy || session.pendingCount == 0
                      ? null
                      : onRestore,
                  icon: const Icon(Icons.restore_rounded, size: 17),
                  label: Text(context.t('恢复全部')),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onPurge,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  icon: const Icon(Icons.delete_forever_rounded, size: 17),
                  label: Text(context.t('永久释放')),
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
  const _StatusChip({required this.partial, required this.resumable});

  final bool partial;
  final bool resumable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final container = resumable
        ? scheme.primaryContainer
        : partial
        ? scheme.tertiaryContainer
        : scheme.primaryContainer;
    final foreground = resumable
        ? scheme.onPrimaryContainer
        : partial
        ? scheme.onTertiaryContainer
        : scheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: container.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        resumable
            ? context.t('待继续清理')
            : partial
            ? context.t('部分可恢复')
            : context.t('可恢复'),
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
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
              context.tf(
                '{count} 个文件 · {bytes} 仍在隔离区。'
                '冲突文件可选择跳过、保留两者或覆盖；永久释放后无法找回。',
                {'count': pendingCount, 'bytes': formatBytes(pendingBytes)},
              ),
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
            label: Text(context.t('永久删除剩余')),
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
        label: context.t('已恢复'),
        color: scheme.onSurfaceVariant,
      ),
      QuarantineEntry(present: false) => (
        label: context.t('隔离文件缺失'),
        color: scheme.error,
      ),
      QuarantineEntry(integrityFailure: _?) => (
        label: context.t('完整性异常'),
        color: scheme.error,
      ),
      QuarantineEntry(originalExists: true) => (
        label: context.t('原位置已有文件'),
        color: scheme.tertiary,
      ),
      _ => (label: context.t('可恢复'), color: scheme.primary),
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
                  Tooltip(
                    message: entry.integrityFailure ?? label,
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                    ),
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
                selectedCount == 0
                    ? context.t('未选择文件')
                    : context.tf('已选 {count} 个文件', {'count': selectedCount}),
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
                child: Text(
                  allSelected ? context.t('取消全选') : context.t('全选可恢复'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: onRestoreSelected,
                icon: const Icon(Icons.restore_rounded, size: 17),
                label: Text(context.t('恢复选中')),
              ),
              FilledButton.icon(
                onPressed: onRestoreAll,
                icon: const Icon(Icons.restore_page_rounded, size: 17),
                label: Text(context.t('恢复全部')),
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
          Text(context.t('没有待处理的清理'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 5),
          Text(
            context.t('完成一次清理后，文件会暂存在这里。你可以随时恢复它们，或永久释放空间。'),
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
        context.t('没有可显示的文件记录。'),
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
            context.t(
              '隔离区文件只保存在本机。恢复遇到同名文件时可选择跳过、保留两者或覆盖；'
              '覆盖需要二次确认。永久释放是不可撤销的操作，页面会再次要求确认。',
            ),
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
            context.tf('将永久删除 {count} 个文件，共 {bytes}。', {
              'count': widget.fileCount,
              'bytes': formatBytes(widget.bytes),
            }),
          ),
          const SizedBox(height: 8),
          Text(
            context.t(
              '删除后无法恢复，也不会放回原位置。文件当前仍占用磁盘空间，'
              '释放后这部分空间才会真正回收。',
            ),
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
              context.t('我明白这些文件将被永久删除，且无法恢复'),
              style: Theme.of(context).textTheme.bodySmall,
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
          key: const ValueKey('purge-confirm-button'),
          onPressed: _acknowledged
              ? () => Navigator.of(context).pop(true)
              : null,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
            disabledBackgroundColor: scheme.error.withValues(alpha: 0.12),
          ),
          child: Text(context.t('永久释放')),
        ),
      ],
    );
  }
}

Future<UndoConflictPolicy?> _askConflictPolicy(
  BuildContext context,
  int conflictCount,
) async {
  if (conflictCount == 0) return UndoConflictPolicy.skip;
  return showDialog<UndoConflictPolicy>(
    context: context,
    builder: (_) => _ConflictResolutionDialog(conflictCount: conflictCount),
  );
}

class _ConflictResolutionDialog extends StatefulWidget {
  const _ConflictResolutionDialog({required this.conflictCount});

  final int conflictCount;

  @override
  State<_ConflictResolutionDialog> createState() =>
      _ConflictResolutionDialogState();
}

class _ConflictResolutionDialogState extends State<_ConflictResolutionDialog> {
  UndoConflictPolicy _policy = UndoConflictPolicy.skip;
  bool _acknowledged = false;

  bool get _canConfirm =>
      _policy != UndoConflictPolicy.overwrite || _acknowledged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AlertDialog(
      icon: Icon(
        Icons.compare_arrows_rounded,
        size: 30,
        color: scheme.tertiary,
      ),
      title: Text(
        context.tf('{count} 个文件的原位置已有内容', {'count': widget.conflictCount}),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: RadioGroup<UndoConflictPolicy>(
            groupValue: _policy,
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _policy = value;
                if (value != UndoConflictPolicy.overwrite) {
                  _acknowledged = false;
                }
              });
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t('这些文件的原路径在清理后出现了新内容。请选择本次恢复的处理方式：'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                RadioListTile<UndoConflictPolicy>(
                  value: UndoConflictPolicy.skip,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(context.t('跳过冲突文件')),
                  subtitle: Text(context.t('暂存文件继续留在隔离区，原位置内容不变。')),
                ),
                RadioListTile<UndoConflictPolicy>(
                  value: UndoConflictPolicy.keepBoth,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(context.t('保留两者')),
                  subtitle: Text(context.t('暂存文件恢复为重命名副本，例如“文件名 (已恢复).扩展名”。')),
                ),
                RadioListTile<UndoConflictPolicy>(
                  value: UndoConflictPolicy.overwrite,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  title: Text(context.t('覆盖原位置文件')),
                  subtitle: Text(context.t('用暂存文件替换原位置内容，原位置的新内容将被删除。')),
                ),
                if (_policy == UndoConflictPolicy.overwrite)
                  CheckboxListTile(
                    key: const ValueKey('overwrite-confirm-checkbox'),
                    value: _acknowledged,
                    onChanged: (value) =>
                        setState(() => _acknowledged = value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      context.t('我明白原位置的文件将被覆盖且无法恢复'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey('conflict-confirm-button'),
          onPressed: _canConfirm
              ? () => Navigator.of(context).pop(_policy)
              : null,
          child: Text(context.t('继续恢复')),
        ),
      ],
    );
  }
}

String _retentionReportMessage(QuarantineRetentionReport report) {
  if (report.removedSessionCount == 0 && report.failureCount > 0) {
    return trf('自动保留策略未能释放旧会话：{count} 个错误，相关文件仍保留在隔离区。', {
      'count': report.failureCount,
    });
  }
  final parts = <String>[
    trf('自动保留策略已永久释放 {sessions} 个旧会话，共 {files} 个文件（{bytes}）', {
      'sessions': report.removedSessionCount,
      'files': report.removedFileCount,
      'bytes': formatBytes(report.removedBytes),
    }),
  ];
  if (report.failureCount > 0) {
    parts.add(trf('{count} 个文件释放失败，仍保留在隔离区', {'count': report.failureCount}));
  }
  return '${parts.join(tr('；'))}${tr('。')}';
}

String _restoreMessage(UndoReport report) {
  final parts = <String>[
    trf('已恢复 {count} 个文件', {'count': report.restoredCount}),
  ];
  if (report.keptBothCount > 0) {
    parts.add(trf('{count} 个以新名称保留两者', {'count': report.keptBothCount}));
  }
  if (report.overwrittenCount > 0) {
    parts.add(trf('{count} 个覆盖了原位置', {'count': report.overwrittenCount}));
  }
  if (report.conflictCount > 0) {
    parts.add(trf('{count} 个已跳过冲突', {'count': report.conflictCount}));
  }
  if (report.integrityFailureCount > 0) {
    parts.add(trf('{count} 个完整性校验失败', {'count': report.integrityFailureCount}));
  }
  final otherFailures = report.failureCount - report.integrityFailureCount;
  if (otherFailures > 0) {
    parts.add(trf('{count} 个恢复失败', {'count': otherFailures}));
  }
  if (report.metadataFailureCount > 0) {
    parts.add(trf('{count} 个元数据未还原', {'count': report.metadataFailureCount}));
  }
  return parts.join('；');
}

String _purgeMessage(QuarantinePurgeReport report) {
  if (report.complete) {
    return trf('已永久释放 {count} 个文件（{bytes}）。', {
      'count': report.removedCount,
      'bytes': formatBytes(report.removedBytes),
    });
  }
  return trf('已释放 {count} 个文件（{bytes}），{failed} 个文件未能释放。', {
    'count': report.removedCount,
    'bytes': formatBytes(report.removedBytes),
    'failed': report.failureCount,
  });
}

Future<bool> _confirmResume(BuildContext context, int remaining) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.play_circle_outline_rounded, size: 30),
      title: Text(context.t('继续清理剩余文件？')),
      content: Text(
        context.tf('还有 {count} 个文件未处理。继续后会把这些文件移入隔离区，过程中可以停止。', {
          'count': remaining,
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(context.t('继续清理')),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

String _resumeMessage(CleanReport report) {
  if (report.cancelled) {
    return trf('清理已停止，还有 {count} 个文件未处理，可再次继续。', {
      'count': report.remainingCount,
    });
  }
  final parts = <String>[
    if (report.movedCount > 0)
      trf('已继续清理 {count} 个文件', {'count': report.movedCount}),
    if (report.skippedCount > 0)
      trf('跳过 {count} 个被占用或已不存在的文件', {'count': report.skippedCount}),
    if (report.failureCount > 0)
      trf('{count} 个文件未能清理', {'count': report.failureCount}),
  ];
  if (parts.isEmpty) return tr('没有剩余文件需要清理。');
  return '${parts.join(tr('；'))}${tr('。')}';
}

class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({
    required this.remainingCount,
    required this.busy,
    required this.onResume,
  });

  final int remainingCount;
  final bool busy;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.play_circle_outline_rounded,
            size: 21,
            color: scheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.tf(
                '这次清理还有 {count} 个文件未处理。'
                '继续后会将这些文件移入隔离区。',
                {'count': remainingCount},
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            key: const ValueKey('resume-clean-detail-button'),
            onPressed: busy ? null : onResume,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(context.t('继续清理')),
          ),
        ],
      ),
    );
  }
}

class _ResumeProgressCard extends StatelessWidget {
  const _ResumeProgressCard({
    required this.progress,
    required this.stopping,
    required this.onStop,
  });

  final CleanProgress progress;
  final bool stopping;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.cleaning_services_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stopping ? context.t('正在停止…') : context.t('正在继续清理…'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                context.tf('{processed} / {total}', {
                  'processed': formatCount(progress.processed),
                  'total': formatCount(progress.total),
                }),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress.total == 0
                ? null
                : progress.processed / progress.total,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.tf('{count} 个文件已移入隔离区（{bytes}）', {
                    'count': formatCount(progress.moved),
                    'bytes': formatBytes(progress.movedBytes),
                  }),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: stopping ? null : onStop,
                child: Text(context.t('停止')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
