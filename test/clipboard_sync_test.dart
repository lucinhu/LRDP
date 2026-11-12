import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/clipboard_picture.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/image_clipboard.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view.dart';

import 'remote_view_test.dart' show ClipboardRecordingSession;

class _PictureRecordingSession extends ClipboardRecordingSession {
  _PictureRecordingSession() {
    features |= 16;
  }

  final picturePasted = Completer<ClipboardPicture>();

  @override
  Future<bool> pastePicture(ClipboardPicture picture) async {
    picturePasted.complete(picture);
    return true;
  }
}

class _ClipboardHost {
  _ClipboardHost(this.tester, {this.createSession});

  final WidgetTester tester;
  final ClipboardRecordingSession Function()? createSession;
  final sessions = <ClipboardRecordingSession>[];
  late ClipboardRecordingSession session;
  var platform = TargetPlatform.linux;
  var localText = 'local clipboard';
  final reads = <String>[];
  final writes = <String>[];
  Completer<Map<String, dynamic>?>? pendingRead;
  static final firstConnection = DateTime.utc(2026, 1, 1);

  ClipboardRecordingSession newSession() {
    final next = (createSession?.call() ?? ClipboardRecordingSession())
      ..connectedAt = firstConnection;
    sessions.add(next);
    return session = next;
  }

  Future<void> start({TargetPlatform platform = TargetPlatform.linux}) async {
    this.platform = platform;
    newSession();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    resume();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          reads.add(call.arguments as String);
          return pendingRead?.future ?? Future.value({'text': localText});
        }
        if (call.method == 'Clipboard.setData') {
          localText = (call.arguments as Map)['text'] as String;
          writes.add(localText);
        }
        return null;
      },
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      resume();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      for (final target in sessions) {
        target.dispose();
      }
      tester.view.reset();
    });
    await mount();
    await focus();
  }

  void resume() {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  }

  Future<void> mount({bool active = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: RemoteView(
            session: session,
            active: active,
            reconnect: () {},
            disconnect: () {},
            toggleFullscreen: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> focus() async {
    tester
        .widget<RemoteSurface>(find.byType(RemoteSurface))
        .focus
        .requestFocus();
    await tester.pump();
  }

  Future<void> poll() async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  Future<void> syncManually() async {
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('同步剪贴板'));
    await tester.tap(find.text('同步剪贴板'));
    await tester.pumpAndSettle();
  }

  Future<void> finishRead(String text) async {
    final pending = pendingRead!;
    pendingRead = null;
    pending.complete({'text': text});
    await tester.pump();
  }
}

void main() {
  testWidgets('automatic polling deduplicates text within one connection', (
    tester,
  ) async {
    final host = _ClipboardHost(tester);
    await host.start();
    await host.poll();
    await host.poll();
    expect(host.reads, ['text/plain', 'text/plain']);
    expect(host.session.announced, ['local clipboard']);

    host.localText = 'changed clipboard';
    await host.poll();
    expect(host.session.announced, ['local clipboard', 'changed clipboard']);
  });

  testWidgets('same text is announced again after reconnecting one session', (
    tester,
  ) async {
    final host = _ClipboardHost(tester);
    await host.start();
    await host.poll();
    host.session.connectedAt = _ClipboardHost.firstConnection.add(
      const Duration(seconds: 1),
    );
    await host.poll();
    await host.poll();
    expect(host.session.announced, ['local clipboard', 'local clipboard']);
  });

  testWidgets(
    'clipboard cache belongs to the session even with equal timestamps',
    (tester) async {
      final host = _ClipboardHost(tester);
      await host.start();
      await host.poll();
      final previous = host.session;
      host.newSession();
      await host.mount();
      await host.focus();
      await host.poll();
      expect(previous.announced, ['local clipboard']);
      expect(host.session.announced, ['local clipboard']);
    },
  );

  testWidgets('phone sync is explicit and can resend unchanged text', (
    tester,
  ) async {
    final host = _ClipboardHost(tester);
    await host.start(platform: TargetPlatform.android);
    await host.poll();
    expect(host.reads, isEmpty);
    await host.syncManually();
    await host.syncManually();
    expect(host.session.announced, ['local clipboard', 'local clipboard']);
  });

  testWidgets(
    'desktop automatic reads require remote focus; manual sync does not',
    (tester) async {
      final host = _ClipboardHost(tester);
      await host.start();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await host.poll();
      expect(host.reads, isEmpty);
      await host.syncManually();
      expect(host.session.announced, ['local clipboard']);
    },
  );

  testWidgets(
    'first explicit text paste keeps its automatic polling snapshot',
    (tester) async {
      final host = _ClipboardHost(tester);
      await host.start();
      expect(host.reads, isEmpty);
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('粘贴本机文字'));
      await tester.tap(find.text('粘贴本机文字'));
      await tester.pumpAndSettle();
      expect(host.session.pasted, ['local clipboard']);
      await host.focus();
      await host.poll();
      await host.poll();
      expect(host.session.announced, isEmpty);
    },
  );

  testWidgets('first explicit image paste is not overwritten by a text poll', (
    tester,
  ) async {
    final target = _PictureRecordingSession();
    final host = _ClipboardHost(tester, createSession: () => target);
    await host.start();
    expect(host.reads, isEmpty);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ImageClipboard.channel,
      (call) async {
        expect(call.method, 'read');
        return {
          'kind': 3,
          'bytes': Uint8List.fromList([255, 0, 0, 255]),
          'width': 1,
          'height': 1,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ImageClipboard.channel,
        null,
      ),
    );
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('粘贴本机图片'));
    await tester.tap(find.text('粘贴本机图片'));
    await tester.pumpAndSettle();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!target.picturePasted.isCompleted &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(target.picturePasted.isCompleted, isTrue);
    expect((await target.picturePasted.future).rgba, [255, 0, 0, 255]);
    expect(host.reads, ['text/plain']);
    await host.focus();
    await host.poll();
    await host.poll();
    expect(target.announced, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final change in [
    'reconnect',
    'replace',
    'disconnect',
    'inactive',
    'background',
  ]) {
    testWidgets('pending clipboard read is discarded after $change', (
      tester,
    ) async {
      final host = _ClipboardHost(tester);
      await host.start();
      final previous = host.session;
      host.pendingRead = Completer<Map<String, dynamic>?>();
      await host.poll();
      expect(host.reads, ['text/plain']);

      switch (change) {
        case 'reconnect':
          host.session.connectedAt = _ClipboardHost.firstConnection.add(
            const Duration(seconds: 1),
          );
        case 'replace':
          host.newSession();
          await host.mount();
        case 'disconnect':
          host.session.state = SessionState.closed;
        case 'inactive':
          await host.mount(active: false);
        case 'background':
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pump();
      }
      // A discarded read must not cache the text for the next valid poll.
      await host.finishRead(host.localText);
      expect(previous.announced, isEmpty);
      expect(host.session.announced, isEmpty);

      host.session.state = SessionState.connected;
      host.resume();
      await host.mount();
      await host.focus();
      await host.poll();
      expect(host.session.announced, ['local clipboard']);
    });
  }

  testWidgets(
    'remote text takes priority and is not echoed by automatic polling',
    (tester) async {
      final host = _ClipboardHost(tester);
      await host.start();
      host.session.remoteClipboard = 'remote text';
      await host.poll();
      expect(host.writes, ['remote text']);
      expect(host.reads, isEmpty);
      expect(host.session.remoteClipboard, isNull);
      await host.poll();
      expect(host.reads, ['text/plain']);
      expect(host.session.announced, isEmpty);
    },
  );

  testWidgets(
    'remote text arriving during a local read wins on the next poll',
    (tester) async {
      final host = _ClipboardHost(tester);
      await host.start();
      host.pendingRead = Completer<Map<String, dynamic>?>();
      await host.poll();
      host.session.remoteClipboard = 'new remote text';
      await host.finishRead('older local text');
      expect(host.session.announced, isEmpty);
      expect(host.session.remoteClipboard, 'new remote text');
      await host.poll();
      expect(host.writes, ['new remote text']);
      await host.poll();
      expect(host.session.announced, isEmpty);
    },
  );
}
