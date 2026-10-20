import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/broom_strings.dart';

Future<void> showOnboardingDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const OnboardingDialog(),
  );
}

class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({super.key});

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  static const _lastStep = 2;
  int _step = 0;

  void _next() {
    if (_step >= _lastStep) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _step++);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final steps = <({IconData icon, String title, String body, String point})>[
      (
        icon: LucideIcons.search,
        title: context.t('先扫描，再决定'),
        body: context.t(
          '扫描只读取文件信息，不会修改任何文件。结果先进入预览，'
          '由你决定要清理哪些内容；安全缓存默认勾选，需确认的缓存默认不勾选。',
        ),
        point: context.t('预览支持搜索、排序与逐文件勾选。'),
      ),
      (
        icon: LucideIcons.archive,
        title: context.t('隔离区不是永久删除'),
        body: context.t(
          '清理时文件会移动到 Broom 隔离区，磁盘空间不会立即释放。'
          '你可以随时恢复，只有永久释放才算真正删除。',
        ),
        point: context.t('恢复冲突时可保留两者或覆盖；永久释放需要单独确认。'),
      ),
      (
        icon: LucideIcons.shieldCheck,
        title: context.t('安全边界'),
        body: context.t(
          'Broom 不会触碰文档、照片、程序和系统文件，也不会扫描浏览器密码、'
          'Cookie 或历史记录。所有处理都在本机完成，不上传文件、路径或使用数据。',
        ),
        point: context.t('管理员工具需要独立提权；被占用的文件会跳过并单独报告。'),
      ),
    ];
    final step = steps[_step];

    return AlertDialog(
      key: const ValueKey('onboarding-dialog'),
      icon: Icon(step.icon, size: 34, color: scheme.primary),
      title: Text(context.t('欢迎使用 Broom'), textAlign: TextAlign.center),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_step == 0) ...[
                  Text(
                    context.t('用三步了解缓存清理、隔离区与安全边界。'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                Semantics(
                  key: ValueKey('onboarding-step-$_step'),
                  container: true,
                  liveRegion: true,
                  label: step.title,
                  child: Column(
                    children: [
                      Text(
                        step.title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        step.body,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.65,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer.withValues(
                            alpha: 0.35,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              LucideIcons.circleCheck,
                              size: 17,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                step.point,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var index = 0; index <= _lastStep; index++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: index == _step ? 22 : 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: index == _step
                              ? scheme.primary
                              : scheme.outlineVariant,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  context.tf('第 {current} / {total} 步', {
                    'current': _step + 1,
                    'total': _lastStep + 1,
                  }),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('onboarding-skip'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('跳过')),
        ),
        FilledButton(
          key: ValueKey(
            _step == _lastStep ? 'onboarding-done' : 'onboarding-next',
          ),
          onPressed: _next,
          child: Text(
            _step == _lastStep ? context.t('开始使用') : context.t('下一步'),
          ),
        ),
      ],
    );
  }
}
