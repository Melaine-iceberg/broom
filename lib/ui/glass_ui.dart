import 'dart:ui';

import 'package:flutter/material.dart';

/// Shared colors and surfaces for the translucent desktop shell.
///
/// The palette is intentionally restrained: the aurora backdrop provides the
/// color, while content sits on quiet glass layers. Accent color is reserved
/// for primary actions and selection.
abstract final class BroomColors {
  static const accent = Color(0xFF7FB5FF);
  static const accentStrong = Color(0xFF2F7BFF);
  static const sky = Color(0xFF8ED5FF);
  static const violet = Color(0xFFB9A8FF);
  static const amber = Color(0xFFF0C67D);
  static const danger = Color(0xFFFF8A80);

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// Fill for the main content panel.
  static Color panel(BuildContext context) =>
      isDark(context) ? const Color(0xC80D141F) : const Color(0xD9F7F9FC);

  /// Fill for the navigation rail / sidebar.
  static Color sidebar(BuildContext context) =>
      isDark(context) ? const Color(0xB80A0F17) : const Color(0xCCFFFFFF);

  /// Default card fill inside a panel.
  static Color card(BuildContext context) =>
      isDark(context) ? const Color(0x0DFFFFFF) : const Color(0xF0FFFFFF);

  /// Card fill on hover.
  static Color cardHover(BuildContext context) =>
      isDark(context) ? const Color(0x17FFFFFF) : const Color(0xFFFFFFFF);

  static Color hairline(BuildContext context) =>
      isDark(context) ? const Color(0x17FFFFFF) : const Color(0x1A0B1220);

  static Color hairlineStrong(BuildContext context) =>
      isDark(context) ? const Color(0x26FFFFFF) : const Color(0x2A0B1220);

  static Color ink(BuildContext context) =>
      isDark(context) ? const Color(0xFFF1F5F9) : const Color(0xFF111820);

  static Color inkMuted(BuildContext context) =>
      isDark(context) ? const Color(0xFF9AA6B4) : const Color(0xFF5A6675);

  static Color inkFaint(BuildContext context) =>
      isDark(context) ? const Color(0xFF6C7885) : const Color(0xFF8A95A3);

  static Color tint(BuildContext context, Color color, [double alpha = 0.14]) =>
      Color.alphaBlend(color.withValues(alpha: alpha), Colors.transparent);
}

/// Soft aurora gradient that sits behind the entire window.
class LiquidBackdrop extends StatelessWidget {
  const LiquidBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = BroomColors.isDark(context);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? const [
                        Color(0xFF060A15),
                        Color(0xFF0A1226),
                        Color(0xFF070B14),
                      ]
                    : const [
                        Color(0xFFF2F6FA),
                        Color(0xFFE9F0F7),
                        Color(0xFFF9F5F0),
                      ],
              ),
            ),
          ),
          _Aurora(
            alignment: const Alignment(-1.05, -0.95),
            size: 720,
            color: dark ? const Color(0xFF2D6BFF) : const Color(0xFFAFCEFA),
            opacity: dark ? 0.62 : 0.62,
          ),
          _Aurora(
            alignment: const Alignment(1.15, -0.55),
            size: 780,
            color: dark ? const Color(0xFF1E8FE0) : const Color(0xFFBFE2FF),
            opacity: dark ? 0.4 : 0.5,
          ),
          _Aurora(
            alignment: const Alignment(0.9, 1.2),
            size: 660,
            color: dark ? const Color(0xFF8C4623) : const Color(0xFFF5D6BD),
            opacity: dark ? 0.26 : 0.46,
          ),
          _Aurora(
            alignment: const Alignment(-0.95, 1.1),
            size: 740,
            color: dark ? const Color(0xFF6446C7) : const Color(0xFFD8C8F5),
            opacity: dark ? 0.46 : 0.4,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const [
                        Color(0x33000000),
                        Color(0x00000000),
                        Color(0x4D000000),
                      ]
                    : const [
                        Color(0x12FFFFFF),
                        Color(0x00000000),
                        Color(0x140B1220),
                      ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Aurora extends StatelessWidget {
  const _Aurora({
    required this.alignment,
    required this.size,
    required this.color,
    required this.opacity,
  });

  final Alignment alignment;
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  color.withValues(alpha: opacity),
                  color.withValues(alpha: opacity * 0.55),
                  color.withValues(alpha: 0),
                ],
                stops: const [0, 0.52, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A soft light patch used to give glass panels depth.
class AmbientGlow extends StatelessWidget {
  const AmbientGlow({
    super.key,
    this.color = BroomColors.accentStrong,
    this.alignment = Alignment.topLeft,
    this.radius = 1.4,
    this.opacity = 0.16,
  });

  final Color color;
  final Alignment alignment;
  final double radius;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: alignment,
            radius: radius,
            colors: [
              color.withValues(
                alpha: opacity * (BroomColors.isDark(context) ? 1.0 : 0.55),
              ),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded translucent panel, optionally blurred against the backdrop.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.radius = 22,
    this.blur = 0,
    this.color,
    this.borderColor,
    this.highlight = true,
    this.shadow = true,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final double blur;
  final Color? color;
  final Color? borderColor;
  final bool highlight;
  final bool shadow;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final fill = color ?? BroomColors.panel(context);
    final border = borderColor ?? BroomColors.hairline(context);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: BroomColors.isDark(context) ? 0.32 : 0.08,
                  ),
                  blurRadius: 32,
                  offset: const Offset(0, 16),
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          if (highlight)
            Positioned(
              top: 0.5,
              left: radius * 0.6,
              right: radius * 0.6,
              height: 1,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(
                          alpha: BroomColors.isDark(context) ? 0.02 : 0.0,
                        ),
                        Colors.white.withValues(
                          alpha: BroomColors.isDark(context) ? 0.14 : 0.8,
                        ),
                        Colors.white.withValues(
                          alpha: BroomColors.isDark(context) ? 0.02 : 0.0,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ],
      ),
    );

    if (clip) {
      surface = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: surface,
      );
    }
    if (blur > 0) {
      surface = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: surface,
        ),
      );
    }
    return surface;
  }
}

/// A hover-aware translucent card used inside the content panel.
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(18),
    this.radius = 18,
    this.tint,
    this.borderColor,
    this.blur = 0,
    this.highlight = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;
  final Color? borderColor;
  final double blur;
  final bool highlight;

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
        (_hovered ? BroomColors.cardHover(context) : BroomColors.card(context));
    final border = widget.borderColor ?? BroomColors.hairline(context);

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: _hovered && widget.onTap != null
              ? BroomColors.hairlineStrong(context)
              : border,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: BroomColors.isDark(context) ? 0.1 : 0.035,
            ),
            blurRadius: _hovered ? 16 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(widget.radius),
          hoverColor: Colors.transparent,
          highlightColor: Colors.white.withValues(alpha: 0.02),
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    );

    card = Stack(
      children: [
        card,
        if (widget.highlight)
          Positioned(
            top: 0.5,
            left: widget.radius * 0.6,
            right: widget.radius * 0.6,
            height: 1,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.white.withValues(
                        alpha: BroomColors.isDark(context) ? 0.1 : 0.65,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.blur > 0) {
      card = ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: widget.blur, sigmaY: widget.blur),
          child: card,
        ),
      );
    }

    if (widget.onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: card,
    );
  }
}

/// Small status label with a colored dot.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.color = BroomColors.accent,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = BroomColors.isDark(context)
        ? Color.alphaBlend(color.withValues(alpha: 0.86), Colors.white)
        : Color.alphaBlend(color.withValues(alpha: 0.7), Colors.black);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 9,
        vertical: dense ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(
          alpha: BroomColors.isDark(context) ? 0.12 : 0.16,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 12.5, color: foreground),
            const SizedBox(width: 4),
          ] else ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: foreground,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft square icon tile used inside cards and navigation.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.size = 38,
    this.radius = 11,
    this.color,
  });

  final IconData icon;
  final double size;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tone = color ?? scheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone.withValues(
          alpha: BroomColors.isDark(context) ? 0.14 : 0.12,
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tone.withValues(alpha: 0.14)),
      ),
      child: Icon(icon, size: size * 0.5, color: tone),
    );
  }
}

/// Page heading used on the home surface.
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
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                ),
              ),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BroomColors.inkMuted(context),
                    height: 1.45,
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
    this.icon,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: BroomColors.inkFaint(context)),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
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

/// Small metadata line used under card titles.
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: BroomColors.inkFaint(context)),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: BroomColors.inkMuted(context)),
          ),
        ),
      ],
    );
  }
}

/// A compact glass app-bar title used by secondary pages.
class ToolPageTitle extends StatelessWidget {
  const ToolPageTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
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
    );
  }
}
