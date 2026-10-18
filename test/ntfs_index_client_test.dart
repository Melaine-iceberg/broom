import 'dart:async';

import 'package:broom/core/scan/ntfs_index.dart';
import 'package:broom/core/scan/ntfs_index_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();
  const channel = MethodChannel('broom/ntfs_index');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> sendNative(String method, Map<String, Object?> arguments) {
    return messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  test('parses probe statuses and caches them', () async {
    var probes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'probe') {
        probes++;
        return {'status': 'unprivileged', 'message': 'need admin'};
      }
      return null;
    });
    final client = NtfsIndexClient(channel: channel);
    final first = await client.probe(r'C:\cache');
    final second = await client.probe(r'C:\Cache');
    expect(first.status, NtfsIndexStatus.unprivileged);
    expect(first.message, 'need admin');
    expect(second.status, NtfsIndexStatus.unprivileged);
    expect(probes, 1);

    client.dispose();
  });

  test('streams batches from native calls', () async {
    final started = Completer<int>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'probe':
          return {'status': 'available'};
        case 'start':
          final arguments = call.arguments as Map<Object?, Object?>;
          started.complete(arguments['requestId']! as int);
          return null;
      }
      return null;
    });

    final client = NtfsIndexClient(channel: channel);
    final entries = <NtfsIndexEntry>[];
    final done = Completer<void>();
    client
        .enumerate(r'C:\cache')
        .listen(
          entries.add,
          onError: done.completeError,
          onDone: done.complete,
        );

    final id = await started.future;
    await sendNative('batch', {
      'requestId': id,
      'paths': [r'C:\cache\a.tmp', r'C:\cache\b.tmp'],
    });
    await sendNative('done', {'requestId': id, 'error': ''});
    await done.future;

    expect(entries.map((entry) => entry.path), [
      r'C:\cache\a.tmp',
      r'C:\cache\b.tmp',
    ]);
    client.dispose();
  });

  test('surfaces native errors as stream errors', () async {
    final started = Completer<int>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        final arguments = call.arguments as Map<Object?, Object?>;
        started.complete(arguments['requestId']! as int);
      }
      return null;
    });

    final client = NtfsIndexClient(channel: channel);
    final error = Completer<Object>();
    client.enumerate(r'C:\cache').listen((_) {}, onError: error.complete);

    final id = await started.future;
    await sendNative('done', {
      'requestId': id,
      'error': 'USN journal unavailable',
    });

    expect(
      await error.future,
      isA<NtfsIndexException>().having(
        (value) => value.message,
        'message',
        contains('USN'),
      ),
    );
    client.dispose();
  });
}
