import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/broom_strings.dart';
import 'glass_ui.dart';

enum AppSection {
  clean,
  systemCache,
  recycleBin,
  duplicates,
  largeFiles,
  quarantine,
  history,
  settings,
}

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.section,
    required this.expanded,
    required this.onSelected,
    this.quarantineCount = 0,
    this.showHistory = true,
  });

  final AppSection section;
  final bool expanded;
  final ValueChanged<AppSection> onSelected;
  final int quarantineCount;
  final bool showHistory;

  static const double expandedWidth = 224;
  static const double compactWidth = 64;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: BroomColors.inkFaint(context),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: expanded ? expandedWidth : compactWidth,
      color: BroomColors.sidebar(context),
      padding: EdgeInsets.fromLTRB(
        expanded ? 12 : 8,
        14,
        expanded ? 12 : 8,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _NavItem(
            key: const ValueKey('sidebar-clean'),
            icon: LucideIcons.sparkles,
            label: context.t('清理'),
            expanded: expanded,
            selected: section == AppSection.clean,
            onTap: () => onSelected(AppSection.clean),
          ),
          const SizedBox(height: 18),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(context.t('工具'), style: labelStyle),
            ),
          _NavItem(
            key: const ValueKey('sidebar-system-cache'),
            icon: LucideIcons.database,
            label: context.t('系统缓存'),
            expanded: expanded,
            selected: section == AppSection.systemCache,
            onTap: () => onSelected(AppSection.systemCache),
          ),
          _NavItem(
            key: const ValueKey('sidebar-recycle-bin'),
            icon: LucideIcons.trash2,
            label: context.t('回收站'),
            expanded: expanded,
            selected: section == AppSection.recycleBin,
            onTap: () => onSelected(AppSection.recycleBin),
          ),
          _NavItem(
            key: const ValueKey('sidebar-duplicates'),
            icon: LucideIcons.copy,
            label: context.t('重复文件'),
            expanded: expanded,
            selected: section == AppSection.duplicates,
            onTap: () => onSelected(AppSection.duplicates),
          ),
          _NavItem(
            key: const ValueKey('sidebar-large-files'),
            icon: LucideIcons.hardDrive,
            label: context.t('大文件'),
            expanded: expanded,
            selected: section == AppSection.largeFiles,
            onTap: () => onSelected(AppSection.largeFiles),
          ),
          const SizedBox(height: 18),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(context.t('记录'), style: labelStyle),
            ),
          _NavItem(
            key: const ValueKey('sidebar-quarantine'),
            icon: LucideIcons.archive,
            label: context.t('隔离区'),
            expanded: expanded,
            selected: section == AppSection.quarantine,
            badge: quarantineCount > 0 ? '$quarantineCount' : null,
            onTap: () => onSelected(AppSection.quarantine),
          ),
          if (showHistory)
            _NavItem(
              key: const ValueKey('sidebar-history'),
              icon: LucideIcons.history,
              label: context.t('清理历史'),
              expanded: expanded,
              selected: section == AppSection.history,
              onTap: () => onSelected(AppSection.history),
            ),
          const Spacer(),
          Container(
            height: 1,
            margin: EdgeInsets.symmetric(horizontal: expanded ? 4 : 10),
            color: BroomColors.hairline(context),
          ),
          const SizedBox(height: 8),
          _NavItem(
            key: const ValueKey('open-settings'),
            icon: LucideIcons.settings,
            label: context.t('设置'),
            expanded: expanded,
            selected: section == AppSection.settings,
            onTap: () => onSelected(AppSection.settings),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.expanded,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final selected = widget.selected;
    final foreground = selected
        ? BroomColors.ink(context)
        : BroomColors.inkMuted(context);
    final iconColor = selected ? scheme.primary : BroomColors.inkMuted(context);

    final background = selected
        ? BroomColors.ink(context)
              .withValues(alpha: BroomColors.isDark(context) ? 0.1 : 0.07)
        : _hovered
        ? BroomColors.ink(context)
              .withValues(alpha: BroomColors.isDark(context) ? 0.06 : 0.04)
        : Colors.transparent;

    final item = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: 40,
      margin: const EdgeInsets.symmetric(vertical: 1.5),
      padding: EdgeInsets.symmetric(horizontal: widget.expanded ? 13 : 0),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(11),
        border: _focused
            ? Border.all(color: scheme.primary.withValues(alpha: 0.7))
            : null,
      ),
      child: Row(
        mainAxisAlignment: widget.expanded
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(widget.icon, size: 21, color: iconColor),
              if (!widget.expanded && widget.badge != null)
                Positioned(
                  right: -4,
                  top: 3,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: BroomColors.sidebar(context),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (widget.expanded) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: -0.1,
                  color: foreground,
                ),
              ),
            ),
            if (widget.badge case final badge?)
              Container(
                height: 19,
                constraints: const BoxConstraints(minWidth: 19),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
          ],
        ],
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: Tooltip(
        message: widget.expanded ? '' : widget.label,
        waitDuration: const Duration(milliseconds: 400),
        child: FocusableActionDetector(
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  item,
                  if (selected)
                    Positioned(
                      left: widget.expanded ? -12 : 5,
                      top: 11,
                      child: Container(
                        width: 3,
                        height: 18,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
