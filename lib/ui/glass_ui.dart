import 'package:flutter/material.dart';

import 'broom_fonts.dart';

/// Shared colors and surfaces for the desktop shell.
///
/// The palette follows the iOS grouped-surface model: a softly tinted page,
/// bright cards floating on it, and blocks one level deeper for controls.
/// Color is reserved for state, selection and the one primary action.
abstract final class BroomColors {
  /// The single accent used for selection, focus and primary actions.
  static const primary = Color(0xFF007AFF);

  /// Secondary accent, used sparingly for highlights.
  static const accent = primary;

  /// Semantic colours. These are the only colours allowed on a neutral page.
  static const success = Color(0xFF34C759);
  static const warning = Color(0xFFFF9F0A);
  static const danger = Color(0xFFFF3B30);

  // Compatibility alias for older call sites.
  static const amber = warning;

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// The content page behind every card.
  static Color page(BuildContext context) =>
      isDark(context) ? const Color(0xFF0B0C10) : const Color(0xFFF3F4F8);

  /// Window chrome: title bar and navigation sidebar.
  static Color sidebar(BuildContext context) =>
      isDark(context) ? const Color(0xFF101116) : const Color(0xFFEDEFF4);

  /// Default card fill, one step above the page.
  static Color card(BuildContext context) =>
      isDark(context) ? const Color(0xFF17181F) : const Color(0xFFFFFFFF);

  /// Card fill on hover.
  static Color cardHover(BuildContext context) =>
      isDark(context) ? const Color(0xFF1E1F27) : const Color(0xFFFAFBFE);

  /// A neutral block inside a card.
  static Color block(BuildContext context) =>
      isDark(context) ? const Color(0xFF23242C) : const Color(0xFFF0F1F6);

  /// The deepest neutral, used for inset controls and empty media.
  static Color inset(BuildContext context) =>
      isDark(context) ? const Color(0xFF2C2D36) : const Color(0xFFE7E9F0);

  /// Structural hairline. Used for chrome edges and grouped rows only.
  static Color hairline(BuildContext context) =>
      isDark(context) ? const Color(0x1FFFFFFF) : const Color(0x13000000);

  static Color ink(BuildContext context) =>
      isDark(context) ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E);

  static Color inkMuted(BuildContext context) =>
      isDark(context) ? const Color(0xFFA7A7B0) : const Color(0xFF6C6C70);

  static Color inkFaint(BuildContext context) =>
      isDark(context) ? const Color(0xFF75757F) : const Color(0xFFA0A0A8);

  /// Soft tint used behind the dashboard's primary action.
  static Color primaryWash(BuildContext context) =>
      isDark(context) ? const Color(0xFF0A2B52) : const Color(0xFFE3EFFF);

  static List<BoxShadow> cardShadow(BuildContext context) {
    if (isDark(context)) {
      return const [
        BoxShadow(
          color: Color(0x3D000000),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
      ];
    }
    return const [
      BoxShadow(
        color: Color(0x0D000000),
        blurRadius: 1,
        offset: Offset(0, 0.5),
      ),
      BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 3)),
      BoxShadow(
        color: Color(0x12000000),
        blurRadius: 28,
        offset: Offset(0, 14),
        spreadRadius: -8,
      ),
    ];
  }
}

/// A hover-aware card used inside the content page.
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(22),
    this.radius = 26,
    this.tint,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final fill =
        widget.tint ??
        (_hovered && widget.onTap != null
            ? BroomColors.cardHover(context)
            : BroomColors.card(context));

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: BroomColors.cardShadow(context),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(widget.radius),
          hoverColor: Colors.transparent,
          splashColor: BroomColors.ink(context).withValues(alpha: 0.04),
          highlightColor: Colors.transparent,
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );

    if (widget.onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: card,
    );
  }
}

/// Neutral icon tile used inside cards and navigation.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.size = 42,
    this.radius = 13,
    this.color,
  });

  final IconData icon;
  final double size;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? BroomColors.inkMuted(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color == null
            ? BroomColors.block(context)
            : color!.withValues(
                alpha: BroomColors.isDark(context) ? 0.18 : 0.11,
              ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: size * 0.48, color: tone),
    );
  }
}

/// Page heading used on top-level surfaces.
class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BroomColors.inkMuted(context),
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 16), trailing!],
      ],
    );
  }
}

/// Compact section label with optional trailing action.
class SectionLabel extends StatelessWidget {
  const SectionLabel({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: BroomColors.inkMuted(context),
                  ),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Small card header: an icon, a quiet title and optional trailing content.
class BroomCardHeader extends StatelessWidget {
  const BroomCardHeader({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: BroomColors.inkMuted(context)),
          const SizedBox(width: 9),
        ],
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.05,
              color: BroomColors.inkMuted(context),
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// A small status capsule with an optional leading dot.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.tone,
    this.icon,
    this.dot = true,
  });

  final String label;
  final Color? tone;
  final IconData? icon;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final base = tone ?? BroomColors.inkMuted(context);
    final foreground = BroomColors.isDark(context)
        ? Color.lerp(base, Colors.white, 0.28)!
        : Color.lerp(base, Colors.black, 0.16)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: base.withValues(alpha: BroomColors.isDark(context) ? 0.2 : 0.13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 12, color: foreground)
          else if (dot)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: base, shape: BoxShape.circle),
            ),
          if (icon != null || dot) const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Large figure used in dashboard cards. Tabular digits keep metrics aligned.
class CardFigure extends StatelessWidget {
  const CardFigure(
    this.value, {
    super.key,
    this.size = 32,
    this.color,
    this.maxLines = 1,
  });

  final String value;
  final double size;
  final Color? color;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: broomFontFamily,
        fontFamilyFallback: broomFontFallback,
        fontSize: size,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: size * -0.02,
        color: color ?? BroomColors.ink(context),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
