import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/ui/login_dialog.dart';
import 'package:lrdp/ui/theme.dart';

void main() {
  for (final scale in [1.4, 2.0]) {
    testWidgets('login actions survive phone IME and text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 1.75;
      tester.view.viewInsets = const FakeViewPadding(bottom: 660);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: LoginDialog(
              profile: ConnectionProfile(
                id: 'login',
                name: '远程工作电脑',
                host: '192.0.2.1',
                username: 'tester',
              ),
              issue: '用户名、域或密码未通过验证，请检查登录信息。',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(const Key('submitLogin'));
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      expect(
        tester.getRect(action).bottom,
        lessThanOrEqualTo((1600 - 660) / 1.75),
      );
      await tester.ensureVisible(find.byKey(const Key('loginPassword')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('loginPassword')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.obscureText, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('login rejects NUL and never trims a password', (tester) async {
    LoginDetails? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<LoginDetails>(
                  context: context,
                  builder: (_) => const LoginDialog(
                    profile: ConnectionProfile(
                      id: 'login',
                      name: 'Test',
                      host: '192.0.2.1',
                      username: 'tester',
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('loginPassword')),
      'bad\u0000value',
    );
    await tester.tap(find.byKey(const Key('submitLogin')));
    await tester.pumpAndSettle();
    expect(find.text('登录信息包含无效字符'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(
      find.byKey(const Key('loginPassword')),
      '  significant spaces  ',
    );
    await tester.enterText(find.byKey(const Key('loginDomain')), '  LAB  ');
    await tester.tap(find.byKey(const Key('submitLogin')));
    await tester.pumpAndSettle();
    expect(result!.password.startsWith('  '), isTrue);
    expect(result!.password.endsWith('  '), isTrue);
    expect(result!.domain, 'LAB');
    await tester.pumpWidget(const SizedBox());
  });
}
