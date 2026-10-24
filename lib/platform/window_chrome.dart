import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the native window chrome used by the desktop runners.
///
/// Windows and Linux both draw the title bar in Flutter, so the runner only
/// provides dragging, maximize state and the caption commands.
class WindowChrome {
  WindowChrome._();

  static final WindowChrome instance = WindowChrome._();

  static const MethodChannel _channel = MethodChannel('broom/window');
  static const EventChannel _stateChannel = EventChannel('broom/window_state');

  final ValueNotifier<bool> isMaximized = ValueNotifier<bool>(false);

  /// Hover state reported by the runner for the custom maximize button, which
  /// is hit-tested as a native caption button and therefore no longer receives
  /// Flutter mouse events.
  final ValueNotifier<bool> isMaximizeHovered = ValueNotifier<bool>(false);

  // The singleton lives for the whole application, so the subscription is
  // intentionally kept for the process lifetime.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _stateSubscription;

  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// Subscribes to native maximize/restore changes.
  ///
  /// Call after the first frame so the native runner has registered its
  /// channel handlers.
  void initialize() {
    if (!isSupported || _stateSubscription != null) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'maximizeHover' && call.arguments is bool) {
        isMaximizeHovered.value = call.arguments as bool;
      }
    });
    _stateSubscription = _stateChannel.receiveBroadcastStream().listen((event) {
      if (event is bool) {
        isMaximized.value = event;
      }
    }, onError: (Object _) {});
  }

  Future<void> startDragging() => _invoke('startDrag');

  Future<void> minimize() => _invoke('minimize');

  Future<void> toggleMaximize() => _invoke('toggleMaximize');

  Future<void> close() => _invoke('close');

  Future<void> showSystemMenu() => _invoke('showSystemMenu');

  Future<void> _invoke(String method) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Older runners and unit tests do not implement the window commands.
    } on PlatformException {
      // Window chrome is cosmetic; a failed command must not break cleaning.
    }
  }
}
