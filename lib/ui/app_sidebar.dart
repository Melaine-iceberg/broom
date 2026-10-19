import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: expanded ? 214 : 68,
      child: GlassSurface(
        radius: 22,
        blur: 28,
        color: BroomColors.sidebar(context),
        shadow: false,
        padding: EdgeInsets.fromLTRB(
          expanded ? 10 : 8,
          14,
          expanded ? 10 : 8,
          12,
        ),
        child: Stack(
          children: [
            const Positioned.fill(
              child: AmbientGlow(
                alignment: Alignment.topLeft,
                radius: 1.15,
                opacity: 0.22,
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NavItem(
                  key: const ValueKey('sidebar-clean'),
                  icon: Icons.cleaning_services_rounded,
                  label: context.t('清理'),
                  expanded: expanded,
                  selected: section == AppSection.clean,
                  onTap: () => onSelected(AppSection.clean),
                ),
                SizedBox(height: expanded ? 22 : 16),
                if (expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
                    child: Text(
                      context.t('工具'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: BroomColors.inkFaint(context),
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                _NavItem(
                  key: const ValueKey('sidebar-system-cache'),
                  icon: Icons.admin_panel_settings_outlined,
                  label: context.t('系统缓存'),
                  expanded: expanded,
                  selected: section == AppSection.systemCache,
                  onTap: () => onSelected(AppSection.systemCache),
                ),
                _NavItem(
                  key: const ValueKey('sidebar-recycle-bin'),
                  icon: Icons.delete_outline_rounded,
                  label: context.t('回收站'),
                  expanded: expanded,
                  selected: section == AppSection.recycleBin,
                  onTap: () => onSelected(AppSection.recycleBin),
                ),
                _NavItem(
                  key: const ValueKey('sidebar-duplicates'),
                  icon: Icons.copy_all_outlined,
                  label: context.t('重复文件'),
                  expanded: expanded,
                  selected: section == AppSection.duplicates,
                  onTap: () => onSelected(AppSection.duplicates),
                ),
                _NavItem(
                  key: const ValueKey('sidebar-large-files'),
                  icon: Icons.sd_storage_outlined,
                  label: context.t('大文件'),
                  expanded: expanded,
                  selected: section == AppSection.largeFiles,
                  onTap: () => onSelected(AppSection.largeFiles),
                ),
                SizedBox(height: expanded ? 22 : 16),
                if (expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
                    child: Text(
                      context.t('记录'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: BroomColors.inkFaint(context),
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                _NavItem(
                  key: const ValueKey('sidebar-quarantine'),
                  icon: Icons.inventory_2_outlined,
                  label: context.t('隔离区'),
                  expanded: expanded,
                  selected: section == AppSection.quarantine,
                  badge: quarantineCount > 0 ? '$quarantineCount' : null,
                  onTap: () => onSelected(AppSection.quarantine),
                ),
                if (showHistory)
                  _NavItem(
                    key: const ValueKey('sidebar-history'),
                    icon: Icons.history_rounded,
                    label: context.t('清理历史'),
                    expanded: expanded,
                    selected: section == AppSection.history,
                    onTap: () => onSelected(AppSection.history),
                  ),
                const Spacer(),
                if (expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 13,
                          color: BroomColors.inkFaint(context),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            context.t('仅在本机处理'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: BroomColors.inkFaint(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Container(
                  height: 1,
                  margin: const EdgeInsets.only(bottom: 8, left: 6, right: 6),
                  color: BroomColors.hairline(context),
                ),
                _NavItem(
                  key: const ValueKey('open-settings'),
                  icon: Icons.settings_outlined,
                  label: context.t('设置'),
                  expanded: expanded,
                  selected: section == AppSection.settings,
                  onTap: () => onSelected(AppSection.settings),
                ),
              ],
            ),
          ],
        ),
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
        ? (BroomColors.isDark(context) ? BroomColors.accent : scheme.primary)
        : BroomColors.inkMuted(context);

    final background = selected
        ? scheme.primary.withValues(
            alpha: BroomColors.isDark(context) ? 0.16 : 0.12,
          )
        : _hovered
        ? Colors.white.withValues(
            alpha: BroomColors.isDark(context) ? 0.055 : 0.5,
          )
        : Colors.transparent;

    final item = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: 38,
      margin: const EdgeInsets.symmetric(vertical: 1.5),
      padding: EdgeInsets.symmetric(horizontal: widget.expanded ? 10 : 0),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _focused
              ? scheme.primary.withValues(alpha: 0.7)
              : selected
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
      ),
      child: Row(
        mainAxisAlignment: widget.expanded
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(widget.icon, size: 18, color: foreground),
              if (!widget.expanded && widget.badge != null)
                Positioned(
                  right: -2,
                  top: -1,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          if (widget.expanded) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected
                      ? BroomColors.ink(context)
                      : BroomColors.inkMuted(context),
                ),
              ),
            ),
            if (widget.badge case final badge?)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badge,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                    fontSize: 9.5,
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
              child: item,
            ),
          ),
        ),
      ),
    );
  }
}
