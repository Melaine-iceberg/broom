import 'package:broom/app.dart';
import 'package:broom/ui/app_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required bool showSystemCache,
  required bool showRecycleBin,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildBroomTheme(Brightness.light),
      home: Scaffold(
        body: Row(
          children: [
            AppSidebar(
              section: AppSection.clean,
              expanded: true,
              showSystemCache: showSystemCache,
              showRecycleBin: showRecycleBin,
              onSelected: (_) {},
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('hides the system cache entry when no backend is available', (
    tester,
  ) async {
    await _pumpSidebar(tester, showSystemCache: false, showRecycleBin: false);

    expect(find.byKey(const ValueKey('sidebar-system-cache')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-recycle-bin')), findsNothing);
  });

  testWidgets('shows the Linux system cache entry without the recycle bin', (
    tester,
  ) async {
    await _pumpSidebar(tester, showSystemCache: true, showRecycleBin: false);

    expect(find.byKey(const ValueKey('sidebar-system-cache')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-recycle-bin')), findsNothing);
  });

  testWidgets('still shows the Windows recycle bin independently', (
    tester,
  ) async {
    await _pumpSidebar(tester, showSystemCache: false, showRecycleBin: true);

    expect(find.byKey(const ValueKey('sidebar-system-cache')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-recycle-bin')), findsOneWidget);
  });
}
