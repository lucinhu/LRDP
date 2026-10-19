import 'dart:ui' as ui;

enum RdpCursorKind { system, hidden, bitmap }

/// Images belong to RdpSession. Hotspot and position are in remote pixels.
class RdpCursor {
  const RdpCursor({
    this.kind = RdpCursorKind.system,
    this.image,
    this.inversion,
    this.hotX = 0,
    this.hotY = 0,
    this.x = -1,
    this.y = -1,
    this.positionSerial = 0,
  });
  final RdpCursorKind kind;
  final ui.Image? image, inversion;
  final int hotX, hotY, x, y, positionSerial;
}
