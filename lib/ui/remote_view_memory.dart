import 'dart:ui';

/// UI data for one open connection; discarded when that connection is removed.
/// No controllers, pending gestures, credentials or persistent storage.
class RemoteViewMemory {
  bool? trackpad;
  bool pan = false;
  bool keyboardSimulation = false;
  bool pasteText = false;
  bool controlsCollapsed = false;
  Offset controlsPosition = const Offset(1, 0);
  final surface = RemoteSurfaceMemory();
}

class RemoteSurfaceMemory {
  RemoteViewportSnapshot? viewport;
}

class RemoteViewportSnapshot {
  const RemoteViewportSnapshot({
    required this.zoom,
    required this.center,
    required this.pointer,
    required this.serverPositionSerial,
    required this.connection,
  });
  final double zoom;

  /// Fractions of the remote image, independent of phone/keyboard geometry.
  final Offset center;
  final Offset? pointer;
  final int serverPositionSerial;
  final DateTime? connection;
}
