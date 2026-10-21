import 'package:flutter/services.dart';
import '../models/remote_input_mode.dart';

/// UI data for one open connection; discarded when that connection is removed.
/// No controllers, pending gestures, credentials or persistent storage.
class RemoteViewMemory {
  RemoteViewMemory({RemoteInputMode inputMode = RemoteInputMode.keyboard}) {
    mode = inputMode;
  }
  bool? trackpad;
  bool pan = false;
  bool keyboardSimulation = true;
  bool pasteText = false;
  TextEditingValue textDraft = TextEditingValue.empty;
  RemoteInputMode get mode => keyboardSimulation
      ? RemoteInputMode.keyboard
      : pasteText
      ? RemoteInputMode.paste
      : RemoteInputMode.text;
  set mode(RemoteInputMode value) {
    keyboardSimulation = value == RemoteInputMode.keyboard;
    pasteText = value == RemoteInputMode.paste;
  }

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
