import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/rdp/session_recovery.dart';

class FakeSession extends RdpSession {
  FakeSession({bool enabled = true})
    : super(
        ConnectionProfile(
          id: 'recovery',
          name: '恢复',
          host: '192.0.2.1',
          autoReconnect: enabled,
        ),
      );
  void emit(
    SessionState value, [
    SessionEndReason reason = SessionEndReason.none,
  ]) {
    state = value;
    endReason = reason;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'background time preserves delay and retry budget; resume continues once',
    (tester) async {
      final session = FakeSession();
      var calls = 0;
      final recovery = SessionRecovery(
        session,
        reconnect: () async {
          calls++;
          session.emit(SessionState.connecting);
          session.emit(SessionState.connected);
        },
      );
      addTearDown(session.dispose);
      addTearDown(recovery.dispose);
      session.emit(SessionState.connected);
      recovery.setForeground(false);
      session.emit(SessionState.failed, SessionEndReason.transport);
      expect(recovery.suspended, isTrue);
      expect(recovery.remainingSeconds, 1);
      await tester.pump(const Duration(minutes: 2));
      expect(calls, 0);
      expect(recovery.attempts, 0);
      recovery.setForeground(true);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
      session.emit(SessionState.failed, SessionEndReason.transport);
      await tester.pump(const Duration(seconds: 1));
      expect(recovery.remainingSeconds, 1);
      recovery.setForeground(false);
      await tester.pump(const Duration(minutes: 2));
      expect(recovery.remainingSeconds, 1);
      expect(recovery.attempts, 1);
      recovery.setForeground(true);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      recovery.setForeground(false);
      await tester.pump(const Duration(minutes: 2));
      expect(recovery.attempts, 2);
      recovery.setForeground(true);
      await tester.pump(const Duration(seconds: 29));
      expect(recovery.attempts, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(recovery.attempts, 0);
      recovery.setForeground(false);
      session.emit(SessionState.failed, SessionEndReason.transport);
      recovery.cancel();
      recovery.setForeground(true);
      await tester.pump(const Duration(minutes: 2));
      expect(calls, 2);
    },
  );

  testWidgets(
    'bounded exponential retry budget survives repeated short connections',
    (tester) async {
      final session = FakeSession();
      var calls = 0;
      final recovery = SessionRecovery(
        session,
        reconnect: () async {
          calls++;
          session.emit(SessionState.connecting);
          session.emit(SessionState.connected);
          session.emit(SessionState.failed, SessionEndReason.transport);
        },
      );
      addTearDown(session.dispose);
      addTearDown(recovery.dispose);
      session.emit(SessionState.connected);
      session.emit(SessionState.failed, SessionEndReason.transport);
      for (var attempt = 0; attempt < 5; attempt++) {
        final seconds = 1 << attempt;
        expect(recovery.remainingSeconds, seconds);
        await tester.pump(Duration(seconds: seconds - 1));
        expect(calls, attempt);
        await tester.pump(const Duration(seconds: 1));
        expect(calls, attempt + 1);
      }
      expect(recovery.pending, isFalse);
      expect(recovery.exhausted, isTrue);
      await tester.pump(const Duration(minutes: 2));
      expect(calls, 5);
    },
  );

  testWidgets(
    'initial failure, explicit ends and disabled preference never retry',
    (tester) async {
      for (final reason in SessionEndReason.values) {
        final session = FakeSession();
        var calls = 0;
        final recovery = SessionRecovery(
          session,
          reconnect: () async {
            calls++;
          },
        );
        session.emit(SessionState.failed, SessionEndReason.transport);
        expect(
          recovery.pending,
          isFalse,
          reason: 'Initial failure is not retried',
        );
        session.emit(SessionState.connected);
        session.emit(
          reason == SessionEndReason.remote || reason == SessionEndReason.local
              ? SessionState.closed
              : reason == SessionEndReason.certificate
              ? SessionState.certificateRequired
              : SessionState.failed,
          reason,
        );
        if (reason == SessionEndReason.transport) recovery.cancel();
        await tester.pump(const Duration(seconds: 40));
        expect(calls, 0, reason: reason.name);
        recovery.dispose();
        session.dispose();
      }
      final session = FakeSession(enabled: false);
      final recovery = SessionRecovery(
        session,
        reconnect: () async {
          fail('Disabled retry');
        },
      );
      session.emit(SessionState.connected);
      session.emit(SessionState.failed, SessionEndReason.transport);
      expect(recovery.pending, isFalse);
      recovery.dispose();
      session.dispose();
    },
  );

  testWidgets(
    'cancel pending and in-flight retries; manual reset; stable budget reset',
    (tester) async {
      final session = FakeSession();
      var calls = 0;
      final recovery = SessionRecovery(
        session,
        reconnect: () async {
          calls++;
          session.emit(SessionState.connecting);
        },
      );
      addTearDown(session.dispose);
      addTearDown(recovery.dispose);
      session.emit(SessionState.connected);
      session.emit(SessionState.failed, SessionEndReason.transport);
      recovery.cancel();
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 0);
      recovery.reset();
      session.emit(SessionState.connecting);
      session.emit(SessionState.connected);
      session.emit(SessionState.failed, SessionEndReason.transport);
      recovery.retryNow();
      recovery.retryNow();
      expect(calls, 1);
      expect(recovery.running, isTrue);
      recovery.cancel();
      await tester.pump();
      expect(session.endReason, SessionEndReason.local);
      expect(recovery.pending, isFalse);
      session.emit(SessionState.connected);
      session.emit(SessionState.failed, SessionEndReason.transport);
      await tester.pump(const Duration(seconds: 1));
      session.emit(SessionState.connected);
      expect(recovery.attempts, 1);
      await tester.pump(const Duration(seconds: 29));
      expect(recovery.attempts, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(recovery.attempts, 0);
    },
  );

  testWidgets(
    'authentication failure during a retry cancels further attempts',
    (tester) async {
      for (final reason in [
        SessionEndReason.authentication,
        SessionEndReason.certificate,
        SessionEndReason.remote,
      ]) {
        final session = FakeSession();
        var calls = 0;
        final recovery = SessionRecovery(
          session,
          reconnect: () async {
            calls++;
            session.emit(SessionState.connecting);
            session.emit(SessionState.failed, reason);
          },
        );
        session.emit(SessionState.connected);
        session.emit(SessionState.failed, SessionEndReason.transport);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(minutes: 1));
        expect(calls, 1);
        expect(recovery.pending, isFalse);
        recovery.dispose();
        session.dispose();
      }
    },
  );
}
