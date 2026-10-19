import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models/cleaner_rule.dart';
import '../core/models/scan_models.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'clean_controller.dart';
import 'format.dart';
import 'result_filters.dart';

class RuleDetailPage extends StatefulWidget {
  const RuleDetailPage({
    super.key,
    required this.controller,
    required this.result,
    this.shell,
  });

  final CleanController controller;
  final RuleResult result;
  final SystemShell? shell;

  @override
  State<RuleDetailPage> createState() => _RuleDetailPageState();
}

class _RuleDetailPageState extends State<RuleDetailPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  ResultItemSort _sort = ResultItemSort.sizeDesc;
  ResultItemFilter _filter = const ResultItemFilter();
  late final List<String> _extensions = availableExtensions(
    widget.result.items,
  );

  List<RuleRootInspection>? _roots;
  bool _rootsLoading = true;
  String? _rootsError;

  CleanController get controller => widget.controller;
  RuleResult get result => widget.result;
  CleanerRule get rule => widget.result.rule;

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRoots() async {
    setState(() {
      _rootsLoading = true;
      _rootsError = null;
    });
    try {
      final roots = await controller.inspectRuleRoots(rule);
      if (!mounted) return;
      setState(() {
        _roots = roots;
        _rootsLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rootsError = '$error';
        _rootsLoading = false;
      });
    }
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  String _sortLabel(BuildContext context, ResultItemSort sort) {
    return switch (sort) {
      ResultItemSort.sizeDesc => context.t('体积从大到小'),
      ResultItemSort.sizeAsc => context.t('体积从小到大'),
      ResultItemSort.modifiedDesc => context.t('修改时间从新到旧'),
      ResultItemSort.modifiedAsc => context.t('修改时间从旧到新'),
      ResultItemSort.pathAsc => context.t('路径 A–Z'),
      ResultItemSort.extensionAsc => context.t('扩展名 A–Z'),
    };
  }

  void _clearFiltering() {
    _searchController.clear();
    setState(() => _filter = const ResultItemFilter());
    _searchFocus.requestFocus();
  }

  Future<void> _openFilterDialog() async {
    final applied = await showDialog<ResultItemFilter>(
      context: context,
      builder: (_) => _FileFilterDialog(
        initial: _filter.copyWith(query: _searchController.text),
        extensions: _extensions,
      ),
    );
    if (applied == null || !mounted) return;
    setState(() => _filter = applied.copyWith(query: ''));
  }

  Future<void> _showRuleInfo(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('rule-info-dialog'),
        icon: const Icon(Icons.fact_check_outlined, size: 30),
        title: Text(context.t('规则详情')),
        content: SizedBox(
          width: 640,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 540),
            child: SingleChildScrollView(
              child: _RuleInfoPanel(
                controller: controller,
                rule: rule,
                roots: _roots,
                rootsLoading: _rootsLoading,
                rootsError: _rootsError,
                onRefreshRoots: _loadRoots,
                onReveal: _revealPath,
                shellAvailable: widget.shell != null,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.t('关闭')),
          ),
        ],
      ),
    );
  }

  Future<void> _revealPath(String path) async {
    final shell = widget.shell;
    if (shell == null) return;
    try {
      await shell.revealPath(path);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tf('无法在资源管理器中显示：{error}', {'error': error})),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final bool? selection = controller.ruleSelectionValue(rule.id);
        final selectedCount = controller.selectedCountForRule(rule.id);
        final selectedBytes = controller.selectedBytesForRule(rule.id);
        final lockedCount = controller.possiblyLockedCountForRule(rule.id);
        final effectiveFilter = _filter.copyWith(query: _searchController.text);
        final visibleItems = visibleResultItems(
          result.items,
          effectiveFilter,
          _sort,
        );
        final isFiltering =
            effectiveFilter.hasQuery || _filter.hasAdvancedFilters;

        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _focusSearch,
            const SingleActivator(LogicalKeyboardKey.escape): () {
              Navigator.of(context).maybePop();
            },
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: context.t('返回（Esc）'),
                ),
                toolbarHeight: 68,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.strings.ruleTitle(rule)),
                    const SizedBox(height: 1),
                    Text(
                      lockedCount > 0
                          ? context.tf(
                              '{count} 个文件 · {bytes} · {locked} 个可能被占用',
                              {
                                'count': formatCount(result.items.length),
                                'bytes': formatBytes(result.totalBytes),
                                'locked': formatCount(lockedCount),
                              },
                            )
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
              body: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: Center(
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
                                color: scheme.outlineVariant.withValues(
                                  alpha: 0.5,
                                ),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        context.strings.ruleDescription(rule),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(height: 1.5),
                                      ),
                                      if (context.strings.ruleNote(rule)
                                          case final note?) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          note,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
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
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: scheme.tertiary,
                                                      height: 1.4,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      const SizedBox(height: 2),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton.icon(
                                          key: const ValueKey('rule-info-open'),
                                          onPressed: () =>
                                              _showRuleInfo(context),
                                          icon: const Icon(
                                            Icons.fact_check_outlined,
                                            size: 16,
                                          ),
                                          label: Text(context.t('规则详情与清理后果')),
                                          style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            minimumSize: const Size(0, 30),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(13),
                              border: Border.all(
                                color: scheme.outlineVariant.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                MergeSemantics(
                                  child: Semantics(
                                    label: context.t('选择或取消选择此规则的全部文件'),
                                    child: Checkbox(
                                      key: const ValueKey('rule-select-all'),
                                      value: selection,
                                      tristate: true,
                                      onChanged: (_) =>
                                          controller.toggleRule(rule.id),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ),
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
                                      ? () => controller.setRuleSelected(
                                          rule.id,
                                          false,
                                        )
                                      : () => controller.setRuleSelected(
                                          rule.id,
                                          true,
                                        ),
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
                          const SizedBox(height: 10),
                          _FileToolbar(
                            searchController: _searchController,
                            searchFocus: _searchFocus,
                            sort: _sort,
                            sortLabel: _sortLabel(context, _sort),
                            activeFilterCount: _filter.activeFilterCount,
                            onQueryChanged: () => setState(() {}),
                            onClearQuery: () {
                              _searchController.clear();
                              setState(() {});
                              _searchFocus.requestFocus();
                            },
                            onOpenFilter: _openFilterDialog,
                            onSortChanged: (sort) =>
                                setState(() => _sort = sort),
                          ),
                          if (isFiltering) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  context.tf('显示 {shown} / {total} 个文件', {
                                    'shown': formatCount(visibleItems.length),
                                    'total': formatCount(result.items.length),
                                  }),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                TextButton(
                                  key: const ValueKey('rule-clear-filter'),
                                  onPressed: _clearFiltering,
                                  child: Text(context.t('清除筛选')),
                                ),
                                const Spacer(),
                                Flexible(
                                  child: Text(
                                    context.t('选择操作仍作用于全部文件'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ] else
                            const SizedBox(height: 2),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: visibleItems.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.search_off_rounded,
                                            size: 34,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            context.t('没有匹配的文件'),
                                            style: theme.textTheme.titleSmall,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            context.t('试试更短的路径、其他扩展名，或清除筛选。'),
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.separated(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      itemCount: visibleItems.length,
                                      separatorBuilder: (context, index) =>
                                          Divider(
                                            height: 1,
                                            indent: 62,
                                            endIndent: 16,
                                            color: scheme.outlineVariant
                                                .withValues(alpha: 0.4),
                                          ),
                                      itemBuilder: (context, index) {
                                        final item = visibleItems[index];
                                        return _FileRow(
                                          key: ValueKey(
                                            'rule-file-${item.path}',
                                          ),
                                          item: item,
                                          selected: controller.isItemSelected(
                                            item.path,
                                          ),
                                          shellAvailable: widget.shell != null,
                                          onChanged: () =>
                                              controller.toggleItem(item.path),
                                          onReveal: () =>
                                              _revealPath(item.path),
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
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FileToolbar extends StatelessWidget {
  const _FileToolbar({
    required this.searchController,
    required this.searchFocus,
    required this.sort,
    required this.sortLabel,
    required this.activeFilterCount,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onOpenFilter,
    required this.onSortChanged,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ResultItemSort sort;
  final String sortLabel;
  final int activeFilterCount;
  final VoidCallback onQueryChanged;
  final VoidCallback onClearQuery;
  final VoidCallback onOpenFilter;
  final ValueChanged<ResultItemSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('rule-file-search'),
            controller: searchController,
            focusNode: searchFocus,
            onChanged: (_) => onQueryChanged(),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: context.t('搜索文件'),
              hintText: context.t('路径或扩展名，Ctrl+F 聚焦'),
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.t('清除搜索'),
                      onPressed: onClearQuery,
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const ValueKey('rule-file-filter'),
          onPressed: onOpenFilter,
          icon: const Icon(Icons.filter_alt_outlined, size: 18),
          label: Text(
            activeFilterCount == 0
                ? context.t('筛选')
                : context.tf('筛选 · {count}', {'count': activeFilterCount}),
          ),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<ResultItemSort>(
          key: const ValueKey('rule-file-sort'),
          tooltip: context.t('排序文件'),
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (context) => [
            for (final value in ResultItemSort.values)
              PopupMenuItem(
                value: value,
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      child: value == sort
                          ? const Icon(Icons.check_rounded, size: 17)
                          : null,
                    ),
                    Text(switch (value) {
                      ResultItemSort.sizeDesc => context.t('体积从大到小'),
                      ResultItemSort.sizeAsc => context.t('体积从小到大'),
                      ResultItemSort.modifiedDesc => context.t('修改时间从新到旧'),
                      ResultItemSort.modifiedAsc => context.t('修改时间从旧到新'),
                      ResultItemSort.pathAsc => context.t('路径 A–Z'),
                      ResultItemSort.extensionAsc => context.t('扩展名 A–Z'),
                    }),
                  ],
                ),
              ),
          ],
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.swap_vert_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(sortLabel, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more_rounded,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FileFilterDialog extends StatefulWidget {
  const _FileFilterDialog({required this.initial, required this.extensions});

  final ResultItemFilter initial;
  final List<String> extensions;

  @override
  State<_FileFilterDialog> createState() => _FileFilterDialogState();
}

class _FileFilterDialogState extends State<_FileFilterDialog> {
  late String? _extension = widget.initial.extension;
  late int _minimumSize = widget.initial.minimumSize;
  late Duration? _olderThan = widget.initial.olderThan;
  late bool _lockedOnly = widget.initial.lockedOnly;

  static const _sizes = <({int bytes, String label})>[
    (bytes: 0, label: '不限体积'),
    (bytes: 1024 * 1024, label: '≥ 1 MB'),
    (bytes: 10 * 1024 * 1024, label: '≥ 10 MB'),
    (bytes: 100 * 1024 * 1024, label: '≥ 100 MB'),
  ];

  static const _ages = <({int days, String label})>[
    (days: 0, label: '不限时间'),
    (days: 30, label: '30 天前修改'),
    (days: 90, label: '90 天前修改'),
    (days: 365, label: '1 年前修改'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return AlertDialog(
      key: const ValueKey('rule-file-filter-dialog'),
      icon: const Icon(Icons.filter_alt_outlined, size: 28),
      title: Text(context.t('筛选文件')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.extensions.isNotEmpty) ...[
                Text(
                  context.t('扩展名'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('filter-extension-all'),
                      label: Text(context.t('全部扩展名')),
                      selected: _extension == null,
                      onSelected: (_) => setState(() => _extension = null),
                    ),
                    for (final extension in widget.extensions)
                      ChoiceChip(
                        key: ValueKey('filter-extension-$extension'),
                        label: Text('.$extension'),
                        selected: _extension == extension,
                        onSelected: (_) =>
                            setState(() => _extension = extension),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              Text(
                context.t('最小体积'),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final size in _sizes)
                    ChoiceChip(
                      label: Text(context.t(size.label)),
                      selected: _minimumSize == size.bytes,
                      onSelected: (_) =>
                          setState(() => _minimumSize = size.bytes),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                context.t('修改时间'),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final age in _ages)
                    ChoiceChip(
                      label: Text(context.t(age.label)),
                      selected: _olderThan?.inDays == age.days,
                      onSelected: (_) => setState(
                        () => _olderThan = age.days == 0
                            ? null
                            : Duration(days: age.days),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                key: const ValueKey('filter-locked-only'),
                contentPadding: EdgeInsets.zero,
                value: _lockedOnly,
                onChanged: (value) => setState(() => _lockedOnly = value),
                title: Text(
                  context.t('仅显示可能被占用的文件'),
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  context.t('被占用的文件在清理时会被跳过。'),
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
              Text(
                context.t('筛选与排序只影响显示，不会改变已选文件。'),
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('filter-reset'),
          onPressed: () => setState(() {
            _extension = null;
            _minimumSize = 0;
            _olderThan = null;
            _lockedOnly = false;
          }),
          child: Text(context.t('重置')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey('filter-apply'),
          onPressed: () => Navigator.of(context).pop(
            widget.initial.copyWith(
              extension: _extension,
              clearExtension: _extension == null,
              minimumSize: _minimumSize,
              olderThan: _olderThan,
              clearOlderThan: _olderThan == null,
              lockedOnly: _lockedOnly,
            ),
          ),
          child: Text(context.t('应用筛选')),
        ),
      ],
    );
  }
}

class _RuleInfoPanel extends StatelessWidget {
  const _RuleInfoPanel({
    required this.controller,
    required this.rule,
    required this.roots,
    required this.rootsLoading,
    required this.rootsError,
    required this.onRefreshRoots,
    required this.onReveal,
    required this.shellAvailable,
  });

  final CleanController controller;
  final CleanerRule rule;
  final List<RuleRootInspection>? roots;
  final bool rootsLoading;
  final String? rootsError;
  final VoidCallback onRefreshRoots;
  final Future<void> Function(String path) onReveal;
  final bool shellAvailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.strings;
    final version = controller.rulesVersion;
    final source = version == 'builtin'
        ? context.t('应用内置规则目录')
        : context.tf('已验证的规则目录更新 · 版本 {version}', {'version': version});
    final riskText = switch (rule.risk) {
      CleanRisk.safe => context.t('安全：可重建的缓存，默认勾选；清理后仍会进入隔离区，可恢复。'),
      CleanRisk.review => context.t('需确认：默认不勾选，提交前需要额外确认；可能影响离线数据或首次启动速度。'),
      CleanRisk.info => context.t('只读：只读分析，不会删除文件。'),
    };
    final consequence = switch (rule.risk) {
      CleanRisk.safe => context.t(
        '清理时文件会移入隔离区，可随时恢复；永久释放隔离区后才会回收磁盘空间。'
        '被占用、已不存在或已被排除的文件会跳过并单独报告。缓存通常会被应用重新生成。',
      ),
      CleanRisk.review => context.t(
        '清理时文件仍会移入隔离区并可恢复，但离线缓存可能需要重新下载，'
        '首次启动或构建也可能变慢。提交前需要勾选额外确认，永久释放后不可恢复。',
      ),
      CleanRisk.info => context.t('此规则不会清理任何文件。'),
    };
    final ageValue = rule.minAge > Duration.zero
        ? context.tf('仅清理修改时间早于 {age}的文件', {
            'age': _formatAge(context, rule.minAge),
          })
        : context.t('不限制文件修改时间');
    final extensionValue = rule.extensions == null
        ? context.t('所有文件类型')
        : context.tf('仅匹配扩展名：{extensions}', {
            'extensions': rule.extensions!.map((e) => '.$e').join('、'),
          });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoLine(label: context.t('来源'), child: Text(source)),
        _InfoLine(label: context.t('规则编号'), child: Text(rule.id)),
        _InfoLine(
          label: context.t('风险'),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              RiskBadge(risk: rule.risk),
              Text(
                riskText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        _InfoLine(
          label: context.t('路径模板'),
          child: rule.pathPatterns.isEmpty
              ? Text(context.t('此规则没有声明路径模板。'))
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final pattern in rule.pathPatterns)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest.withValues(
                            alpha: 0.55,
                          ),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: SelectableText(
                          pattern,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        _InfoLine(
          label: context.t('实际目录'),
          child: _RootsView(
            roots: roots,
            loading: rootsLoading,
            error: rootsError,
            onRefresh: onRefreshRoots,
            onReveal: onReveal,
            shellAvailable: shellAvailable,
          ),
        ),
        _InfoLine(label: context.t('保留时间'), child: Text(ageValue)),
        _InfoLine(label: context.t('文件类型'), child: Text(extensionValue)),
        if (rule.excludedPathPatterns.isNotEmpty)
          _InfoLine(
            label: context.t('排除子目录'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.t('与更严格的规则或保留期重叠时，这些子目录会被跳过。')),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final pattern in rule.excludedPathPatterns)
                      Chip(
                        label: Text(pattern),
                        visualDensity: VisualDensity.compact,
                        labelStyle: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 17,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('清理后果'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      consequence,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        height: 1.5,
                      ),
                    ),
                    if (rule.audit != null) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: () => _showRuleAudit(context, rule),
                        icon: const Icon(Icons.policy_outlined, size: 16),
                        label: Text(strings.t('查看规则审计')),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onSecondaryContainer,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _formatAge(BuildContext context, Duration age) {
    if (age.inDays >= 1) {
      return context.tf('{days} 天', {'days': age.inDays});
    }
    if (age.inHours >= 1) {
      return context.tf('{hours} 小时', {'hours': age.inHours});
    }
    return context.tf('{minutes} 分钟', {'minutes': age.inMinutes});
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DefaultTextStyle.merge(
              style:
                  theme.textTheme.bodySmall?.copyWith(height: 1.5) ??
                  const TextStyle(),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _RootsView extends StatelessWidget {
  const _RootsView({
    required this.roots,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onReveal,
    required this.shellAvailable,
  });

  final List<RuleRootInspection>? roots;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;
  final Future<void> Function(String path) onReveal;
  final bool shellAvailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (loading) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(context.t('正在解析实际目录…')),
        ],
      );
    }
    if (error case final error?) {
      return Row(
        children: [
          Expanded(
            child: Text(
              context.tf('无法解析实际目录：{error}', {'error': error}),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            tooltip: context.t('重试'),
            icon: const Icon(Icons.refresh_rounded, size: 17),
          ),
        ],
      );
    }
    final roots = this.roots ?? const <RuleRootInspection>[];
    if (roots.isEmpty) {
      return Text(context.t('当前配置下没有可扫描目录（可能已被排除或受保护）。'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final root in roots)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  switch (root.state) {
                    RuleRootState.active => Icons.folder_open_outlined,
                    RuleRootState.excluded => Icons.block_outlined,
                    RuleRootState.protected => Icons.lock_outline_rounded,
                  },
                  size: 15,
                  color: root.state == RuleRootState.active
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Tooltip(
                    message: root.path,
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(
                      root.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: root.state == RuleRootState.active
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (root.state != RuleRootState.active)
                  Text(
                    switch (root.state) {
                      RuleRootState.active => '',
                      RuleRootState.excluded => context.t('已被排除'),
                      RuleRootState.protected => context.t('受保护'),
                    },
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.tertiary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (root.state == RuleRootState.active && shellAvailable)
                  IconButton(
                    key: ValueKey('rule-root-reveal-${root.path}'),
                    onPressed: () => onReveal(root.path),
                    tooltip: context.t('在资源管理器中显示'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                  ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('rule-roots-refresh'),
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: Text(context.t('重新解析目录')),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
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
    required this.onReveal,
    required this.shellAvailable,
  });

  final JunkItem item;
  final bool selected;
  final VoidCallback onChanged;
  final VoidCallback onReveal;
  final bool shellAvailable;

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
            MergeSemantics(
              child: Semantics(
                label: context.tf('选择文件 {name}', {
                  'name': fileNameOf(item.path),
                }),
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => onChanged(),
                  visualDensity: VisualDensity.compact,
                ),
              ),
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
            const SizedBox(width: 12),
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
                  formatDateTime(item.modified),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (shellAvailable)
              IconButton(
                key: ValueKey('rule-file-reveal-${item.path}'),
                onPressed: onReveal,
                tooltip: context.t('在资源管理器中显示'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
              )
            else
              const SizedBox(width: 10),
          ],
        ),
      ),
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
