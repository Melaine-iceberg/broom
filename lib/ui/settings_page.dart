import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/clean/quarantine_retention_service.dart';
import '../core/models/app_settings.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/quarantine_policy_models.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'clean_controller.dart';
import 'exclusions_page.dart';
import 'format.dart';
import 'quarantine_policy_dialog.dart';
import 'rule_update_controller.dart';
import 'settings_controller.dart';

const _appVersion = '0.4.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.cleanController,
    required this.shell,
    this.retention,
    this.ruleUpdates,
  });

  final SettingsController settings;
  final CleanController cleanController;
  final SystemShell shell;
  final QuarantineRetentionService? retention;
  final RuleUpdateController? ruleUpdates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([settings, cleanController, ?ruleUpdates]),
      builder: (context, _) {
        final strings = context.strings;
        final rules = cleanController.platform.rules;
        final disabledCount = rules
            .where((rule) => !settings.isRuleEnabled(rule.id))
            .length;
        final ruleGroups = <String, List<CleanerRule>>{};
        for (final rule in rules) {
          ruleGroups
              .putIfAbsent(strings.ruleCategory(rule), () => [])
              .add(rule);
        }

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
              tooltip: strings.t('返回'),
            ),
            toolbarHeight: 68,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.t('设置')),
                const SizedBox(height: 1),
                Text(
                  strings.t('偏好设置'),
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 6, 28, 28),
                children: [
                  if (settings.loadError case final error?)
                    _SettingsBanner(
                      message: strings.tf('设置读取失败，已使用默认设置：{error}', {
                        'error': error,
                      }),
                    ),
                  if (settings.saveError case final error?)
                    _SettingsBanner(
                      message: strings.tf('设置保存失败：{error}', {'error': error}),
                      isError: true,
                    ),
                  _Section(
                    icon: Icons.palette_outlined,
                    title: strings.t('外观'),
                    subtitle: strings.t('语言切换会立即应用，已保存的清理规则与排除项不受影响。'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel(label: strings.t('主题')),
                        SegmentedButton<AppThemePreference>(
                          key: const ValueKey('settings-theme-selector'),
                          segments: [
                            ButtonSegment(
                              value: AppThemePreference.system,
                              icon: const Icon(Icons.brightness_auto_outlined),
                              label: Text(strings.t('跟随系统')),
                            ),
                            ButtonSegment(
                              value: AppThemePreference.light,
                              icon: const Icon(Icons.light_mode_outlined),
                              label: Text(strings.t('浅色')),
                            ),
                            ButtonSegment(
                              value: AppThemePreference.dark,
                              icon: const Icon(Icons.dark_mode_outlined),
                              label: Text(strings.t('深色')),
                            ),
                          ],
                          selected: {settings.settings.theme},
                          onSelectionChanged: (selection) =>
                              _setTheme(context, selection.single),
                        ),
                        const SizedBox(height: 18),
                        _FieldLabel(label: strings.t('语言')),
                        SegmentedButton<AppLanguagePreference>(
                          key: const ValueKey('settings-language-selector'),
                          segments: [
                            ButtonSegment(
                              value: AppLanguagePreference.system,
                              label: Text(strings.t('跟随系统')),
                            ),
                            ButtonSegment(
                              value: AppLanguagePreference.zh,
                              label: Text(strings.t('简体中文')),
                            ),
                            ButtonSegment(
                              value: AppLanguagePreference.en,
                              label: const Text('English'),
                            ),
                          ],
                          selected: {settings.settings.language},
                          onSelectionChanged: (selection) =>
                              _setLanguage(context, selection.single),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.tune_rounded,
                    title: strings.t('扫描引擎'),
                    subtitle: strings.t(
                      '扫描类别、并行线程、低优先级与 NTFS 索引都在本机生效。'
                      '扫描结果默认不限制数量；NTFS 索引在权限不足或非 NTFS 卷上会自动回退。',
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel(label: strings.t('扫描类别')),
                        for (final entry in ruleGroups.entries)
                          CheckboxListTile(
                            key: ValueKey(
                              'settings-category-'
                              '${ruleCategoryKey(entry.value.first)}',
                            ),
                            value: settings.isCategoryEnabled(
                              ruleCategoryKey(entry.value.first),
                            ),
                            onChanged: (value) => _setCategory(
                              context,
                              ruleCategoryKey(entry.value.first),
                              value ?? false,
                            ),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                            title: Text(entry.key),
                            subtitle: Text(
                              strings.tf('{count} 条规则', {
                                'count': entry.value.length,
                              }),
                            ),
                          ),
                        const Divider(),
                        _FieldLabel(label: strings.t('并行扫描线程')),
                        SegmentedButton<int>(
                          key: const ValueKey('settings-parallelism'),
                          segments: [
                            for (final value in _parallelismOptions)
                              ButtonSegment(
                                value: value,
                                label: Text(
                                  value == 0 ? strings.t('自动') : '$value',
                                ),
                              ),
                          ],
                          selected: {settings.settings.scanParallelism},
                          onSelectionChanged: (selection) =>
                              _setParallelism(context, selection.single),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          key: const ValueKey('settings-low-priority'),
                          value: settings.settings.scanLowPriority,
                          onChanged: (value) => _setLowPriority(context, value),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(strings.t('低优先级扫描')),
                          subtitle: Text(
                            strings.t(
                              '扫描期间尝试使用后台 I/O 与低于正常的 CPU 优先级，'
                              '减少对前台程序的影响；结束后恢复。',
                            ),
                          ),
                        ),
                        SwitchListTile(
                          key: const ValueKey('settings-ntfs-index'),
                          value: settings.settings.useNtfsIndex,
                          onChanged: (value) => _setNtfsIndex(context, value),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(strings.t('优先使用 NTFS 索引')),
                          subtitle: Text(
                            strings.t(
                              '通过 USN 日志快速枚举文件，需要管理员权限且仅支持 NTFS 卷；'
                              '不可用时会自动回退到逐目录扫描，不会漏掉回退路径。',
                            ),
                          ),
                        ),
                        ListTile(
                          key: const ValueKey('settings-scan-limit'),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.speed_rounded, size: 20),
                          title: Text(strings.t('扫描结果数量上限')),
                          subtitle: Text(
                            settings.settings.scanItemLimit == null
                                ? strings.t('不限制（默认）')
                                : strings.tf('最多 {count} 个文件', {
                                    'count': settings.settings.scanItemLimit!,
                                  }),
                          ),
                          trailing: TextButton(
                            onPressed: () => _editScanLimit(context),
                            child: Text(strings.t('调整')),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (ruleUpdates case final updates?) ...[
                    const SizedBox(height: 16),
                    _RuleUpdateSection(
                      updates: updates,
                      onEditUrl: () => _editRuleUpdateUrl(context, updates),
                      onCheck: () => _checkRuleUpdates(context, updates),
                      onApply: () => _applyRuleUpdate(context, updates),
                      onRollback: () => _rollbackRules(context, updates),
                      onRestoreBuiltin: () =>
                          _restoreBuiltinRules(context, updates),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.rule_rounded,
                    title: strings.t('清理规则'),
                    subtitle: strings.t(
                      '关闭的规则不会参与扫描，也不会出现在清理结果中。'
                      'Review 级规则默认扫描但不预选，需要在预览中手动勾选。'
                      '排除列表仍然优先于所有规则。',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          disabledCount == 0
                              ? strings.t('全部规则已启用')
                              : strings.tf('已关闭 {count} 条规则', {
                                  'count': disabledCount,
                                }),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (disabledCount > 0) ...[
                          const SizedBox(width: 6),
                          TextButton(
                            key: const ValueKey('settings-rules-reset'),
                            onPressed: () => _resetRules(context),
                            child: Text(strings.t('恢复默认')),
                          ),
                        ],
                      ],
                    ),
                    child: Column(
                      children: [
                        for (final entry in ruleGroups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.only(
                              left: 4,
                              top: 4,
                              bottom: 2,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _categoryIcon(entry.key),
                                  size: 14,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  entry.key,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          for (final rule in entry.value)
                            SwitchListTile(
                              key: ValueKey('settings-rule-${rule.id}'),
                              value: settings.isRuleEnabled(rule.id),
                              onChanged: (enabled) =>
                                  _setRule(context, rule.id, enabled),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              dense: true,
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      strings.ruleTitle(rule),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (rule.risk == CleanRisk.review) ...[
                                    const SizedBox(width: 8),
                                    const RiskBadge(risk: CleanRisk.review),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                strings.ruleDescription(rule),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.inventory_2_outlined,
                    title: strings.t('扫描与隔离'),
                    child: Column(
                      children: [
                        ListTile(
                          key: const ValueKey('settings-exclusions'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.block_rounded),
                          title: Text(strings.t('排除列表')),
                          subtitle: Text(
                            cleanController.exclusionCount == 0
                                ? strings.t('没有排除项')
                                : strings.tf('{count} 个目录不参与扫描', {
                                    'count': cleanController.exclusionCount,
                                  }),
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _openExclusions(context),
                        ),
                        const Divider(),
                        ListTile(
                          key: const ValueKey('settings-retention'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.auto_delete_outlined),
                          title: Text(strings.t('隔离区保留策略')),
                          subtitle: Text(_retentionSummary(context)),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          enabled: retention != null,
                          onTap: retention == null
                              ? null
                              : () => _editRetention(context),
                        ),
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(strings.t('隔离区位置')),
                          subtitle: SelectableText(
                            cleanController.quarantine.quarantineRoot,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: const ValueKey('settings-copy-path'),
                                tooltip: strings.t('复制路径'),
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                onPressed: () => _copyPath(context),
                              ),
                              IconButton(
                                key: const ValueKey('settings-reveal-path'),
                                tooltip: strings.t('在资源管理器中显示'),
                                icon: const Icon(
                                  Icons.open_in_new_rounded,
                                  size: 18,
                                ),
                                onPressed: () => _revealPath(context),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    icon: Icons.info_outline_rounded,
                    title: strings.t('关于'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.tf('版本 {version}', {'version': _appVersion}),
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          strings.t('Broom 只在本地运行，不上传文件、路径或使用数据。'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<int> get _parallelismOptions {
    final current = settings.settings.scanParallelism;
    const standard = {0, 1, 2, 4};
    final values = {...standard, if (!standard.contains(current)) current};
    return values.toList()..sort();
  }

  Future<void> _setCategory(
    BuildContext context,
    String categoryId,
    bool enabled,
  ) async {
    final error = await settings.setCategoryEnabled(categoryId, enabled);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _setParallelism(BuildContext context, int value) async {
    final error = await settings.setScanParallelism(value);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _setLowPriority(BuildContext context, bool value) async {
    final error = await settings.setScanLowPriority(value);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _setNtfsIndex(BuildContext context, bool value) async {
    final error = await settings.setUseNtfsIndex(value);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _editScanLimit(BuildContext context) async {
    final controller = TextEditingController(
      text: settings.settings.scanItemLimit?.toString() ?? '',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t('扫描结果数量上限')),
        content: SizedBox(
          width: 360,
          child: TextField(
            key: const ValueKey('scan-limit-input'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.t('最多文件数'),
              helperText: context.t('留空表示不限制。上限只影响预览与清理集合，不会删除文件。'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !context.mounted) return;

    int? limit;
    if (value.isNotEmpty && value != '0') {
      limit = int.tryParse(value);
      if (limit == null || limit < 1) {
        _showError(context, context.t('请输入不小于 1 的整数，或留空表示不限制。'));
        return;
      }
    }
    final error = await settings.setScanItemLimit(limit);
    if (error != null && context.mounted) {
      _showError(context, error);
    } else if (context.mounted) {
      _showMessage(
        context,
        limit == null
            ? context.t('扫描结果数量不限制。')
            : context.tf('扫描结果最多保留 {count} 个文件。', {'count': limit}),
      );
    }
  }

  Future<void> _editRuleUpdateUrl(
    BuildContext context,
    RuleUpdateController updates,
  ) async {
    final controller = TextEditingController(text: updates.updateUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t('规则更新地址')),
        content: SizedBox(
          width: 480,
          child: TextField(
            key: const ValueKey('rule-update-url-input'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'HTTPS URL',
              helperText: context.t('规则清单必须由 Broom 发布密钥签名，签名校验失败会拒绝更新。'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !context.mounted) return;
    final error = await updates.saveUrl(value);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _checkRuleUpdates(
    BuildContext context,
    RuleUpdateController updates,
  ) async {
    await updates.checkForUpdates();
  }

  Future<void> _applyRuleUpdate(
    BuildContext context,
    RuleUpdateController updates,
  ) async {
    final candidate = updates.candidate;
    if (candidate == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded, size: 30),
        title: Text(context.t('应用规则更新？')),
        content: Text(
          context.tf(
            '将启用规则版本 {version}，共 {count} 条规则。'
            '更新会替换当前规则目录，但保留上一版本用于回滚；'
            '用户关闭的规则、扫描类别与排除列表继续生效。',
            {
              'version': candidate.manifestVersion,
              'count': candidate.catalog.rules.length,
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.t('应用更新')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await updates.applyUpdate();
    }
  }

  Future<void> _rollbackRules(
    BuildContext context,
    RuleUpdateController updates,
  ) async {
    final confirmed = await _confirmRuleReplacement(
      context,
      title: context.t('回滚规则版本？'),
      message: context.t('将重新启用上一版规则目录。当前版本会被替换；签名与审计校验仍会执行。'),
    );
    if (confirmed) await updates.rollback();
  }

  Future<void> _restoreBuiltinRules(
    BuildContext context,
    RuleUpdateController updates,
  ) async {
    final confirmed = await _confirmRuleReplacement(
      context,
      title: context.t('恢复内置规则？'),
      message: context.t('将停用在线更新规则并恢复应用内置规则。当前在线版本会保留为上一版，可再次回滚。'),
    );
    if (confirmed) await updates.restoreBuiltin();
  }

  Future<bool> _confirmRuleReplacement(
    BuildContext context, {
    required String title,
    required String message,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.t('继续')),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _setTheme(BuildContext context, AppThemePreference value) async {
    final error = await settings.setTheme(value);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _setLanguage(
    BuildContext context,
    AppLanguagePreference value,
  ) async {
    final error = await settings.setLanguage(value);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _setRule(
    BuildContext context,
    String ruleId,
    bool enabled,
  ) async {
    final error = await settings.setRuleEnabled(ruleId, enabled);
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _resetRules(BuildContext context) async {
    final error = await settings.resetRuleToggles();
    if (error != null && context.mounted) _showError(context, error);
  }

  Future<void> _openExclusions(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExclusionsPage(controller: cleanController, shell: shell),
      ),
    );
  }

  Future<void> _editRetention(BuildContext context) async {
    final service = retention;
    if (service == null) return;
    await service.ensureInitialized();
    if (!context.mounted) return;
    final current = service.policy;
    final result = await showQuarantinePolicyDialog(
      context,
      policy: current ?? QuarantineRetentionPolicy.defaults,
    );
    if (result == null || !context.mounted) return;
    try {
      final report = await service.save(result);
      if (!context.mounted) return;
      if (report != null && report.removedSessionCount > 0) {
        _showMessage(
          context,
          context.tf('自动保留策略已永久释放 {count} 个旧会话。', {
            'count': report.removedSessionCount,
          }),
        );
      } else {
        _showMessage(context, context.t('保留策略已保存。'));
      }
    } catch (error) {
      if (context.mounted) {
        _showError(context, context.tf('无法保存保留策略：{error}', {'error': error}));
      }
    }
  }

  String _retentionSummary(BuildContext context) {
    final service = retention;
    if (service == null) return context.t('无法读取当前保留策略。');
    if (service.loadError != null) {
      return context.t('保留策略读取失败，自动永久释放已停用');
    }
    final policy = service.policy;
    if (policy == null || !policy.enabled) {
      return context.t('自动永久释放未开启');
    }
    return context.tf('保留 {days} 天 · 上限 {bytes}', {
      'days': policy.retentionDays,
      'bytes': formatBytes(policy.maxBytes),
    });
  }

  Future<void> _copyPath(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: cleanController.quarantine.quarantineRoot),
    );
    if (context.mounted) {
      _showMessage(context, context.t('已复制路径'));
    }
  }

  Future<void> _revealPath(BuildContext context) async {
    try {
      await shell.revealPath(cleanController.quarantine.quarantineRoot);
    } on SystemShellException catch (error) {
      if (context.mounted) _showError(context, error.message);
    }
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
  }
}

class _RuleUpdateSection extends StatelessWidget {
  const _RuleUpdateSection({
    required this.updates,
    required this.onEditUrl,
    required this.onCheck,
    required this.onApply,
    required this.onRollback,
    required this.onRestoreBuiltin,
  });

  final RuleUpdateController updates;
  final VoidCallback onEditUrl;
  final VoidCallback onCheck;
  final VoidCallback onApply;
  final VoidCallback onRollback;
  final VoidCallback onRestoreBuiltin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final catalog = updates.activeCatalog;
    final candidate = updates.candidate;
    final sourceLabel = catalog.isBuiltin
        ? context.t('内置规则')
        : context.t('在线更新');
    final canCheck = updates.updatesEnabled && !updates.busy;
    final canRestoreBuiltin = !catalog.isBuiltin && !updates.busy;

    return _Section(
      icon: Icons.system_update_alt_rounded,
      title: context.t('规则更新'),
      subtitle: context.t(
        '在线规则清单必须使用 HTTPS，并通过构建时注入的签名密钥校验。'
        '更新会完整替换规则目录；缺少内置规则、审计信息或签名不符都会被拒绝。',
      ),
      trailing: updates.busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (updates.storeError case final error?)
            _SettingsBanner(message: error, isError: true),
          if (!updates.updatesEnabled)
            _SettingsBanner(
              message: context.t(
                '此构建未配置规则签名密钥，在线更新已禁用。'
                '请使用 --dart-define=BROOM_RULE_SIGNING_KEY=... 构建后再启用。',
              ),
            ),
          if (updates.error case final error?)
            _SettingsBanner(message: error, isError: true),
          if (updates.notice case final notice?)
            _SettingsBanner(message: notice),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_outlined),
            title: Text(
              context.tf('当前规则版本：{version}', {'version': catalog.version}),
            ),
            subtitle: Text(
              context.tf('{source} · {count} 条规则', {
                'source': sourceLabel,
                'count': catalog.rules.length,
              }),
            ),
          ),
          ListTile(
            key: const ValueKey('settings-rule-update-url'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link_rounded),
            title: Text(context.t('规则更新地址')),
            subtitle: SelectableText(
              updates.updateUrl.isEmpty ? context.t('未设置') : updates.updateUrl,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            trailing: TextButton(
              onPressed: onEditUrl,
              child: Text(context.t('设置地址')),
            ),
          ),
          if (candidate != null)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.new_releases_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tf('规则版本 {version} 已下载并通过签名校验', {
                        'version': candidate.manifestVersion,
                      }),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  FilledButton(
                    key: const ValueKey('rule-update-apply'),
                    onPressed: updates.busy ? null : onApply,
                    child: Text(context.t('应用')),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('rule-update-check'),
                onPressed: canCheck ? onCheck : null,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(context.t('检查更新')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('rule-update-rollback'),
                onPressed: updates.hasPrevious && !updates.busy
                    ? onRollback
                    : null,
                icon: const Icon(Icons.undo_rounded, size: 17),
                label: Text(context.t('回滚上一版')),
              ),
              TextButton(
                key: const ValueKey('rule-update-builtin'),
                onPressed: canRestoreBuiltin ? onRestoreBuiltin : null,
                child: Text(context.t('恢复内置规则')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                ?trailing,
              ],
            ),
            if (subtitle case final subtitle?) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SettingsBanner extends StatelessWidget {
  const _SettingsBanner({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSurfaceVariant;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: isError
            ? scheme.errorContainer.withValues(alpha: 0.65)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? scheme.error.withValues(alpha: 0.2)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _categoryIcon(String category) {
  final lower = category.toLowerCase();
  if (category.contains('浏览器') || lower.contains('browser')) {
    return Icons.public_rounded;
  }
  if (category.contains('日志') || lower.contains('log')) {
    return Icons.receipt_long_outlined;
  }
  if (category.contains('缩略图') || lower.contains('thumbnail')) {
    return Icons.image_outlined;
  }
  if (category.contains('GPU') || lower.contains('graphics')) {
    return Icons.memory_rounded;
  }
  if (category.contains('应用') || lower.contains('app cache')) {
    return Icons.apps_rounded;
  }
  if (category.contains('开发') || lower.contains('developer')) {
    return Icons.code_rounded;
  }
  return Icons.folder_outlined;
}
