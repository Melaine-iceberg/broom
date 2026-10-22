import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/broom_strings.dart';
import '../platform/window_chrome.dart';
import 'glass_ui.dart';

/// Places the quiet desktop chrome above every route.
class BroomWindowFrame extends StatelessWidget {
  const BroomWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final supported = WindowChrome.instance.isSupported;
    return ColoredBox(
      color: BroomColors.page(context),
      child: supported
          ? Column(
              children: [
                const WindowTitleBar(),
                Expanded(child: child),
              ],
            )
          : child,
    );
  }
}

/// A compact, rectangular title bar. It reads as window chrome rather than as
/// another content surface.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  static const double barHeight = 38;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: barHeight,
      decoration: BoxDecoration(color: BroomColors.sidebar(context)),
      child: Row(
        children: [
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) =>
                    unawaited(WindowChrome.instance.startDragging()),
                onDoubleTap: () =>
                    unawaited(WindowChrome.instance.toggleMaximize()),
                onSecondaryTapUp: (_) =>
                    unawaited(WindowChrome.instance.showSystemMenu()),
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.asset(
                          'assets/icon/app_icon.png',
                          width: 18,
                          height: 18,
                          cacheWidth: 72,
                          filterQuality: FilterQuality.medium,
                          excludeFromSemantics: true,
                          errorBuilder: (context, error, stackTrace) {
                            return Icon(
                              LucideIcons.broom,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 9),
                      Text(
                        'Broom',
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                          color: BroomColors.ink(context),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: BroomColors.ink(context).withValues(
                            alpha: BroomColors.isDark(context) ? 0.1 : 0.06,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          context.t('本地安全清理'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: BroomColors.inkMuted(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const _WindowControls(),
        ],
      ),
    );
  }
}

class _WindowControls extends StatelessWidget {
  const _WindowControls();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: WindowChrome.instance.isMaximized,
      builder: (context, maximized, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WindowButton(
              key: const ValueKey('window-minimize'),
              glyph: _WindowGlyph.minimize,
              label: context.t('最小化'),
              onPressed: () => unawaited(WindowChrome.instance.minimize()),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: WindowChrome.instance.isMaximizeHovered,
              builder: (context, hovered, _) => _WindowButton(
                key: const ValueKey('window-maximize'),
                glyph: maximized ? _WindowGlyph.restore : _WindowGlyph.maximize,
                label: maximized ? context.t('还原') : context.t('最大化'),
                externalHover: hovered,
                onPressed: () =>
                    unawaited(WindowChrome.instance.toggleMaximize()),
              ),
            ),
            _WindowButton(
              key: const ValueKey('window-close'),
              glyph: _WindowGlyph.close,
              label: context.t('关闭'),
              isCloseButton: true,
              onPressed: () => unawaited(WindowChrome.instance.close()),
            ),
          ],
        );
      },
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onPressed,
    this.isCloseButton = false,
    this.externalHover = false,
  });

  final _WindowGlyph glyph;
  final String label;
  final VoidCallback onPressed;
  final bool isCloseButton;

  /// Hover state reported by the runner. Used for the maximize button, whose
  /// hit test is owned by the native non-client area.
  final bool externalHover;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  static const _closeHover = Color(0xFFC42B1C);
  static const _closePressed = Color(0xFFB0291B);

  bool _hovered = false;
  bool _pressed = false;

  bool get _isHovered => _hovered || widget.externalHover;

  Color _backgroundColor(BuildContext context) {
    if (widget.isCloseButton) {
      if (_pressed) return _closePressed;
      if (_isHovered) return _closeHover;
      return Colors.transparent;
    }
    if (_pressed) {
      return BroomColors.ink(context).withValues(alpha: 0.1);
    }
    if (_isHovered) {
      return BroomColors.ink(context).withValues(alpha: 0.06);
    }
    return Colors.transparent;
  }

  Color _foregroundColor(BuildContext context) {
    if (widget.isCloseButton && _isHovered) return Colors.white;
    return _isHovered ? BroomColors.ink(context) : BroomColors.inkMuted(context);
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
      if (!hovered) _pressed = false;
    });
  }

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: (_) => _setPressed(true),
          onTapCancel: () => _setPressed(false),
          onTapUp: (_) => _setPressed(false),
          onTap: widget.onPressed,
          child: Container(
            width: 44,
            height: WindowTitleBar.barHeight - 10,
            margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 5),
            decoration: BoxDecoration(
              color: _backgroundColor(context),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: CustomPaint(
              size: const Size(10, 10),
              painter: _WindowGlyphPainter(
                glyph: widget.glyph,
                color: _foregroundColor(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _WindowGlyph { minimize, maximize, restore, close }

class _WindowGlyphPainter extends CustomPainter {
  const _WindowGlyphPainter({required this.glyph, required this.color});

  final _WindowGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = true;

    canvas.save();
    canvas.translate((size.width - 10) / 2, (size.height - 10) / 2);

    switch (glyph) {
      case _WindowGlyph.minimize:
        canvas.drawLine(const Offset(1, 5.5), const Offset(9, 5.5), paint);
      case _WindowGlyph.maximize:
        canvas.drawRect(const Rect.fromLTWH(1, 1, 8, 8), paint);
      case _WindowGlyph.restore:
        canvas.drawRect(const Rect.fromLTWH(1, 3.5, 5.5, 5.5), paint);
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 1)
            ..lineTo(9, 1)
            ..lineTo(9, 6.5),
          paint,
        );
      case _WindowGlyph.close:
        canvas.drawLine(const Offset(1, 1), const Offset(9, 9), paint);
        canvas.drawLine(const Offset(9, 1), const Offset(1, 9), paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindowGlyphPainter oldDelegate) {
    return oldDelegate.glyph != glyph || oldDelegate.color != color;
  }
}
