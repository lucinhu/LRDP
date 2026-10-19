import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/certificate_dialog.dart';
import 'package:lrdp/ui/theme.dart';

void main() {
  final pin = List.filled(32, 'ab').join(':');
  for (final (physicalSize, inset) in [
    (const Size(720, 1600), 520.0),
    (const Size(1600, 720), 260.0),
  ]) {
    testWidgets('certificate actions remain reachable at $physicalSize', (
      tester,
    ) async {
      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = 1.75;
      tester.view.padding = const FakeViewPadding(top: 42, bottom: 42);
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      addTearDown(tester.view.reset);
      CertificateAcceptance? accepted;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.android),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  accepted = await showDialog<CertificateAcceptance>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => CertificateDialog(
                      address: '127.0.0.1:3389',
                      fingerprint: pin,
                      previousFingerprint: pin.replaceAll('ab', 'cd'),
                    ),
                  );
                },
                child: const Text('证书'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('证书'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final confirm = find.widgetWithText(FilledButton, '指纹匹配，继续');
      expect(confirm.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(confirm).bottom,
        lessThanOrEqualTo((physicalSize.height - inset) / 1.75),
      );
      // Both fingerprints stay available by scrolling, including while the
      // login keyboard is still occupying the bottom of the display.
      await tester.ensureVisible(find.text('原指纹'));
      await tester.pumpAndSettle();
      expect(find.text('原指纹').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      // Exercise the intermediate fractional insets of the real IME animation.
      for (final bottom in [inset / 2, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: bottom);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(accepted, (remember: true));
    });
  }
}
