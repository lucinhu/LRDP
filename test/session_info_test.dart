import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/l10n/app_strings.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/session_info_sheet.dart';

const _profile = ConnectionProfile(id: 'info', name: 'Info', host: '192.0.2.1');

class _BackendSession extends RdpSession {
  _BackendSession() : super(_profile);
  int backend = 0;
  @override
  int get decoderBackend => backend;
}

Widget _harness(Widget child) => MaterialApp(
  locale: AppStrings.localeFor('zh-CN'),
  supportedLocales: AppStrings.supportedLocales,
  localizationsDelegates: const [
    AppStrings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('session info lists the idle frame pipeline state', (
    tester,
  ) async {
    final session = RdpSession(_profile);
    addTearDown(session.dispose);
    await tester.pumpWidget(_harness(SessionInfoSheet(session: session)));
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('会话信息'), findsOneWidget);
    expect(find.text('连接状态'), findsOneWidget);
    // Idle state and the unknown resolution share the fallback label.
    expect(find.text('未知'), findsNWidgets(2));
    expect(find.text('CPU 图像'), findsOneWidget);
    expect(find.text('位图（GDI）'), findsOneWidget);
    expect(find.text('已关闭'), findsOneWidget);
    expect(find.text('无'), findsOneWidget);
    expect(find.text('0 帧/秒'), findsOneWidget);
  });

  testWidgets('session info reports capability bits and rate limit', (
    tester,
  ) async {
    final session = RdpSession(_profile)
      ..state = SessionState.connected
      ..features = 1 | 16 | 33
      ..setFrameRate(90);
    addTearDown(session.dispose);
    await tester.pumpWidget(_harness(SessionInfoSheet(session: session)));
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('文本, 图片, 文件'), findsOneWidget);
    expect(find.text('90 帧/秒'), findsOneWidget);
  });

  testWidgets(
    'H.264 reports the latest backend including unknown and CPU fallback',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = _BackendSession()..features = 4;
      addTearDown(session.dispose);
      await tester.pumpWidget(_harness(SessionInfoSheet(session: session)));
      expect(find.text('H.264 视频 · 解码路径未获取'), findsOneWidget);

      for (final entry in [
        (2, 'GPU (VA-API)'),
        (3, 'GPU (CUDA)'),
        (4, '硬件（MediaCodec）'),
        (1, 'CPU (FFmpeg)'),
        (99, '解码路径未获取'),
        (0, '解码路径未获取'),
      ]) {
        session.backend = entry.$1;
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('H.264 视频 · ${entry.$2}'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('measured frame rate follows decoded frames', (tester) async {
    var now = DateTime(2026, 10, 31, 12);
    final session = RdpSession(_profile);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      _harness(SessionInfoSheet(session: session, clock: () => now)),
    );

    session.decodedFrames = 30;
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('30 帧/秒'), findsOneWidget);

    session.decodedFrames = 75;
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('45 帧/秒'), findsOneWidget);
  });

  testWidgets('the more-sheet entry opens the panel', (tester) async {
    final session = RdpSession(_profile);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: AppStrings.localeFor('zh-CN'),
        supportedLocales: AppStrings.supportedLocales,
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSessionInfoSheet(context, session),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('会话信息'), findsOneWidget);
  });
}
