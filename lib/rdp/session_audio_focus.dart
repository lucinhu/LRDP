import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'rdp_session.dart';

/// One foreground session owns playback. Platform callbacks carry a generation
/// so an old request cannot unmute a replacement or a background session.
class SessionAudioFocus {
  SessionAudioFocus({bool? android, MethodChannel? channel})
    : _android = android ?? Platform.isAndroid,
      _channel = channel ?? const MethodChannel('dev.lrdp/audio_focus') {
    if (_android) {
      _handlerOwner?.select(null);
      _handlerOwner = this;
      _channel.setMethodCallHandler(_changed);
    }
  }
  final bool _android;
  final MethodChannel _channel;
  RdpSession? _session;
  static int _nextToken = 0;
  static SessionAudioFocus? _handlerOwner;
  int _generation = 0;
  int? _nativeToken;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();

  void select(
    RdpSession? session, {
    bool foreground = true,
    bool force = false,
  }) {
    final next =
        foreground &&
            session != null &&
            session.profile.audio &&
            session.isActive
        ? session
        : null;
    if (_disposed || (!force && identical(next, _session))) return;
    _session?.setAudioAllowed(false);
    next?.setAudioAllowed(false);
    _session = next;
    final token = _generation = ++_nextToken;
    if (!_android) {
      next?.setAudioAllowed(true);
      return;
    }
    // Serialize native requests, but revoke permission synchronously above.
    _tail = _tail.then((_) async {
      if (token != _generation || _disposed) return;
      await _release();
      if (token != _generation || _disposed || next == null) return;
      var granted = false;
      try {
        _nativeToken = token;
        granted =
            await _channel.invokeMethod<bool>('request', {'token': token}) ??
            false;
      } on PlatformException {
        // Missing/denied focus must leave playback paused, not break RDP.
      } on MissingPluginException {
        // A platform without this handler cannot grant Android playback.
      }
      if (token == _generation && !_disposed && identical(_session, next)) {
        next.setAudioAllowed(granted);
      } else {
        await _release(token: token);
      }
    });
  }

  Future<void> _release({int? token}) async {
    final owned = token ?? _nativeToken;
    if (owned == null) return;
    if (owned == _nativeToken) _nativeToken = null;
    try {
      await _channel.invokeMethod<void>('release', {'token': owned});
    } on PlatformException {
      // Playback permission was already revoked locally.
    } on MissingPluginException {
      // Nothing was acquired if the platform handler is unavailable.
    }
  }

  Future<void> _changed(MethodCall call) async {
    if (call.method != 'changed' || _disposed) return;
    final data = call.arguments;
    if (data is! Map || data['token'] != _generation) return;
    _session?.setAudioAllowed(data['granted'] == true);
  }

  Future<void> get settled => _tail;

  void dispose() {
    if (_disposed) return;
    _session?.setAudioAllowed(false);
    _session = null;
    _disposed = true;
    _generation = ++_nextToken;
    if (_android) {
      if (identical(_handlerOwner, this)) {
        _handlerOwner = null;
        _channel.setMethodCallHandler(null);
      }
      _tail = _tail.then((_) => _release());
      unawaited(_tail);
    }
  }
}
