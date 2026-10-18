import 'package:broom/core/platform/file_lock_probe.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedProbe implements FileLockProbe {
  _ScriptedProbe(this.locked, {this.error});

  final Set<String> locked;
  final Object? error;
  final List<List<String>> calls = [];

  @override
  Future<List<bool>> probePossiblyLocked(List<String> paths) async {
    calls.add(List.of(paths));
    if (error != null) throw error!;
    return [for (final path in paths) locked.contains(path)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('noop probe never reports locked files', () async {
    expect(await const NoopFileLockProbe().probePossiblyLocked(['a', 'b']), [
      false,
      false,
    ]);
  });

  test('method channel sends paths and parses aligned results', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        MethodChannelFileLockProbe.channel,
        null,
      ),
    );
    messenger.setMockMethodCallHandler(MethodChannelFileLockProbe.channel, (
      call,
    ) async {
      expect(call.method, 'probe');
      final arguments = call.arguments as Map;
      final paths = (arguments['paths'] as List).cast<String>();
      return [for (final path in paths) path.endsWith('locked')];
    });

    final results = await const MethodChannelFileLockProbe()
        .probePossiblyLocked([r'C:\a\locked', r'C:\a\free']);

    expect(results, [true, false]);
  });

  test('method channel rejects incomplete plugin results', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        MethodChannelFileLockProbe.channel,
        null,
      ),
    );
    messenger.setMockMethodCallHandler(
      MethodChannelFileLockProbe.channel,
      (call) async => const <bool>[],
    );

    await expectLater(
      const MethodChannelFileLockProbe().probePossiblyLocked(['a']),
      throwsA(isA<FileLockProbeException>()),
    );
  });

  test('runner batches and reports only locked paths', () async {
    final probe = _ScriptedProbe({'b', 'c'});
    final batches = <String>[];

    final checked = await runLockProbe(
      probe: probe,
      paths: ['a', 'b', 'c', 'd', 'e'],
      batchSize: 2,
      isActive: () => true,
      onBatch: (locked, count) async =>
          batches.add('$count:${locked.join(',')}'),
    );

    expect(checked, 5);
    expect(probe.calls.map((call) => call.length), [2, 2, 1]);
    expect(batches, ['2:b', '4:c', '5:']);
  });

  test('runner stops silently when the probe fails', () async {
    final probe = _ScriptedProbe(const {}, error: StateError('no plugin'));

    final checked = await runLockProbe(
      probe: probe,
      paths: ['a', 'b'],
      isActive: () => true,
      onBatch: (_, _) async => fail('should not report a batch'),
    );

    expect(checked, 0);
  });

  test('runner stops when the caller becomes inactive', () async {
    final probe = _ScriptedProbe(const {});
    var active = false;

    final checked = await runLockProbe(
      probe: probe,
      paths: ['a', 'b', 'c'],
      batchSize: 1,
      isActive: () => active,
      onBatch: (_, _) async => fail('should not report a batch'),
    );

    expect(checked, 0);
    expect(probe.calls, isEmpty);
  });
}
