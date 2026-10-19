import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/rdp/session_audio_focus.dart';

class AudioSession extends RdpSession {
  AudioSession(String id, {bool enabled = true})
    : super(
        ConnectionProfile(id: id, name: id, host: '192.0.2.1', audio: enabled),
      ) {
    state = SessionState.connected;
  }
  final permissions = <bool>[];
  bool get allowed => permissions.isNotEmpty && permissions.last;
  @override
  void setAudioAllowed(bool allowed) {
    permissions.add(allowed);
    super.setAudioAllowed(allowed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.lrdp/audio_focus');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Future<bool> Function(int token)? request;
  Future<void> changed(int token, bool granted) async {
    final done = Completer<void>();
    ui.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('changed', {'token': token, 'granted': granted}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() {
    calls.clear();
    request = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'request') {
        return request == null
            ? true
            : request!((call.arguments as Map)['token'] as int);
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'only the selected active session may play; background and termination revoke it',
    () async {
      final first = AudioSession('a'), second = AudioSession('b');
      final focus = SessionAudioFocus(android: false);
      focus.select(first);
      expect(first.allowed, isTrue);
      focus.select(second);
      expect(first.allowed, isFalse);
      expect(second.allowed, isTrue);
      focus.select(second, foreground: false);
      expect(second.allowed, isFalse);
      focus.select(second);
      expect(second.allowed, isTrue);
      second.state = SessionState.closed;
      focus.select(second);
      expect(second.allowed, isFalse);
      focus.dispose();
      first.dispose();
      second.dispose();
    },
  );

  test('denied Android focus and disabled profiles remain silent', () async {
    request = (_) async => false;
    final session = AudioSession('a'),
        disabled = AudioSession('off', enabled: false);
    final focus = SessionAudioFocus(android: true, channel: channel);
    focus.select(disabled);
    await focus.settled;
    expect(calls, isEmpty);
    focus.select(session);
    await focus.settled;
    expect(session.allowed, isFalse);
    expect(calls.where((c) => c.method == 'request'), hasLength(1));
    focus.dispose();
    await focus.settled;
    session.dispose();
    disabled.dispose();
  });

  test(
    'loss/gain applies to current request and old events cannot unmute background',
    () async {
      final session = AudioSession('a');
      final focus = SessionAudioFocus(android: true, channel: channel);
      focus.select(session);
      await focus.settled;
      final firstToken = (calls.last.arguments as Map)['token'] as int;
      expect(session.allowed, isTrue);
      await changed(firstToken, false);
      expect(session.allowed, isFalse);
      await changed(firstToken, true);
      expect(session.allowed, isTrue);
      focus.select(session, foreground: false);
      await focus.settled;
      await changed(firstToken, true);
      expect(session.allowed, isFalse);
      focus.select(session);
      await focus.settled;
      final newToken = (calls.last.arguments as Map)['token'] as int;
      expect(newToken, isNot(firstToken));
      await changed(firstToken, false);
      expect(session.allowed, isTrue);
      await changed(newToken, false);
      expect(session.allowed, isFalse);
      focus.dispose();
      await focus.settled;
      session.dispose();
    },
  );

  test('a late native grant cannot unmute a replaced session', () async {
    final pending = Completer<bool>(), entered = Completer<void>();
    var requests = 0;
    request = (_) {
      if (++requests == 1) {
        entered.complete();
        return pending.future;
      }
      return Future.value(true);
    };
    final first = AudioSession('a'), second = AudioSession('b');
    final focus = SessionAudioFocus(android: true, channel: channel);
    focus.select(first);
    await entered.future;
    focus.select(second);
    expect(first.allowed, isFalse);
    expect(second.allowed, isFalse);
    pending.complete(true);
    await focus.settled;
    expect(first.allowed, isFalse);
    expect(second.allowed, isTrue);
    expect(
      calls.where(
        (c) => c.method == 'release' && (c.arguments as Map)['token'] != null,
      ),
      hasLength(1),
    );
    focus.dispose();
    await focus.settled;
    first.dispose();
    second.dispose();
  });

  test(
    'replacing a coordinator revokes old audio without losing new focus callbacks',
    () async {
      final pending = Completer<bool>(), entered = Completer<void>();
      var requests = 0;
      request = (_) {
        if (++requests == 1) {
          entered.complete();
          return pending.future;
        }
        return Future.value(true);
      };
      final first = AudioSession('a'), second = AudioSession('b');
      final old = SessionAudioFocus(android: true, channel: channel);
      old.select(first);
      await entered.future;
      final oldToken = (calls.last.arguments as Map)['token'] as int;
      final current = SessionAudioFocus(android: true, channel: channel);
      expect(first.allowed, isFalse);
      current.select(second);
      await current.settled;
      final currentToken = (calls.last.arguments as Map)['token'] as int;
      expect(currentToken, isNot(oldToken));
      expect(second.allowed, isTrue);
      old.dispose();
      pending.complete(true);
      await old.settled;
      expect(first.allowed, isFalse);
      expect(second.allowed, isTrue);
      expect(
        calls
            .where((call) => call.method == 'release')
            .map((call) => (call.arguments as Map)['token']),
        everyElement(oldToken),
      );
      await changed(oldToken, false);
      expect(second.allowed, isTrue);
      await changed(currentToken, false);
      expect(second.allowed, isFalse);
      await changed(currentToken, true);
      expect(second.allowed, isTrue);
      current.dispose();
      await current.settled;
      first.dispose();
      second.dispose();
    },
  );

  test(
    'dispose during request and a missing platform handler never grant playback',
    () async {
      final pending = Completer<bool>(), entered = Completer<void>();
      request = (_) {
        entered.complete();
        return pending.future;
      };
      final session = AudioSession('a');
      final focus = SessionAudioFocus(android: true, channel: channel);
      focus.select(session);
      await entered.future;
      focus.dispose();
      pending.complete(true);
      await focus.settled;
      expect(session.allowed, isFalse);
      messenger.setMockMethodCallHandler(channel, null);
      final missing = SessionAudioFocus(android: true, channel: channel);
      missing.select(session);
      await missing.settled;
      expect(session.allowed, isFalse);
      missing.dispose();
      await missing.settled;
      session.dispose();
    },
  );
}
