import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to the native window chrome used by the Windows runner.
class WindowChrome {
  WindowChrome._();

  static final WindowChrome instance = WindowChrome._();

  static const MethodChannel _channel = MethodChannel('broom/window');
  static const EventChannel _stateChannel = EventChannel('broom/window_state');

  final ValueNotifier<bool> isMaximized = ValueNotifier<bool>(false);

  StreamSubscription<dynamic>? _stateSubscription;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Subscribes to native maximize/restore changes.
  ///
  /// Call after the first frame so the native runner has registered its
  /// channel handlers.
  void initialize() {
    if (!isSupported || _stateSubscription != null) return;
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
      // Only the Windows runner implements the window commands.
    } on PlatformException {
      // Window chrome is cosmetic; a failed command must not break cleaning.
    }
  }
}
