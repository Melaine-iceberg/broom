import 'package:broom/core/app/app_update_service.dart';
import 'package:broom/core/platform/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockMethodCallHandler(
      MethodChannelAppVersion.channel,
      null,
    ),
  );

  test('reads the runner version and trims whitespace', () async {
    messenger.setMockMethodCallHandler(MethodChannelAppVersion.channel, (
      call,
    ) async {
      expect(call.method, 'appVersion');
      return ' 0.5.0+7 ';
    });

    final raw = await const MethodChannelAppVersion().read();

    expect(raw, '0.5.0+7');
    expect(AppVersion.parse(raw!).toString(), '0.5.0.7');
  });

  test('returns null when the runner has no version channel', () async {
    expect(await const MethodChannelAppVersion().read(), isNull);
  });
}
