import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/window_chrome.dart';

/// Places the custom title bar above every route of the Windows app.
class BroomWindowFrame extends StatelessWidget {
  const BroomWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!WindowChrome.instance.isSupported) {
      return child;
    }

    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        children: [
          const WindowTitleBar(),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A draggable title bar that replaces the native Windows caption.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  static const double barHeight = 46;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: barHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
        ),
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
                    padding: const EdgeInsets.only(left: 16, right: 12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final showTagline = constraints.maxWidth >= 360;
                        return Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.asset(
                                'assets/icon/app_icon.png',
                                width: 22,
                                height: 22,
                                cacheWidth: 96,
                                filterQuality: FilterQuality.medium,
                                excludeFromSemantics: true,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(
                                    Icons.cleaning_services_rounded,
                                    size: 18,
                                    color: scheme.primary,
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Broom',
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                                color: scheme.onSurface,
                              ),
                            ),
                            if (showTagline) ...[
                              const SizedBox(width: 10),
                              Container(
                                width: 1,
                                height: 12,
                                color: scheme.outlineVariant.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Windows 安全清理',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const _WindowControls(),
          ],
        ),
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
              label: '最小化',
              onPressed: () => unawaited(WindowChrome.instance.minimize()),
            ),
            _WindowButton(
              key: const ValueKey('window-maximize'),
              glyph: maximized ? _WindowGlyph.restore : _WindowGlyph.maximize,
              label: maximized ? '还原' : '最大化',
              onPressed: () =>
                  unawaited(WindowChrome.instance.toggleMaximize()),
            ),
            _WindowButton(
              key: const ValueKey('window-close'),
              glyph: _WindowGlyph.close,
              label: '关闭',
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
  });

  final _WindowGlyph glyph;
  final String label;
  final VoidCallback onPressed;
  final bool isCloseButton;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  static const _closeHover = Color(0xFFC42B1C);
  static const _closePressed = Color(0xFFB0291B);

  bool _hovered = false;
  bool _pressed = false;

  Color _backgroundColor(ColorScheme scheme) {
    if (widget.isCloseButton) {
      if (_pressed) return _closePressed;
      if (_hovered) return _closeHover;
      return Colors.transparent;
    }
    if (_pressed) return scheme.onSurface.withValues(alpha: 0.12);
    if (_hovered) return scheme.onSurface.withValues(alpha: 0.07);
    return Colors.transparent;
  }

  Color _foregroundColor(ColorScheme scheme) {
    if (widget.isCloseButton && _hovered) {
      return Colors.white;
    }
    return _hovered ? scheme.onSurface : scheme.onSurfaceVariant;
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
    final scheme = Theme.of(context).colorScheme;

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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            width: WindowTitleBar.barHeight,
            height: WindowTitleBar.barHeight,
            color: _backgroundColor(scheme),
            alignment: Alignment.center,
            child: CustomPaint(
              size: const Size(12, 12),
              painter: _WindowGlyphPainter(
                glyph: widget.glyph,
                color: _foregroundColor(scheme),
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
    canvas.translate((size.width - 12) / 2, (size.height - 12) / 2);

    switch (glyph) {
      case _WindowGlyph.minimize:
        canvas.drawLine(const Offset(1.5, 6.5), const Offset(10.5, 6.5), paint);
      case _WindowGlyph.maximize:
        canvas.drawRect(const Rect.fromLTWH(1.5, 1.5, 9, 9), paint);
      case _WindowGlyph.restore:
        canvas.drawRect(const Rect.fromLTWH(1.5, 4.5, 6, 6), paint);
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 1.5)
            ..lineTo(10.5, 1.5)
            ..lineTo(10.5, 7.5),
          paint,
        );
      case _WindowGlyph.close:
        canvas.drawLine(
          const Offset(1.5, 1.5),
          const Offset(10.5, 10.5),
          paint,
        );
        canvas.drawLine(
          const Offset(10.5, 1.5),
          const Offset(1.5, 10.5),
          paint,
        );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindowGlyphPainter oldDelegate) {
    return oldDelegate.glyph != glyph || oldDelegate.color != color;
  }
}
