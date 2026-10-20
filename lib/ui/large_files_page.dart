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

class LargeFilesPage extends StatefulWidget {
  const LargeFilesPage({
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
  State<LargeFilesPage> createState() => _LargeFilesPageState();
}

class _LargeFilesPageState extends State<LargeFilesPage> {
  late final LargeFileController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LargeFileController(
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
        title: Text(context.t('大文件分析')),
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
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: AnalysisProgressCard(
            icon: Icons.sd_storage_rounded,
            title: context.t('正在扫描大文件'),
            description: context.t('遍历目录并记录超过大小阈值的文件。'),
            progress: null,
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
                label: context.t('匹配大文件'),
                value: formatCount(progress?.matchedFiles ?? 0),
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
        if (report.resultsCapped) ...[
          AnalysisBanner(
            message: context.tf('共找到 {matched} 个匹配文件，列表中只显示体积最大的 {shown} 个。', {
              'matched': formatCount(report.matchedCount),
              'shown': formatCount(report.files.length),
            }),
          ),
          const SizedBox(height: 10),
        ],
        _LargeFileSummary(report: report),
        const SizedBox(height: 12),
        Expanded(
          child: report.files.isEmpty
              ? _NoLargeFiles(
                  report: report,
                  minFileSize: _controller.minFileSize,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 4),
                  itemCount: report.files.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _LargeFileRow(
                      rank: index + 1,
                      file: report.files[index],
                      onReveal: _reveal,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ConfigPanel extends StatelessWidget {
  const _ConfigPanel({required this.controller});

  final LargeFileController controller;

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
                  for (final size in largeFileThresholdOptions)
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

class _LargeFileSummary extends StatelessWidget {
  const _LargeFileSummary({required this.report});

  final LargeFileScanReport report;

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
                label: context.t('匹配文件'),
                value: formatCount(report.matchedCount),
              ),
              _divider(scheme),
              _SummaryStat(
                label: context.t('合计体积'),
                value: formatBytes(report.matchedBytes),
                emphasized: true,
              ),
              _divider(scheme),
              _SummaryStat(
                label: context.t('已检查'),
                value: formatCount(report.scannedFiles),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.tf('在 {bytes} 的已读数据中，找到 {count} 个超过阈值的大文件。', {
              'bytes': formatBytes(report.scannedBytes),
              'count': formatCount(report.matchedCount),
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
    this.emphasized = false,
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

class _LargeFileRow extends StatelessWidget {
  const _LargeFileRow({
    required this.rank,
    required this.file,
    required this.onReveal,
  });

  final int rank;
  final LargeFileEntry file;
  final Future<void> Function(String path) onReveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BroomColors.block(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$rank',
              style: theme.textTheme.labelMedium?.copyWith(
                color: BroomColors.inkMuted(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileNameOf(file.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
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
          const SizedBox(width: 14),
          SizedBox(
            width: 118,
            child: Text(
              formatDateTime(file.modified),
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 92,
            child: Text(
              formatBytes(file.size),
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
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

class _NoLargeFiles extends StatelessWidget {
  const _NoLargeFiles({required this.report, required this.minFileSize});

  final LargeFileScanReport report;
  final int minFileSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            decoration: BoxDecoration(
              color: BroomColors.card(context),
              borderRadius: BorderRadius.circular(14),
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
                        context.t('没有超过阈值的大文件'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.tf(
                          '已检查 {scanned} 个文件（{bytes}），所选目录中没有大于 {threshold} 的文件。',
                          {
                            'scanned': formatCount(report.scannedFiles),
                            'bytes': formatBytes(report.scannedBytes),
                            'threshold': formatBytes(minFileSize),
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
              Icons.sd_storage_outlined,
              size: 30,
              color: BroomColors.inkFaint(context),
            ),
            const SizedBox(height: 12),
            Text(context.t('选择文件夹查看大文件'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              context.t('按体积从大到小排列，只读分析。'),
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
