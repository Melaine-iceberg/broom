import 'dart:ui';

import 'package:broom/app.dart';
import 'package:broom/core/safety/path_guard.dart';
import 'package:broom/core/settings/exclusion_store.dart';
import 'package:broom/ui/clean_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/support/quarantine_fakes.dart';
import 'support/integration_fakes.dart';

/// Measures real frame timings while scrolling a preview with thousands of
/// results. Run on a Windows desktop device:
///
///   flutter test integration_test/ui_frame_benchmark_test.dart -d windows
///
/// The printed p50/p95 build and raster durations are the source for the
/// numbers in benchmark/README.md. A generous sanity threshold keeps the test
/// useful on slow CI machines without turning it into a hardware benchmark.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reports preview scroll frame timings', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final items = buildIntegrationItems(5000);
    final controller = CleanController(
      platform: IntegrationPlatform(),
      guard: PathGuard(protectedRoots: const []),
      quarantine: FakeQuarantineService(),
      exclusions: ExclusionStore(
        filePath: p.join(r'C:\Integration', 'frame-exclusions.json'),
      ),
      scanServiceFactory: () => IntegrationScanService(items: items),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.scan();
    expect(controller.results.single.items, hasLength(5000));

    await tester.pumpWidget(
      BroomApp(controller: controller, systemShell: IntegrationShell()),
    );
    await tester.pumpAndSettle();

    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> values) => timings.addAll(values);
    binding.addTimingsCallback(collect);

    final scrollable = find.byType(Scrollable).first;
    for (var frame = 0; frame < 40; frame++) {
      await tester.drag(scrollable, const Offset(0, -180));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 250));
    binding.removeTimingsCallback(collect);

    final measured = timings
        .where((timing) => timing.totalSpan.inMicroseconds > 0)
        .toList();
    final build =
        measured
            .map((timing) => timing.buildDuration.inMicroseconds / 1000)
            .toList()
          ..sort();
    final raster =
        measured
            .map((timing) => timing.rasterDuration.inMicroseconds / 1000)
            .toList()
          ..sort();
    final total =
        measured
            .map((timing) => timing.totalSpan.inMicroseconds / 1000)
            .toList()
          ..sort();

    double percentile(List<double> values, double p) {
      if (values.isEmpty) return 0;
      final index = ((values.length - 1) * p).round();
      return values[index];
    }

    // ignore: avoid_print
    print(
      'UI_FRAMES count=${measured.length} '
      'build_p50=${percentile(build, 0.5).toStringAsFixed(2)}ms '
      'build_p95=${percentile(build, 0.95).toStringAsFixed(2)}ms '
      'raster_p50=${percentile(raster, 0.5).toStringAsFixed(2)}ms '
      'raster_p95=${percentile(raster, 0.95).toStringAsFixed(2)}ms '
      'total_p50=${percentile(total, 0.5).toStringAsFixed(2)}ms '
      'total_p95=${percentile(total, 0.95).toStringAsFixed(2)}ms',
    );

    expect(
      measured,
      isNotEmpty,
      reason: 'The device did not report any frame timings.',
    );
    expect(
      percentile(total, 0.95),
      lessThan(250),
      reason: 'Preview scrolling should stay responsive on desktop.',
    );
  });
}
