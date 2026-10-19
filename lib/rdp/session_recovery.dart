import 'dart:async';
import 'package:flutter/foundation.dart';
import 'rdp_session.dart';

/// Fresh connections with bounded backoff; never replays keyboard or text input.
/// Credentials remain with the session manager and are not retained here.
class SessionRecovery extends ChangeNotifier {
  SessionRecovery(this.session, {required this.reconnect}) {
    session.addListener(_changed);
    _changed();
  }

  final RdpSession session;
  final Future<void> Function() reconnect;
  static const maxAttempts = 5;
  int attempts = 0, remainingSeconds = 0;
  bool _armed = false, _disposed = false, _recovering = false;
  bool _foreground = true;
  Timer? _countdown, _stable;
  SessionState? _lastState;
  bool get pending => _countdown != null;
  bool get suspended => !_foreground && _recovering && remainingSeconds > 0;
  bool get running => _recovering && session.state == SessionState.connecting;
  bool get exhausted =>
      _armed && attempts >= maxAttempts && !running && !pending;

  void _changed() {
    if (_disposed || _lastState == session.state) return;
    _lastState = session.state;
    _stable?.cancel();
    _stable = null;
    if (session.state == SessionState.connected) {
      _cancelCountdown();
      _armed = true;
      _recovering = false;
      // A flapping connection must not reset its retry budget on each handshake.
      _startStableTimer();
    } else if (session.state == SessionState.failed &&
        session.endReason == SessionEndReason.transport &&
        session.profile.autoReconnect &&
        _armed) {
      if (!pending && attempts < maxAttempts) _schedule();
    } else if (session.state != SessionState.connecting) {
      _cancelCountdown();
      _armed = _recovering = false;
    }
    notifyListeners();
  }

  void _schedule() {
    _recovering = true;
    remainingSeconds = 1 << attempts;
    _startCountdown();
  }

  void _startStableTimer() {
    if (!_foreground) return;
    _stable = Timer(const Duration(seconds: 30), () {
      attempts = 0;
      if (!_disposed) notifyListeners();
    });
  }

  /// Mobile background time does not consume a retry delay or reset the budget.
  /// Healthy sessions stay connected; an already started attempt may finish.
  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _countdown?.cancel();
    _countdown = null;
    _stable?.cancel();
    _stable = null;
    if (value) {
      if (session.state == SessionState.connected) _startStableTimer();
      if (_recovering && remainingSeconds > 0) _startCountdown();
    }
    notifyListeners();
  }

  void _startCountdown() {
    if (!_foreground) return;
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      remainingSeconds--;
      if (remainingSeconds == 0) {
        _cancelCountdown();
        unawaited(_attempt());
      } else {
        notifyListeners();
      }
    });
  }

  Future<void> _attempt() async {
    if (_disposed || !_armed || !_foreground || attempts >= maxAttempts) return;
    attempts++;
    notifyListeners();
    try {
      await reconnect();
    } catch (_) {
      // Unexpected manager/storage errors are not transport failures.
      if (!_disposed) cancel();
    }
  }

  void retryNow() {
    if (!pending) return;
    _cancelCountdown();
    unawaited(_attempt());
  }

  void _cancelCountdown() {
    _countdown?.cancel();
    _countdown = null;
    remainingSeconds = 0;
  }

  /// A manual reconnect starts a new budget; cancel also stops an active retry.
  void reset() {
    _cancelCountdown();
    _stable?.cancel();
    _stable = null;
    _armed = _recovering = false;
    attempts = 0;
    if (!_disposed) notifyListeners();
  }

  void cancel() {
    final stop = running;
    reset();
    if (stop) unawaited(session.close());
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelCountdown();
    _stable?.cancel();
    session.removeListener(_changed);
    super.dispose();
  }
}
