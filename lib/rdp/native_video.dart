import 'dart:async';
import 'package:flutter/services.dart';

/// The platform renderer owns a retained, immutable native frame reader.
/// Only metadata crosses this channel; frame bytes never enter Dart.
class NativeVideo {
  NativeVideo._(this.id, this.changed, this.failed);
  static const channel = MethodChannel('dev.lrdp/video');
  final int id;
  final void Function(NativeVideo) changed, failed;
  int width = 0, height = 0, uploads = 0, generation = 0;
  bool _closed = false, _polling = false, _visible = true;
  Timer? _timer;
  DateTime _nextPoll = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<NativeVideo?> create(
    int ticket, {
    required void Function(NativeVideo) changed,
    required void Function(NativeVideo) failed,
  }) async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('create', {
        'ticket': ticket,
      });
      final id = result?['id'];
      if (id is! int || id < 0) return null;
      final video = NativeVideo._(id, changed, failed);
      video._update(result!);
      video._startPolling();
      return video;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  void _startPolling() {
    if (_closed || !_visible || _timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (DateTime.now().isAfter(_nextPoll)) unawaited(poll());
    });
  }

  void _update(Map<String, dynamic> value) {
    if (_closed) return;
    if (value['failed'] == true) {
      failed(this);
      return;
    }
    final w = value['width'], h = value['height'];
    if (w is! int || h is! int || w < 0 || h < 0 || w > 4096 || h > 4096) {
      failed(this);
      return;
    }
    final count = value['uploads'] as int? ?? 0;
    final serial = value['generation'] as int? ?? 0;
    final update =
        width != w || height != h || uploads != count || generation != serial;
    width = w;
    height = h;
    uploads = count;
    generation = serial;
    if (update) changed(this);
  }

  Future<void> poll() async {
    if (_closed || _polling || !_visible) return;
    _polling = true;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('status', {
        'id': id,
      });
      if (!_closed && result != null) _update(result);
    } on PlatformException {
      if (!_closed) failed(this);
    } on MissingPluginException {
      if (!_closed) failed(this);
    } finally {
      _polling = false;
      _nextPoll = DateTime.now().add(
        Duration(milliseconds: width > 0 ? 100 : 0),
      );
    }
  }

  Future<void> setVisible(bool visible) async {
    if (_closed) return;
    _visible = visible;
    if (visible) {
      _startPolling();
    } else {
      _timer?.cancel();
      _timer = null;
    }
    try {
      await channel.invokeMethod<void>('visible', {
        'id': id,
        'visible': visible,
      });
      if (visible && !_closed) await poll();
    } on PlatformException {
      if (!_closed) failed(this);
    } on MissingPluginException {
      if (!_closed) failed(this);
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    try {
      await channel.invokeMethod<void>('dispose', {'id': id});
    } on PlatformException {
      // The engine may already have released the renderer during shutdown.
    } on MissingPluginException {
      // Native plugins are absent from headless tests and unsupported hosts.
    }
  }
}
