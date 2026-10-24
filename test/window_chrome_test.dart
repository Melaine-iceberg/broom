import 'package:broom/platform/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the custom title bar is enabled on both desktop platforms', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(WindowChrome.instance.isSupported, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(WindowChrome.instance.isSupported, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(WindowChrome.instance.isSupported, isFalse);
  });
}
