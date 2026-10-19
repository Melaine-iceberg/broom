import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/broom_strings.dart';
import '../platform/window_chrome.dart';
import 'glass_ui.dart';

/// Places the aurora backdrop and the custom title bar above every route.
class BroomWindowFrame extends StatelessWidget {
  const BroomWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final supported = WindowChrome.instance.isSupported;
    return Stack(
      fit: StackFit.expand,
      children: [
        const LiquidBackdrop(),
        if (!supported)
          child
        else
          Column(
            children: [
              const WindowTitleBar(),
              Expanded(child: child),
            ],
          ),
      ],
    );
  }
}

/// A draggable title bar matching the translucent desktop shell.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  static const double barHeight = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: barHeight,
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
                  padding: const EdgeInsets.only(left: 18, right: 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final showTagline = constraints.maxWidth >= 340;
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
                          const SizedBox(width: 9),
                          Text(
                            'Broom',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              color: BroomColors.ink(context),
                            ),
                          ),
                          if (showTagline) ...[
                            const SizedBox(width: 10),
                            Container(
                              width: 1,
                              height: 11,
                              color: BroomColors.hairlineStrong(context),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              context.t('本地安全清理'),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: BroomColors.inkFaint(context),
                                letterSpacing: 0.1,
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
          const SizedBox(width: 6),
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
            _WindowButton(
              key: const ValueKey('window-maximize'),
              glyph: maximized ? _WindowGlyph.restore : _WindowGlyph.maximize,
              label: maximized ? context.t('还原') : context.t('最大化'),
              onPressed: () =>
                  unawaited(WindowChrome.instance.toggleMaximize()),
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

  Color _backgroundColor(BuildContext context) {
    if (widget.isCloseButton) {
      if (_pressed) return _closePressed;
      if (_hovered) return _closeHover;
      return Colors.transparent;
    }
    if (_pressed) {
      return BroomColors.isDark(context)
          ? const Color(0x1FFFFFFF)
          : const Color(0x14000000);
    }
    if (_hovered) {
      return BroomColors.isDark(context)
          ? const Color(0x12FFFFFF)
          : const Color(0x0D000000);
    }
    return Colors.transparent;
  }

  Color _foregroundColor(BuildContext context) {
    if (widget.isCloseButton && _hovered) return Colors.white;
    return _hovered ? BroomColors.ink(context) : BroomColors.inkMuted(context);
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              width: 40,
              height: 30,
              decoration: BoxDecoration(
                color: _backgroundColor(context),
                borderRadius: BorderRadius.circular(7),
              ),
              alignment: Alignment.center,
              child: CustomPaint(
                size: const Size(12, 12),
                painter: _WindowGlyphPainter(
                  glyph: widget.glyph,
                  color: _foregroundColor(context),
                ),
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
