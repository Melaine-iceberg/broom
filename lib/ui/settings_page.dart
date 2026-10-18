import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/clean/quarantine_retention_service.dart';
import '../core/models/app_settings.dart';
import '../core/models/cleaner_rule.dart';
import '../core/models/quarantine_policy_models.dart';
import '../core/shell/system_shell.dart';
import '../l10n/broom_strings.dart';
import 'clean_controller.dart';
import 'exclusions_page.dart';
import 'format.dart';
import 'quarantine_policy_dialog.dart';
import 'settings_controller.dart';

const _appVersion = '0.4.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.cleanController,
    required this.shell,
    this.retention,
  });

  final SettingsController settings;
  final CleanController cleanController;
  final SystemShell shell;
  final QuarantineRetentionService? retention;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([settings, cleanController]),
      builder: (context, _) {
        final strings = context.strings;
        final rules = cleanController.platform.rules
            .where((rule) => rule.risk == CleanRisk.safe)
            .toList();
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
                    icon: Icons.rule_rounded,
                    title: strings.t('清理规则'),
                    subtitle: strings.t(
                      '关闭的规则不会参与扫描，也不会出现在清理结果中。排除列表仍然优先于所有规则。',
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
                              title: Text(strings.ruleTitle(rule)),
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
  if (category.contains('开发') || lower.contains('developer')) {
    return Icons.code_rounded;
  }
  return Icons.memory_rounded;
}
