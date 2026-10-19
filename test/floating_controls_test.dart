import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/floating_controls.dart';
import 'package:lrdp/ui/remote_view_memory.dart';

void main() {
  testWidgets(
    'tools stay reachable after drag, collapse, rotation and large text',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var remoteClicks = 0;
      final memory = RemoteViewMemory();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTap: () => remoteClicks++,
                    child: const ColoredBox(color: Colors.black),
                  ),
                  FloatingControls(
                    memory: memory,
                    title: 'Connection',
                    actions: [
                      for (var i = 0; i < 8; i++)
                        TextButton(onPressed: () {}, child: Text('Action $i')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.text('Connection'), const Offset(-900, 1000));
      await tester.pumpAndSettle();
      final collapse = find.byKey(const Key('collapseSessionControls'));
      expect(collapse.hitTestable(), findsOneWidget);
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      final expand = find.byKey(const Key('expandSessionControls'));
      expect(expand.hitTestable(), findsOneWidget);
      expect(remoteClicks, 0);
      tester.view.physicalSize = const Size(800, 320);
      await tester.pumpAndSettle();
      expect(tester.getRect(expand).bottom, lessThanOrEqualTo(320));
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(collapse.hitTestable(), findsOneWidget);
      expect(tester.getRect(collapse).top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(780, 300));
      expect(remoteClicks, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
