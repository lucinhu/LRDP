import '../l10n/app_strings.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../rdp/rdp_session.dart';
import '../rdp/rdp_cursor.dart';
import 'remote_view_memory.dart';

/// Pointer handling lives outside the transformed image, so zoom never changes
/// the coordinate system used to interpret finger motion.
class RemoteSurface extends StatefulWidget {
  const RemoteSurface({
    super.key,
    required this.session,
    required this.focus,
    required this.transform,
    required this.trackpad,
    required this.pan,
    this.active = true,
    this.preserveKeyboardFocus = false,
    this.memory,
  });
  final RdpSession session;
  final FocusNode focus;
  final TransformationController transform;
  final bool trackpad, pan, active;
  final bool preserveKeyboardFocus;
  final RemoteSurfaceMemory? memory;
  @override
  State<RemoteSurface> createState() => _RemoteSurfaceState();
}

class _RemoteSurfaceState extends State<RemoteSurface>
    with WidgetsBindingObserver {
  final _touches = <int, Offset>{};
  final _touchStarts = <int, Offset>{};
  final _pairChanged = <int>{};
  final _buttons = <int>{};
  int? _hardwarePointer, _hardwareDevice;
  Offset? _pointer, _origin, _lastTap, _pendingTap;
  Timer? _holdTimer, _doubleTapTimer;
  Timer? _dragTimer, _tapTimer, _pairTimer, _edgeTimer;
  Offset? _edgeLocal;
  bool _dragPending = false, _pairTapEligible = false;
  bool _moved = false, _held = false, _multi = false, _dragging = false;
  Offset _pairOrigin = Offset.zero, _pairPrevious = Offset.zero;
  double _pairDistance = 1, _wheel = 0, _wheelX = 0;
  String? _pairMode;
  Matrix4 _pairMatrix = Matrix4.identity();
  int? _panZoomPointer;
  String? _panZoomMode;
  Offset _panZoomOrigin = Offset.zero, _trackpadWheel = Offset.zero;
  Matrix4 _panZoomMatrix = Matrix4.identity();
  bool _mouseInside = false;
  int _serverPositionSerial = 0;
  Size _viewport = Size.zero;
  Size _desktopSize = Size.zero;
  double _baseScale = 1;
  Offset _imageOrigin = Offset.zero;
  late RemoteSurfaceMemory _memory;
  int _layoutSerial = 0;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory ?? RemoteSurfaceMemory();
    WidgetsBinding.instance.addObserver(this);
    widget.focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (!widget.focus.hasFocus) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (widget.active &&
          widget.session.state == SessionState.connected &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
        // Tapping a remote text field then immediately opening the local
        // keyboard must deliver that tap before keyboard input takes focus.
        _flushTap();
      }
      _cancel();
    }
  }

  @override
  void didUpdateWidget(covariant RemoteSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
    }
    if (oldWidget.trackpad != widget.trackpad ||
        oldWidget.pan != widget.pan ||
        !widget.active ||
        oldWidget.session != widget.session) {
      _cancel();
    }
    if (oldWidget.session != widget.session) {
      _pointer = null;
      _serverPositionSerial = 0;
    }
    if (oldWidget.memory != widget.memory ||
        oldWidget.session != widget.session) {
      _memory = widget.memory ?? RemoteSurfaceMemory();
      _viewport = Size.zero;
      _desktopSize = Size.zero;
      _layoutSerial++;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancel();
  }

  @override
  void dispose() {
    _rememberViewport();
    WidgetsBinding.instance.removeObserver(this);
    widget.focus.removeListener(_focusChanged);
    _cancel();
    _doubleTapTimer?.cancel();
    super.dispose();
  }

  void _rememberViewport() {
    if (_viewport.isEmpty || _desktopSize.isEmpty) return;
    final center =
        (MatrixUtils.transformPoint(
              Matrix4.inverted(widget.transform.value),
              _viewport.center(Offset.zero),
            ) -
            _imageOrigin) /
        _baseScale;
    _memory.viewport = RemoteViewportSnapshot(
      zoom: widget.transform.value.getMaxScaleOnAxis(),
      center: Offset(
        center.dx / _desktopSize.width,
        center.dy / _desktopSize.height,
      ),
      pointer: _pointer == null
          ? null
          : Offset(
              _pointer!.dx / math.max(1, _desktopSize.width - 1),
              _pointer!.dy / math.max(1, _desktopSize.height - 1),
            ),
      serverPositionSerial: _serverPositionSerial,
      connection: widget.session.connectedAt,
    );
  }

  void _restoreViewport(RemoteViewportSnapshot snapshot) {
    final zoom = snapshot.zoom.clamp(1.0, 5.0);
    final remoteCenter = Offset(
      snapshot.center.dx * _desktopSize.width,
      snapshot.center.dy * _desktopSize.height,
    );
    final offset =
        _viewport.center(Offset.zero) -
        (_imageOrigin + remoteCenter * _baseScale) * zoom;
    _matrix(
      Matrix4.diagonal3Values(zoom, zoom, 1)
        ..setTranslationRaw(offset.dx, offset.dy, 0),
    );
  }

  Offset _clamp(Offset p) {
    final image = (
      width: widget.session.desktopWidth,
      height: widget.session.desktopHeight,
    );
    return Offset(
      p.dx.clamp(0, image.width - 1.0),
      p.dy.clamp(0, image.height - 1.0),
    );
  }

  Offset _map(Offset p) => _clamp(
    (MatrixUtils.transformPoint(Matrix4.inverted(widget.transform.value), p) -
            _imageOrigin) /
        _baseScale,
  );
  void _mouse(int flags, Offset p) =>
      widget.session.mouse(flags, p.dx.round(), p.dy.round());
  void _button(int flags, bool down, Offset p) {
    if (down) {
      _buttons.add(flags);
    } else {
      _buttons.remove(flags);
    }
    // The native owner sends position and button changes as separate PDUs;
    // peers such as KRDP treat MOVE|BUTTON release as movement only.
    _mouse(0x0800 | flags | (down ? 0x8000 : 0), p);
  }

  void _release() {
    _dragTimer?.cancel();
    _dragPending = false;
    for (final button in _buttons.toList()) {
      _button(button, false, _pointer ?? Offset.zero);
    }
    _dragging = false;
    _hardwarePointer = _hardwareDevice = null;
  }

  void _hardwareButtons(int buttons) {
    for (final entry in {1: 0x1000, 2: 0x2000, 4: 0x4000}.entries) {
      final down = buttons & entry.key != 0;
      if (_buttons.contains(entry.value) != down) {
        _button(entry.value, down, _pointer!);
      }
    }
  }

  void _recoverHardwareRelease(PointerEvent event) {
    // A release outside the application can be absent from the routed stream.
    // A real mouse returning with no buttons down is authoritative. Touch hover
    // must not cancel an active finger drag or change its relative cursor.
    if (event.kind != PointerDeviceKind.touch &&
        event.device == _hardwareDevice &&
        event.buttons == 0) {
      _release();
    }
  }

  void _cancel() {
    _release();
    _holdTimer?.cancel();
    _doubleTapTimer?.cancel();
    _pendingTap = _lastTap = null;
    _tapTimer?.cancel();
    _pairTimer?.cancel();
    _stopEdgePan();
    _touches.clear();
    _touchStarts.clear();
    _pairChanged.clear();
    _pairTapEligible = false;
    _multi = true;
    _endPanZoom();
  }

  bool _matrix(Matrix4 value) {
    final scale = value.getMaxScaleOnAxis();
    final image = (
      width: widget.session.desktopWidth,
      height: widget.session.desktopHeight,
    );
    double translation(
      double requested,
      double viewport,
      double origin,
      double extent,
    ) {
      final length = extent * _baseScale * scale;
      if (length <= viewport) return (viewport - length) / 2 - origin * scale;
      return requested.clamp(
        viewport - (origin * scale + length),
        -origin * scale,
      );
    }

    value.setTranslationRaw(
      translation(
        value.storage[12],
        _viewport.width,
        _imageOrigin.dx,
        image.width.toDouble(),
      ),
      translation(
        value.storage[13],
        _viewport.height,
        _imageOrigin.dy,
        image.height.toDouble(),
      ),
      0,
    );
    if (widget.transform.value == value) return false;
    widget.transform.value = value;
    return true;
  }

  void _followPointer() {
    final position = MatrixUtils.transformPoint(
      widget.transform.value,
      _imageOrigin + _pointer! * _baseScale,
    );
    final margin = math.min(36.0, _viewport.shortestSide * .1);
    final target = Offset(
      position.dx.clamp(margin, _viewport.width - margin),
      position.dy.clamp(margin, _viewport.height - margin),
    );
    final delta = target - position;
    if (delta != Offset.zero) {
      _matrix(
        Matrix4.translationValues(delta.dx, delta.dy, 0)
          ..multiply(widget.transform.value),
      );
    }
  }

  void _stopEdgePan() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgeLocal = null;
  }

  Offset _edgeVelocity(Offset local) {
    final margin = math.min(36.0, _viewport.shortestSide * .1);
    double axis(double p, double length) {
      if (p < margin) return 360 * ((margin - p) / margin).clamp(0, 1);
      if (p > length - margin) {
        return -360 * ((p - length + margin) / margin).clamp(0, 1);
      }
      return 0;
    }

    return Offset(
      axis(local.dx, _viewport.width),
      axis(local.dy, _viewport.height),
    );
  }

  void _hardwareMove(Offset local) {
    setState(() => _pointer = _map(local));
    _mouse(0x0800, _pointer!);
    if (_edgeVelocity(local) == Offset.zero ||
        widget.transform.value.getMaxScaleOnAxis() <= 1) {
      _stopEdgePan();
      return;
    }
    _edgeLocal = local;
    _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted ||
          !widget.active ||
          widget.pan ||
          widget.session.state != SessionState.connected ||
          !widget.session.hasVideo) {
        _stopEdgePan();
        return;
      }
      final local = _edgeLocal!;
      final delta = _edgeVelocity(local) * .016;
      if (!_matrix(
        Matrix4.translationValues(delta.dx, delta.dy, 0)
          ..multiply(widget.transform.value),
      )) {
        _stopEdgePan();
        return;
      }
      setState(() => _pointer = _map(local));
      _mouse(0x0800, _pointer!);
    });
  }

  void _beginDrag() {
    if (!_dragPending || _multi || widget.pan || !widget.active) return;
    _dragTimer?.cancel();
    _holdTimer?.cancel();
    _dragPending = false;
    // The first tap is only a local gesture prefix. Sending it before this
    // press makes remote window managers interpret the drag as a double click.
    _pendingTap = _lastTap = null;
    _button(0x1000, true, _pointer!);
    _dragging = true;
  }

  void _flushTap() {
    _doubleTapTimer?.cancel();
    final position = _pendingTap;
    _pendingTap = _lastTap = null;
    if (position != null) {
      _button(0x1000, true, position);
      _button(0x1000, false, position);
    }
  }

  void _wheelEvent(double delta, {bool horizontal = false}) {
    if (delta == 0) return;
    final negative = delta < 0;
    widget.session.mouse(
      (horizontal ? 0x0400 : 0x0200) | (negative ? 0x0100 | (512 - 120) : 120),
      0,
      0,
    );
  }

  bool get _canPanZoom {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return widget.active &&
        widget.session.state == SessionState.connected &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  void _startPanZoom(PointerPanZoomStartEvent event) {
    if (!_canPanZoom) return;
    if (!widget.preserveKeyboardFocus) widget.focus.requestFocus();
    _stopEdgePan();
    _panZoomPointer = event.pointer;
    _panZoomMode = widget.pan ? 'zoom' : null;
    _panZoomOrigin = event.localPosition;
    _panZoomMatrix = widget.transform.value.clone();
    _trackpadWheel = Offset.zero;
  }

  void _updatePanZoom(PointerPanZoomUpdateEvent event) {
    if (!_canPanZoom || _panZoomPointer != event.pointer) return;
    final undecided = _panZoomMode == null;
    if (undecided) {
      if ((event.scale - 1).abs() > .02) {
        _panZoomMode = 'zoom';
      } else if (event.localPan.distance >= 4) {
        _panZoomMode = 'scroll';
      }
    }
    if (_panZoomMode == 'zoom') {
      final initialScale = _panZoomMatrix.getMaxScaleOnAxis();
      final factor =
          (initialScale * event.scale).clamp(1.0, 5.0) / initialScale;
      final center = _panZoomOrigin + event.localPan;
      _matrix(
        Matrix4.translationValues(center.dx, center.dy, 0)
          ..multiply(Matrix4.diagonal3Values(factor, factor, 1))
          ..multiply(
            Matrix4.translationValues(
              -_panZoomOrigin.dx,
              -_panZoomOrigin.dy,
              0,
            ),
          )
          ..multiply(_panZoomMatrix),
      );
    } else if (_panZoomMode == 'scroll') {
      // Desktop trackpads report a pan/zoom stream, not touch pointers. Keep
      // sub-step motion so slow gestures scroll, and preserve both axes.
      final delta = undecided ? event.localPan : event.localPanDelta;
      _trackpadWheel += Offset(-delta.dx, delta.dy);
      while (_trackpadWheel.dy.abs() >= 24) {
        _wheelEvent(_trackpadWheel.dy);
        _trackpadWheel -= Offset(0, _trackpadWheel.dy.sign * 24);
      }
      while (_trackpadWheel.dx.abs() >= 24) {
        _wheelEvent(_trackpadWheel.dx, horizontal: true);
        _trackpadWheel -= Offset(_trackpadWheel.dx.sign * 24, 0);
      }
    }
  }

  void _endPanZoom() {
    _panZoomPointer = null;
    _panZoomMode = null;
    _trackpadWheel = Offset.zero;
  }

  void _down(PointerDownEvent e) {
    if (!widget.active) return;
    if (!widget.preserveKeyboardFocus) {
      widget.focus.requestFocus();
    }
    if (e.kind != PointerDeviceKind.touch) {
      if (widget.pan) return;
      _flushTap();
      if (_hardwarePointer != null && _hardwarePointer != e.pointer) _release();
      _hardwarePointer = e.pointer;
      _hardwareDevice = e.device;
      _pointer = _map(e.localPosition);
      _hardwareButtons(e.buttons);
      return;
    }
    _stopEdgePan();
    _touches[e.pointer] = e.localPosition;
    _touchStarts[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _multi = false;
      _moved = false;
      _held = false;
      _origin = e.localPosition;
      _pairTapEligible = false;
      _tapTimer?.cancel();
      _tapTimer = Timer(const Duration(milliseconds: 350), () {
        _pairTapEligible = false;
      });
      _holdTimer = Timer(const Duration(milliseconds: 500), () {
        _held = true;
      });
      if (!widget.pan &&
          (_doubleTapTimer?.isActive ?? false) &&
          _lastTap != null &&
          (e.localPosition - _lastTap!).distance < 32) {
        _doubleTapTimer?.cancel();
        _pointer = widget.trackpad ? _pointer : _map(e.localPosition);
        // Wait for motion/hold so a second finger joining the touch does not
        // accidentally press the remote left button.
        _dragPending = true;
        _dragTimer = Timer(const Duration(milliseconds: 150), _beginDrag);
      } else {
        _flushTap();
      }
    } else {
      final tapEligible =
          _touches.length == 2 &&
          (_tapTimer?.isActive ?? false) &&
          !_moved &&
          !_held &&
          !_dragging &&
          !widget.pan;
      _multi = true;
      _holdTimer?.cancel();
      _flushTap();
      _release();
      if (_touches.length == 2) {
        final pair = _touches.values.toList();
        _pairOrigin = _pairPrevious = (pair[0] + pair[1]) / 2;
        _pairDistance = math.max(1, (pair[0] - pair[1]).distance);
        _pairMatrix = widget.transform.value.clone();
        _pairMode = null;
        _wheel = _wheelX = 0;
        _pairChanged.clear();
        _pairTapEligible = tapEligible;
      } else {
        _pairTapEligible = false;
        _pairMode = 'blocked';
      }
    }
  }

  void _applyPairMotion() {
    _pairTimer?.cancel();
    _pairTimer = null;
    _pairChanged.clear();
    if (_touches.length != 2 || _pairMode == 'blocked') return;
    final pair = _touches.values.toList();
    final center = (pair[0] + pair[1]) / 2;
    final distance = (pair[0] - pair[1]).distance;
    final ratio = distance / _pairDistance;
    if (_pairMode == null) {
      if (widget.pan ||
          ((ratio - 1).abs() > .08 && (distance - _pairDistance).abs() > 10)) {
        _pairMode = 'zoom';
      } else if ((center - _pairOrigin).distance > 10) {
        _pairMode = 'scroll';
      }
    }
    if (_pairMode == 'zoom') {
      _pairTapEligible = false;
      final initialScale = _pairMatrix.getMaxScaleOnAxis();
      final factor = (initialScale * ratio).clamp(1.0, 5.0) / initialScale;
      _matrix(
        Matrix4.translationValues(center.dx, center.dy, 0)
          ..multiply(Matrix4.diagonal3Values(factor, factor, 1))
          ..multiply(
            Matrix4.translationValues(-_pairOrigin.dx, -_pairOrigin.dy, 0),
          )
          ..multiply(_pairMatrix),
      );
    } else if (_pairMode == 'scroll') {
      _pairTapEligible = false;
      _wheel += center.dy - _pairPrevious.dy;
      _wheelX -= center.dx - _pairPrevious.dx;
      while (_wheel.abs() >= 24) {
        _wheelEvent(_wheel);
        _wheel -= _wheel.sign * 24;
      }
      while (_wheelX.abs() >= 24) {
        _wheelEvent(_wheelX, horizontal: true);
        _wheelX -= _wheelX.sign * 24;
      }
    }
    _pairPrevious = center;
  }

  void _move(PointerMoveEvent e) {
    if (!widget.active) return;
    if (e.kind != PointerDeviceKind.touch) {
      if (!widget.pan) {
        // Flutter reports intermediate multi-button presses/releases as Move,
        // even with zero movement; Up arrives only after the last button.
        if (_hardwarePointer == e.pointer) {
          _pointer = _map(e.localPosition);
          _hardwareButtons(e.buttons);
        }
        _hardwareMove(e.localPosition);
      }
      return;
    }
    final previous = _touches[e.pointer];
    if (previous == null) return;
    _touches[e.pointer] = e.localPosition;
    if ((e.localPosition - _touchStarts[e.pointer]!).distance > 10) {
      _pairTapEligible = false;
    }
    if (_touches.length >= 2) {
      // Touch packets arrive one finger at a time. Coalesce both updates to
      // avoid mistaking a parallel two-finger swipe for a pinch.
      _pairChanged.add(e.pointer);
      if (_pairChanged.length >= 2) {
        _applyPairMotion();
      } else if (!(_pairTimer?.isActive ?? false)) {
        _pairTimer = Timer(const Duration(milliseconds: 16), _applyPairMotion);
      }
      return;
    }
    if (_multi) return;
    final delta = e.localPosition - previous;
    if ((e.localPosition - _origin!).distance > 8) {
      _moved = true;
      _holdTimer?.cancel();
      if (_dragPending) _beginDrag();
    }
    if (widget.pan) {
      _matrix(
        Matrix4.translationValues(delta.dx, delta.dy, 0)
          ..multiply(widget.transform.value),
      );
    } else if (widget.trackpad || _dragging) {
      setState(
        () => _pointer = widget.trackpad
            ? _clamp(
                _pointer! +
                    delta /
                        (_baseScale *
                            widget.transform.value.getMaxScaleOnAxis()),
              )
            : _map(e.localPosition),
      );
      if (widget.trackpad) _followPointer();
      _mouse(0x0800, _pointer!);
    }
  }

  void _up(PointerUpEvent e) {
    if (e.kind != PointerDeviceKind.touch) {
      if (_hardwarePointer == e.pointer) {
        _pointer = _map(e.localPosition);
        _release();
      }
      return;
    }
    if (!_touches.containsKey(e.pointer)) return;
    if (_touches.length == 2) _applyPairMotion();
    _holdTimer?.cancel();
    _touches.remove(e.pointer);
    _touchStarts.remove(e.pointer);
    if (_multi) {
      if (_touches.isEmpty) {
        if (_pairTapEligible && (_tapTimer?.isActive ?? false) && !widget.pan) {
          if (!widget.trackpad) _pointer = _map(_pairOrigin);
          _button(0x2000, true, _pointer!);
          _button(0x2000, false, _pointer!);
        }
        _pairTapEligible = false;
        _tapTimer?.cancel();
        _pairTimer?.cancel();
      }
      return;
    }
    final secondTap = _dragPending;
    _dragTimer?.cancel();
    _dragPending = false;
    _tapTimer?.cancel();
    if (_dragging) {
      _release();
    } else if (!_multi && !_moved && !widget.pan) {
      _pointer = widget.trackpad ? _pointer : _map(e.localPosition);
      final button = _held ? 0x2000 : 0x1000;
      if (secondTap || _held) {
        _flushTap();
        _button(button, true, _pointer!);
        _button(button, false, _pointer!);
      } else {
        _pendingTap = _pointer;
        _lastTap = e.localPosition;
        _doubleTapTimer?.cancel();
        _doubleTapTimer = Timer(const Duration(milliseconds: 300), _flushTap);
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final image = (
        width: widget.session.desktopWidth,
        height: widget.session.desktopHeight,
      );
      final desktopSize = Size(image.width.toDouble(), image.height.toDouble());
      final geometryChanged =
          _viewport != constraints.biggest || _desktopSize != desktopSize;
      RemoteViewportSnapshot? saved;
      if (geometryChanged) {
        _rememberViewport();
        saved = _memory.viewport;
        // Release at the last sent position before scaling the cursor to a
        // changed remote resolution; active gestures never survive layout.
        _cancel();
      }
      _viewport = constraints.biggest;
      _desktopSize = desktopSize;
      _baseScale = math.min(
        _viewport.width / image.width,
        _viewport.height / image.height,
      );
      final size = Size(image.width * _baseScale, image.height * _baseScale);
      _imageOrigin = Offset(
        (_viewport.width - size.width) / 2,
        (_viewport.height - size.height) / 2,
      );
      if (geometryChanged) {
        if (saved?.pointer case final pointer?) {
          _pointer = Offset(
            pointer.dx * math.max(1, desktopSize.width - 1),
            pointer.dy * math.max(1, desktopSize.height - 1),
          );
        }
        if (saved != null && saved.connection == widget.session.connectedAt) {
          _serverPositionSerial = saved.serverPositionSerial;
        }
        final restore = saved;
        final serial = ++_layoutSerial;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || serial != _layoutSerial || !widget.session.hasVideo) {
            return;
          }
          if (restore != null) {
            _restoreViewport(restore);
          } else {
            _matrix(widget.transform.value.clone());
          }
        });
      }
      final cursor = widget.session.cursor;
      if (_serverPositionSerial != cursor.positionSerial) {
        _serverPositionSerial = cursor.positionSerial;
        if (cursor.x >= 0 && cursor.y >= 0) {
          _pointer = Offset(cursor.x.toDouble(), cursor.y.toDouble());
        }
      }
      _pointer = _clamp(_pointer ?? Offset(image.width / 2, image.height / 2));
      return Semantics(
        label: context.tr("远程桌面。轻点左键，双指轻点或长按右键，双击按住拖拽；双指滚动、捏合缩放，光标靠近边缘自动移动视野。"),
        child: MouseRegion(
          cursor: widget.pan
              ? SystemMouseCursors.grab
              : SystemMouseCursors.none,
          onEnter: (event) {
            if (event.kind == PointerDeviceKind.touch) return;
            _recoverHardwareRelease(event);
            // A stationary mouse also enters a newly rebuilt region. Actual
            // hover/down events take control; entering preserves the cursor.
            setState(() => _mouseInside = true);
          },
          onExit: (event) {
            if (event.kind == PointerDeviceKind.touch) return;
            _recoverHardwareRelease(event);
            _stopEdgePan();
            setState(() => _mouseInside = false);
          },
          child: Listener(
            key: const Key('remoteSurface'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: (_) => _cancel(),
            onPointerPanZoomStart: _startPanZoom,
            onPointerPanZoomUpdate: _updatePanZoom,
            onPointerPanZoomEnd: (event) {
              if (_panZoomPointer == event.pointer) _endPanZoom();
            },
            onPointerHover: (e) {
              _recoverHardwareRelease(e);
              // Android can synthesize touch hover before a finger goes down.
              // It carries an absolute position, not trackpad mouse motion.
              if (e.kind != PointerDeviceKind.touch &&
                  !widget.pan &&
                  widget.active) {
                _hardwareMove(e.localPosition);
              }
            },
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && !widget.pan && widget.active) {
                GestureBinding.instance.pointerSignalResolver.register(e, (
                  event,
                ) {
                  final scroll = event as PointerScrollEvent;
                  final horizontal =
                      scroll.scrollDelta.dx.abs() > scroll.scrollDelta.dy.abs();
                  _wheelEvent(
                    horizontal ? scroll.scrollDelta.dx : -scroll.scrollDelta.dy,
                    horizontal: horizontal,
                  );
                });
              }
            },
            child: AnimatedBuilder(
              animation: widget.transform,
              builder: (context, _) => ClipRect(
                child: Transform(
                  transform: widget.transform.value,
                  child: Center(
                    child: SizedBox.fromSize(
                      size: size,
                      child: CustomPaint(
                        key: const Key('remoteCursorCanvas'),
                        foregroundPainter: _RemoteCursorPainter(
                          cursor: cursor,
                          position: _pointer! * _baseScale,
                          baseScale: _baseScale,
                          zoom: widget.transform.value.getMaxScaleOnAxis(),
                          visible:
                              widget.trackpad || (_mouseInside && !widget.pan),
                        ),
                        child: widget.session.textureId != null
                            ? Texture(
                                textureId: widget.session.textureId!,
                                freeze: !widget.active,
                                filterQuality: FilterQuality.low,
                              )
                            : RawImage(
                                image: widget.session.image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.low,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _RemoteCursorPainter extends CustomPainter {
  const _RemoteCursorPainter({
    required this.cursor,
    required this.position,
    required this.baseScale,
    required this.zoom,
    required this.visible,
  });
  final RdpCursor cursor;
  final Offset position;
  final double baseScale, zoom;
  final bool visible;
  @override
  void paint(Canvas canvas, Size size) {
    if (!visible || cursor.kind == RdpCursorKind.hidden) return;
    final image = cursor.image;
    if (cursor.kind == RdpCursorKind.bitmap && image != null) {
      final scale = math.max(
        baseScale,
        math.min(1.0, 20 / math.max(image.width, image.height)) / zoom,
      );
      final target = Rect.fromLTWH(
        position.dx - cursor.hotX * scale,
        position.dy - cursor.hotY * scale,
        image.width * scale,
        image.height * scale,
      );
      final source = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      canvas.drawImageRect(
        image,
        source,
        target,
        Paint()..filterQuality = FilterQuality.none,
      );
      // RawImage and this foreground painter share the same canvas; difference
      // blends against the real remote desktop, including translucent cursors.
      if (cursor.inversion case final mask?) {
        canvas.drawImageRect(
          mask,
          source,
          target,
          Paint()..blendMode = BlendMode.difference,
        );
      }
    } else {
      canvas.save();
      canvas.translate(position.dx, position.dy);
      canvas.scale(1 / zoom);
      const _TrackpadCursor().paint(canvas, const Size(22, 28));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_RemoteCursorPainter oldDelegate) =>
      oldDelegate.cursor != cursor ||
      oldDelegate.position != position ||
      oldDelegate.baseScale != baseScale ||
      oldDelegate.zoom != zoom ||
      oldDelegate.visible != visible;
}

class _TrackpadCursor extends CustomPainter {
  const _TrackpadCursor();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 22)
      ..lineTo(7, 17)
      ..lineTo(12, 27)
      ..lineTo(16, 25)
      ..lineTo(11, 15)
      ..lineTo(21, 15)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrackpadCursor oldDelegate) => false;
}
