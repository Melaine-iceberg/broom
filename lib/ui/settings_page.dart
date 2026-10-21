import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../core/app_info.dart';
import '../core/clean/quarantine_retention_service.dart';
import '../core/diagnostics/app_logger.dart';
import '../core/models/app_settings.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/quarantine_policy_models.dart';
import '../core/settings/config_bundle.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'analysis_widgets.dart';
import 'app_update_controller.dart';
import 'clean_controller.dart';
import 'exclusions_page.dart';
import 'format.dart';
import 'glass_ui.dart';
import 'quarantine_policy_dialog.dart';
import 'rule_update_controller.dart';
import 'settings_controller.dart';

const _appVersion = broomAppVersion;

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.cleanController,
    required this.shell,
    this.retention,
    this.ruleUpdates,
    this.appUpdates,
    this.onShowOnboarding,
    this.logger,
  });

  final SettingsController settings;
  final CleanController cleanController;
  final SystemShell shell;
  final QuarantineRetentionService? retention;
  final RuleUpdateController? ruleUpdates;
  final AppUpdateController? appUpdates;
  final VoidCallback? onShowOnboarding;
  final AppLogger? logger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([
        settings,
        cleanController,
        ?ruleUpdates,
        ?appUpdates,
      ]),
      builder: (context, _) {
        final strings = context.strings;
        final rules = cleanController.platform.rules;
        final scanCategories = cleanController.scanCategories;
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
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: strings.t('返回'),
            ),
            toolbarHeight: 76,
            title: Text(strings.t('设置')),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
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
                    icon: LucideIcons.palette,
                    title: strings.t('外观'),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 600;
                        final themeField = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _FieldLabel(label: strings.t('主题')),
                            SegmentedButton<AppThemePreference>(
                              key: const ValueKey('settings-theme-selector'),
                              expandedInsets: EdgeInsets.zero,
                              segments: [
                                ButtonSegment(
                                  value: AppThemePreference.system,
                                  icon: const Icon(
                                    LucideIcons.sunMoon,
                                    size: 16,
                                  ),
                                  label: Text(strings.t('跟随系统')),
                                ),
                                ButtonSegment(
                                  value: AppThemePreference.light,
                                  icon: const Icon(LucideIcons.sun, size: 16),
                                  label: Text(strings.t('浅色')),
                                ),
                                ButtonSegment(
                                  value: AppThemePreference.dark,
                                  icon: const Icon(LucideIcons.moon, size: 16),
                                  label: Text(strings.t('深色')),
                                ),
                              ],
                              selected: {settings.settings.theme},
                              onSelectionChanged: (selection) =>
                                  _setTheme(context, selection.single),
                            ),
                          ],
                        );
                        final languageField = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _FieldLabel(label: strings.t('语言')),
                            SegmentedButton<AppLanguagePreference>(
                              key: const ValueKey('settings-language-selector'),
                              expandedInsets: EdgeInsets.zero,
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
                        );
                        if (!wide) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              themeField,
                              const SizedBox(height: 14),
                              languageField,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: themeField),
                            const SizedBox(width: 20),
                            Expanded(child: languageField),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  _Section(
                    icon: LucideIcons.slidersHorizontal,
                    title: strings.t('扫描引擎'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FieldLabel(label: strings.t('扫描类别')),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = constraints.maxWidth >= 560 ? 2 : 1;
                            final width =
                                (constraints.maxWidth - 12 * (columns - 1)) /
                                columns;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 0,
                              children: [
                                for (final category in scanCategories)
                                  SizedBox(
                                    width: width,
                                    child: CheckboxListTile(
                                      key: ValueKey(
                                        'settings-category-${category.key}',
                                      ),
                                      value: settings.isCategoryEnabled(
                                        category.key,
                                      ),
                                      onChanged: (value) => _setCategory(
                                        context,
                                        category.key,
                                        value ?? false,
                                        refreshLeftover: category.isLeftover,
                                      ),
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      dense: true,
                                      title: Text(
                                        strings.ruleCategoryGroupLabel(
                                          category,
                                        ),
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: BroomColors.ink(context),
                                            ),
                                      ),
                                      subtitle: Text(
                                        _categorySummary(strings, category),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
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
                          subtitle: Text(strings.t('扫描时降低后台 I/O 与 CPU 优先级。')),
                        ),
                        SwitchListTile(
                          key: const ValueKey('settings-ntfs-index'),
                          value: settings.settings.useNtfsIndex,
                          onChanged: (value) => _setNtfsIndex(context, value),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(strings.t('优先使用 NTFS 索引')),
                          subtitle: Text(
                            strings.t('需要管理员权限与 NTFS 卷，不可用时自动回退。'),
                          ),
                        ),
                        ListTile(
                          key: const ValueKey('settings-scan-limit'),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(LucideIcons.gauge, size: 20),
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
                  if (appUpdates case final updates?) ...[
                    const SizedBox(height: 16),
                    _AppUpdateSection(
                      updates: updates,
                      onCheck: () => _checkAppUpdates(context, updates),
                    ),
                  ],
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
                  const SizedBox(height: 18),
                  _Section(
                    icon: LucideIcons.listChecks,
                    title: strings.t('清理规则'),
                    subtitle: strings.t('关闭的规则不会参与扫描。'),
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
                  const SizedBox(height: 18),
                  _Section(
                    icon: LucideIcons.archive,
                    title: strings.t('扫描与隔离'),
                    child: Column(
                      children: [
                        ListTile(
                          key: const ValueKey('settings-exclusions'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(LucideIcons.ban),
                          title: Text(strings.t('排除列表')),
                          subtitle: Text(
                            cleanController.exclusionCount == 0
                                ? strings.t('没有排除项')
                                : strings.tf('{count} 个目录不参与扫描', {
                                    'count': cleanController.exclusionCount,
                                  }),
                          ),
                          trailing: const Icon(LucideIcons.chevronRight),
                          onTap: () => _openExclusions(context),
                        ),
                        const Divider(),
                        ListTile(
                          key: const ValueKey('settings-retention'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(LucideIcons.clock),
                          title: Text(strings.t('隔离区保留策略')),
                          subtitle: Text(_retentionSummary(context)),
                          trailing: const Icon(LucideIcons.chevronRight),
                          enabled: retention != null,
                          onTap: retention == null
                              ? null
                              : () => _editRetention(context),
                        ),
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(LucideIcons.folder),
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
                                icon: const Icon(LucideIcons.copy, size: 18),
                                onPressed: () => _copyPath(context),
                              ),
                              IconButton(
                                key: const ValueKey('settings-reveal-path'),
                                tooltip: strings.t('在资源管理器中显示'),
                                icon: const Icon(
                                  LucideIcons.externalLink,
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
                  _ConfigTransferSection(
                    settings: settings,
                    cleanController: cleanController,
                    retention: retention,
                    shell: shell,
                  ),
                  if (logger case final logger?) ...[
                    const SizedBox(height: 16),
                    _DiagnosticsSection(
                      settings: settings,
                      logger: logger,
                      shell: shell,
                    ),
                  ],
                  const SizedBox(height: 18),
                  _Section(
                    icon: LucideIcons.info,
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
                        const SizedBox(height: 6),
                        Text(
                          strings.t(
                            '界面字体使用 HarmonyOS Sans（© Huawei Device Co., Ltd.），依据 HarmonyOS Sans Fonts License Agreement 授权使用。',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        if (onShowOnboarding != null) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const ValueKey('settings-onboarding'),
                            onPressed: onShowOnboarding,
                            icon: const Icon(
                              LucideIcons.graduationCap,
                              size: 18,
                            ),
                            label: Text(strings.t('重新查看首次使用引导')),
                          ),
                        ],
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
    bool enabled, {
    bool refreshLeftover = false,
  }) async {
    final error = await settings.setCategoryEnabled(categoryId, enabled);
    if (context.mounted && error != null) _showError(context, error);
    if (context.mounted && refreshLeftover) {
      await cleanController.refreshLeftoverRules();
    }
  }

  /// Category subtitle: rule counts for catalog categories, detection state
  /// for the runtime leftover category.
  String _categorySummary(BroomStrings strings, RuleCategoryGroup category) {
    if (!settings.isCategoryEnabled(category.key)) return strings.t('本次跳过');
    if (category.isLeftover) {
      if (cleanController.leftoverDetectionError != null) {
        return strings.t('无法读取应用清单，已跳过检测');
      }
      if (category.isEmpty) return strings.t('未检测到残留应用');
      return strings.tf('{count} 个残留应用', {'count': category.ruleCount});
    }
    return strings.tf('{count} 条规则', {'count': category.ruleCount});
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

  Future<void> _checkAppUpdates(
    BuildContext context,
    AppUpdateController updates,
  ) async {
    await updates.check();
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
        icon: const Icon(LucideIcons.download, size: 30),
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

class _AppUpdateSection extends StatelessWidget {
  const _AppUpdateSection({required this.updates, required this.onCheck});

  final AppUpdateController updates;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = updates.info;
    final current = updates.currentVersion;

    return _Section(
      icon: LucideIcons.packageCheck,
      title: context.t('软件更新'),
      subtitle: context.t(
        '通过 App Installer 更新源检查新版本。下载、安装与签名校验都由 Windows 完成，'
        '应用本身只读取清单、不运行任何安装程序。',
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
          if (updates.error case final error?)
            _SettingsBanner(message: error, isError: true),
          if (updates.notice case final notice?)
            _SettingsBanner(message: notice),
          ListTile(
            key: const ValueKey('settings-app-version'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.packageCheck),
            title: Text(
              context.tf('当前版本：{version}', {
                'version': current ?? context.t('未知'),
              }),
            ),
            subtitle: info == null
                ? null
                : Text(
                    context.tf('更新源版本：{version}', {
                      'version': info.latestVersion.toString(),
                    }),
                  ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.globe),
            title: Text(context.t('更新源')),
            subtitle: SelectableText(
              updates.feedUrl,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('settings-check-app-update'),
                onPressed: updates.busy ? null : onCheck,
                icon: const Icon(LucideIcons.download, size: 18),
                label: Text(context.t('检查更新')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.t('发现新版本后，Windows 会在后台完成下载与安装，重启应用即可生效。'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
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
      icon: LucideIcons.download,
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
            leading: const Icon(LucideIcons.shieldCheck),
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
            leading: const Icon(LucideIcons.link),
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
                    LucideIcons.packageCheck,
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
                icon: const Icon(LucideIcons.refreshCw, size: 17),
                label: Text(context.t('检查更新')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('rule-update-rollback'),
                onPressed: updates.hasPrevious && !updates.busy
                    ? onRollback
                    : null,
                icon: const Icon(LucideIcons.undo2, size: 17),
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

class _ConfigTransferSection extends StatefulWidget {
  const _ConfigTransferSection({
    required this.settings,
    required this.cleanController,
    required this.retention,
    required this.shell,
  });

  final SettingsController settings;
  final CleanController cleanController;
  final QuarantineRetentionService? retention;
  final SystemShell shell;

  @override
  State<_ConfigTransferSection> createState() => _ConfigTransferSectionState();
}

class _ConfigTransferSectionState extends State<_ConfigTransferSection> {
  static const _transfer = ConfigTransferService();

  bool _busy = false;

  SettingsController get settings => widget.settings;

  CleanController get cleanController => widget.cleanController;

  QuarantineRetentionService? get retention => widget.retention;

  bool get _blocked => _busy || cleanController.isBusy;

  Future<void> _export() async {
    if (_blocked) return;
    setState(() => _busy = true);
    try {
      final bundle = await _snapshotForExport();
      if (!mounted) return;
      final path = await widget.shell.saveJsonFile(
        suggestedName: _suggestedFileName(),
        title: context.t('导出 Broom 配置'),
      );
      if (path == null || !mounted) return;
      await _transfer.exportTo(filePath: path, bundle: bundle);
      if (!mounted) return;
      _showMessage(
        context.tf('配置已导出：{name}', {'name': p.windows.basename(path)}),
      );
    } on SystemShellException catch (error) {
      if (mounted) _showError(error.message);
    } on ConfigTransferException catch (error) {
      if (mounted) _showError(error.message);
    } catch (error) {
      if (mounted) {
        _showError(context.tf('无法导出配置：{error}', {'error': error}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ConfigBundle> _snapshotForExport() async {
    final strings = BroomStrings.instance;
    if (settings.loadError != null) {
      throw ConfigTransferException(strings.t('设置读取失败，请先恢复默认配置或导入配置。'));
    }
    try {
      await cleanController.exclusions.ensureLoaded();
    } catch (error) {
      throw ConfigTransferException(
        strings.tf('排除列表读取失败，请先重置后再导出：{error}', {'error': error}),
      );
    }
    final service = retention;
    if (service == null) {
      throw ConfigTransferException(strings.t('当前无法读取保留策略，配置未导出。'));
    }
    await service.ensureInitialized();
    if (service.loadError != null) {
      throw ConfigTransferException(
        strings.tf('保留策略读取失败，请先恢复默认配置后再导出：{error}', {
          'error': service.loadError,
        }),
      );
    }
    return ConfigBundle(
      settings: settings.settings,
      exclusions: cleanController.exclusions.paths,
      retention: service.policy ?? QuarantineRetentionPolicy.defaults,
    );
  }

  Future<void> _import() async {
    if (_blocked) return;
    setState(() => _busy = true);
    try {
      final path = await widget.shell.pickJsonFile(
        title: context.t('导入 Broom 配置'),
      );
      if (path == null || !mounted) return;
      final bundle = await _transfer.importFrom(path);
      if (!mounted) return;

      // The modal dialog itself blocks the page; stop the spinner while the
      // user reviews the summary so the frame can settle.
      setState(() => _busy = false);
      final confirmed = await _confirmImport(bundle, path);
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);

      final errors = <String>[];
      final exclusionError = await cleanController.replaceExclusions(
        bundle.exclusions,
      );
      if (exclusionError != null) {
        errors.add(exclusionError);
      }
      final settingsError = await settings.importSettings(bundle.settings);
      if (settingsError != null) {
        errors.add(settingsError);
      }
      final service = retention;
      if (service == null) {
        errors.add(BroomStrings.instance.t('当前无法保存保留策略，该部分未导入。'));
      } else {
        try {
          // Never enable automatic permanent release just because a file was
          // imported. The user can opt back in from the quarantine page.
          await service.replacePolicy(
            bundle.retention.copyWith(enabled: false),
          );
        } catch (error) {
          errors.add(
            BroomStrings.instance.tf('保留策略未导入：{error}', {'error': error}),
          );
        }
      }

      if (!mounted) return;
      if (errors.isEmpty) {
        _showMessage(
          bundle.retention.enabled
              ? context.t(
                  '配置已导入。为避免自动永久释放，保留策略保持关闭；'
                  '可在隔离区页重新开启。',
                )
              : context.t('配置已导入。'),
        );
      } else {
        _showError(
          context.tf('配置已部分导入：{errors}', {'errors': errors.join(' ')}),
        );
      }
    } on SystemShellException catch (error) {
      if (mounted) _showError(error.message);
    } on ConfigBundleException catch (error) {
      if (mounted) _showError(error.message);
    } on ConfigTransferException catch (error) {
      if (mounted) _showError(error.message);
    } catch (error) {
      if (mounted) {
        _showError(context.tf('无法导入配置：{error}', {'error': error}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmImport(ConfigBundle bundle, String path) {
    final retention = bundle.retention;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final strings = dialogContext.strings;
        return AlertDialog(
          icon: const Icon(LucideIcons.fileUp, size: 30),
          title: Text(strings.t('导入配置？')),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.t(
                      '将替换当前的主题、语言、规则开关、扫描设置、'
                      '排除列表与保留策略。',
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ImportSummaryLine(
                    icon: LucideIcons.palette,
                    text: strings.tf('{theme} · {language}', {
                      'theme': _themeLabel(strings, bundle.settings.theme),
                      'language': _languageLabel(
                        strings,
                        bundle.settings.language,
                      ),
                    }),
                  ),
                  _ImportSummaryLine(
                    icon: LucideIcons.listChecks,
                    text: strings.tf('{rules} 条关闭规则 · {categories} 个关闭类别', {
                      'rules': bundle.settings.disabledRuleIds.length,
                      'categories': bundle.settings.disabledCategoryIds.length,
                    }),
                  ),
                  _ImportSummaryLine(
                    icon: LucideIcons.ban,
                    text: strings.tf('{count} 个排除目录（路径需与本机一致才会生效）', {
                      'count': bundle.exclusions.length,
                    }),
                  ),
                  _ImportSummaryLine(
                    icon: LucideIcons.clock,
                    text: retention.enabled
                        ? strings.tf(
                            '保留策略已开启（保留 {days} 天 · 上限 {bytes}），'
                            '导入后将保持关闭',
                            {
                              'days': retention.retentionDays,
                              'bytes': formatBytes(retention.maxBytes),
                            },
                          )
                        : strings.tf('保留策略未开启（保留 {days} 天 · 上限 {bytes}）', {
                            'days': retention.retentionDays,
                            'bytes': formatBytes(retention.maxBytes),
                          }),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    strings.t(
                      '隔离区文件、清理历史与扫描结果不在配置中，'
                      '导入不会删除或修改它们，也不会立即释放任何文件。',
                    ),
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant,
                          height: 1.5,
                        ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    p.windows.basename(path),
                    style: Theme.of(dialogContext).textTheme.labelSmall
                        ?.copyWith(
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.t('取消')),
            ),
            FilledButton(
              key: const ValueKey('settings-config-confirm-import'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.t('导入并替换')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _reset() async {
    if (_blocked) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(LucideIcons.rotateCcw, size: 30),
        title: Text(context.t('恢复默认配置？')),
        content: Text(
          context.t(
            '主题、语言、规则开关、扫描设置与规则更新地址将恢复默认；'
            '排除列表会被清空，自动保留策略会关闭。'
            '隔离区文件、清理历史与扫描结果不会被删除或修改。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey('settings-config-confirm-reset'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.t('恢复默认')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final errors = <String>[];
    try {
      final exclusionError = await cleanController.resetExclusions();
      if (exclusionError != null) {
        errors.add(exclusionError);
      }
      final service = retention;
      if (service == null) {
        errors.add(BroomStrings.instance.t('当前无法重置保留策略。'));
      } else {
        try {
          await service.replacePolicy(QuarantineRetentionPolicy.defaults);
        } catch (error) {
          errors.add(
            BroomStrings.instance.tf('保留策略未重置：{error}', {'error': error}),
          );
        }
      }
      final settingsError = await settings.restoreDefaults();
      if (settingsError != null) {
        errors.add(settingsError);
      }

      if (!mounted) return;
      if (errors.isEmpty) {
        _showMessage(context.t('已恢复默认配置。隔离区文件与历史记录未受影响。'));
      } else {
        _showError(
          context.tf('配置未能全部重置：{errors}', {'errors': errors.join(' ')}),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _suggestedFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'broom-config-${now.year}-${two(now.month)}-${two(now.day)}.json';
  }

  String _themeLabel(BroomStrings strings, AppThemePreference theme) {
    return switch (theme) {
      AppThemePreference.system => strings.t('跟随系统'),
      AppThemePreference.light => strings.t('浅色'),
      AppThemePreference.dark => strings.t('深色'),
    };
  }

  String _languageLabel(BroomStrings strings, AppLanguagePreference language) {
    return switch (language) {
      AppLanguagePreference.system => strings.t('跟随系统'),
      AppLanguagePreference.zh => strings.t('简体中文'),
      AppLanguagePreference.en => 'English',
    };
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  void _showError(String message) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _Section(
      icon: LucideIcons.arrowLeftRight,
      title: context.t('备份与恢复'),
      subtitle: context.t(
        '导出或导入主题、语言、规则开关、扫描设置、排除列表与保留策略。'
        '配置不包含隔离区文件、清理历史、扫描结果或在线规则目录。',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('settings-config-export'),
                onPressed: _blocked ? null : _export,
                icon: const Icon(LucideIcons.download, size: 17),
                label: Text(context.t('导出配置')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('settings-config-import'),
                onPressed: _blocked ? null : _import,
                icon: const Icon(LucideIcons.upload, size: 17),
                label: Text(context.t('导入配置')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.t(
              '导入会替换当前配置；保留策略以关闭状态导入，不会立即释放隔离区文件。'
              '排除目录的路径必须在本机存在才会生效。',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.t('导出文件包含排除目录的绝对路径，请妥善保管。'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 24),
          ListTile(
            key: const ValueKey('settings-config-reset'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(LucideIcons.history, color: scheme.error),
            title: Text(context.t('恢复默认配置')),
            subtitle: Text(context.t('清除偏好设置与排除列表，并关闭自动保留策略；不会删除隔离区文件。')),
            trailing: TextButton(
              onPressed: _blocked ? null : _reset,
              child: Text(context.t('恢复默认')),
            ),
            onTap: _blocked ? null : _reset,
          ),
        ],
      ),
    );
  }
}

class _ImportSummaryLine extends StatelessWidget {
  const _ImportSummaryLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsSection extends StatefulWidget {
  const _DiagnosticsSection({
    required this.settings,
    required this.logger,
    required this.shell,
  });

  final SettingsController settings;
  final AppLogger logger;
  final SystemShell shell;

  @override
  State<_DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<_DiagnosticsSection> {
  bool _busy = false;
  bool _toggling = false;

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _toggling = true);
    final error = await widget.settings.setDiagnosticsEnabled(enabled);
    if (!mounted) return;
    setState(() => _toggling = false);
    if (error != null) {
      _showError(context.tf('无法更新诊断日志设置：{error}', {'error': error}));
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final locale = context.strings.localeName;
      final path = await widget.shell.saveJsonFile(
        suggestedName: 'broom-diagnostics-$stamp.json',
        title: context.t('导出诊断信息'),
      );
      if (path == null || path.isEmpty) return;
      final bundle = await widget.logger.buildBundle(
        appVersion: _appVersion,
        environment: {
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'locale': locale,
          'processors': '${Platform.numberOfProcessors}',
        },
      );
      File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(bundle),
        flush: true,
      );
      widget.logger.info('diagnostics', '诊断信息已导出');
      if (!mounted) return;
      _showMessage(
        context.tf('诊断信息已导出：{name}', {'name': p.windows.basename(path)}),
      );
    } catch (error) {
      if (!mounted) return;
      _showError(context.tf('无法导出诊断信息：{error}', {'error': error}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  void _showError(String message) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = widget.settings.diagnosticsEnabled;
    return _Section(
      icon: LucideIcons.bug,
      title: context.t('诊断与日志'),
      subtitle: context.t(
        '日志默认关闭，仅保存在本地，不记录文件内容。启用后仅记录操作事件、'
        '错误信息与统计数字，用于排查问题；可随时导出诊断包并分享给开发者。',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const ValueKey('settings-diagnostics-toggle'),
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: _toggling || _busy ? null : _setEnabled,
            title: Text(context.t('启用本地诊断日志')),
            subtitle: Text(
              enabled
                  ? context.t('运行事件将写入 Broom 日志目录，最多保留 3 个滚动文件。')
                  : context.t('当前未写入任何诊断日志。'),
            ),
          ),
          const Divider(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('settings-diagnostics-export'),
              onPressed: _busy ? null : _export,
              icon: const Icon(LucideIcons.download, size: 17),
              label: Text(context.t('导出诊断信息')),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.t(
              '诊断包为 JSON 文件，包含版本、系统环境、日志级别与滚动日志。'
              '日志未启用时仍可导出环境信息用于排查启动问题。',
            ),
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

    return Container(
      decoration: BoxDecoration(
        color: BroomColors.card(context),
        borderRadius: BorderRadius.circular(26),
        boxShadow: BroomColors.cardShadow(context),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 19, color: BroomColors.inkMuted(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.15,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BroomColors.inkMuted(context),
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              child,
            ],
          ),
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
          fontSize: 12.5,
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
            : BroomColors.block(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            isError ? LucideIcons.circleAlert : LucideIcons.info,
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
  if (category.contains('残留') || lower.contains('leftover')) {
    return LucideIcons.packageX;
  }
  if (category.contains('浏览器') || lower.contains('browser')) {
    return LucideIcons.globe;
  }
  if (category.contains('日志') || lower.contains('log')) {
    return LucideIcons.receiptText;
  }
  if (category.contains('缩略图') || lower.contains('thumbnail')) {
    return LucideIcons.image;
  }
  if (category.contains('GPU') || lower.contains('graphics')) {
    return LucideIcons.cpu;
  }
  if (category.contains('应用') || lower.contains('app cache')) {
    return LucideIcons.layoutGrid;
  }
  if (category.contains('开发') || lower.contains('developer')) {
    return LucideIcons.code;
  }
  return LucideIcons.folder;
}
