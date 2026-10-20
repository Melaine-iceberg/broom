import 'package:flutter/material.dart';

import '../core/analysis/analysis_service.dart';
import '../core/models/analysis_models.dart';
import '../core/models/cleaner_rule.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_controllers.dart';
import 'analysis_widgets.dart';
import 'format.dart';
import 'glass_ui.dart';

class DuplicateFinderPage extends StatefulWidget {
  const DuplicateFinderPage({
    super.key,
    required this.shell,
    required this.runnerFactory,
    this.initialDirectory,
    this.excludedPaths = const [],
  });

  final SystemShell shell;
  final AnalysisRunner Function() runnerFactory;
  final String? initialDirectory;
  final List<String> excludedPaths;

  @override
  State<DuplicateFinderPage> createState() => _DuplicateFinderPageState();
}

class _DuplicateFinderPageState extends State<DuplicateFinderPage> {
  late final DuplicateFinderController _controller;

  @override
  void initState() {
    super.initState();
    _controller = DuplicateFinderController(
      shell: widget.shell,
      runnerFactory: widget.runnerFactory,
      excludedPaths: widget.excludedPaths,
      initialDirectory: widget.initialDirectory,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reveal(String path) async {
    try {
      await widget.shell.revealPath(path);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(analysisErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: context.t('返回'),
        ),
        toolbarHeight: 76,
        title: Text(context.t('重复文件')),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 20),
            child: Center(child: RiskBadge(risk: CleanRisk.info)),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 6, 28, 24),
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_controller.error case final error?) ...[
                      AnalysisBanner(
                        message: error,
                        isError: true,
                        onClose: _controller.clearError,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_controller.notice case final notice?) ...[
                      AnalysisBanner(
                        message: notice,
                        onClose: _controller.clearNotice,
                      ),
                      const SizedBox(height: 10),
                    ],
                    _ConfigPanel(controller: _controller),
                    const SizedBox(height: 14),
                    Expanded(child: _buildContent(context)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (_controller.phase) {
      case AnalysisToolPhase.running:
        return _buildProgress();
      case AnalysisToolPhase.results:
        return _buildResults(context);
      case AnalysisToolPhase.idle:
        return const _IdleState();
    }
  }

  Widget _buildProgress() {
    final progress = _controller.progress;
    final comparing = progress?.phase == AnalysisPhase.comparing;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: AnalysisProgressCard(
            icon: Icons.content_copy_rounded,
            title: comparing ? context.t('正在核对文件内容') : context.t('正在遍历文件夹'),
            description: comparing
                ? context.t('对大小相同的候选文件做部分指纹与完整哈希比对。')
                : context.t('只读取文件信息，不会修改任何文件。'),
            progress: progress?.fraction,
            stats: [
              AnalysisProgressStat(
                label: context.t('已检查文件'),
                value: formatCount(progress?.scannedFiles ?? 0),
              ),
              AnalysisProgressStat(
                label: context.t('已读取'),
                value: formatBytes(progress?.scannedBytes ?? 0),
              ),
              AnalysisProgressStat(
                label: comparing ? context.t('已比对') : context.t('当前阶段'),
                value: comparing
                    ? '${formatCount(progress!.processedFiles)} / '
                          '${formatCount(progress.totalFiles)}'
                    : context.t('遍历中'),
              ),
            ],
            currentPath: progress?.currentPath,
            cancelRequested: _controller.cancelRequested,
            onCancel: _controller.cancel,
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final report = _controller.report;
    if (report == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (report.errorCount > 0) ...[
          AnalysisBanner(
            message: context.tf('有 {count} 个文件或目录无法读取，已跳过。', {
              'count': formatCount(report.errorCount),
            }),
          ),
          const SizedBox(height: 10),
        ],
        if (report.truncated) ...[
          AnalysisBanner(message: context.t('已达到单次分析上限（200,000 个文件），结果可能不完整。')),
          const SizedBox(height: 10),
        ],
        _DuplicateSummary(report: report),
        const SizedBox(height: 12),
        Expanded(
          child: report.groups.isEmpty
              ? _NoDuplicates(report: report)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 4),
                  itemCount: report.groups.length,
                  itemBuilder: (context, index) {
                    final group = report.groups[index];
                    return _DuplicateGroupCard(group: group, onReveal: _reveal);
                  },
                ),
        ),
      ],
    );
  }
}

class _ConfigPanel extends StatelessWidget {
  const _ConfigPanel({required this.controller});

  final DuplicateFinderController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = controller.report;

    return Column(
      children: [
        FolderSelectionCard(
          path: controller.directory,
          onPick: controller.chooseDirectory,
          enabled: !controller.isRunning,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: BroomColors.card(context),
            borderRadius: BorderRadius.circular(18),
            boxShadow: BroomColors.cardShadow(context),
          ),
          child: Row(
            children: [
              Text(
                context.t('最小文件大小'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: controller.minFileSize,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(12),
                onChanged: controller.isRunning
                    ? null
                    : (value) {
                        if (value != null) controller.setMinFileSize(value);
                      },
                items: [
                  for (final size in duplicateMinSizeOptions)
                    DropdownMenuItem(
                      value: size,
                      child: Text('≥ ${formatBytes(size)}'),
                    ),
                ],
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: controller.isRunning ? null : controller.scan,
                icon: Icon(
                  report == null ? Icons.search_rounded : Icons.refresh_rounded,
                  size: 18,
                ),
                label: Text(
                  report == null ? context.t('开始分析') : context.t('重新分析'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DuplicateSummary extends StatelessWidget {
  const _DuplicateSummary({required this.report});

  final DuplicateScanReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(24),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _SummaryStat(
                label: context.t('重复组'),
                value: formatCount(report.groupCount),
                emphasized: false,
              ),
              _divider(scheme),
              _SummaryStat(
                label: context.t('可释放空间'),
                value: formatBytes(report.reclaimableBytes),
                emphasized: true,
              ),
              _divider(scheme),
              _SummaryStat(
                label: context.t('冗余文件'),
                value: formatCount(report.redundantFileCount),
                emphasized: false,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.tf('已检查 {scanned} 个文件（{bytes}），找到 {duplicates} 个内容相同的文件。', {
              'scanned': formatCount(report.scannedFiles),
              'bytes': formatBytes(report.scannedBytes),
              'duplicates': formatCount(report.duplicateFileCount),
            }),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(ColorScheme scheme) {
    return Container(
      width: 1,
      height: 30,
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.emphasized,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: emphasized ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
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

class _DuplicateGroupCard extends StatelessWidget {
  const _DuplicateGroupCard({required this.group, required this.onReveal});

  static const _maxVisibleFiles = 20;

  final DuplicateGroup group;
  final Future<void> Function(String path) onReveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hidden = group.files.length - _maxVisibleFiles;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(22),
        boxShadow: BroomColors.cardShadow(context),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.content_copy_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tf('{count} 个相同文件', {
                          'count': group.files.length,
                        }),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.tf('每个 {size} · 合计 {total}', {
                          'size': formatBytes(group.size),
                          'total': formatBytes(group.totalBytes),
                        }),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    context.tf('可释放 {bytes}', {
                      'bytes': formatBytes(group.wastedBytes),
                    }),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
          for (final file in group.files.take(_maxVisibleFiles))
            _DuplicateFileRow(file: file, onReveal: onReveal),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.tf('还有 {count} 个相同文件未显示。', {
                    'count': formatCount(hidden),
                  }),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DuplicateFileRow extends StatelessWidget {
  const _DuplicateFileRow({required this.file, required this.onReveal});

  final DuplicateFile file;
  final Future<void> Function(String path) onReveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 8, 7),
      child: Row(
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileNameOf(file.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 1),
                Tooltip(
                  message: file.path,
                  child: Text(
                    file.path,
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
          Text(
            formatDateTime(file.modified),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            onPressed: () => onReveal(file.path),
            icon: const Icon(Icons.folder_open_rounded, size: 17),
            visualDensity: VisualDensity.compact,
            tooltip: context.t('在资源管理器中显示'),
          ),
        ],
      ),
    );
  }
}

class _NoDuplicates extends StatelessWidget {
  const _NoDuplicates({required this.report});

  final DuplicateScanReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
              color: BroomColors.card(context),
              borderRadius: BorderRadius.circular(24),
              boxShadow: BroomColors.cardShadow(context),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 20,
                  color: BroomColors.inkMuted(context),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.t('没有发现重复文件'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.tf(
                          '已检查 {scanned} 个文件（{bytes}），所选目录中没有内容完全相同的文件。',
                          {
                            'scanned': formatCount(report.scannedFiles),
                            'bytes': formatBytes(report.scannedBytes),
                          },
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: BroomColors.inkMuted(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IdleState extends StatelessWidget {
  const _IdleState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.content_copy_outlined,
              size: 30,
              color: BroomColors.inkFaint(context),
            ),
            const SizedBox(height: 12),
            Text(context.t('选择文件夹开始分析'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              context.t('只读取文件内容，不会修改文件。'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: BroomColors.inkMuted(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
