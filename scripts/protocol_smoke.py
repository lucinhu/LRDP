#!/usr/bin/env python3
"""Real TLS/RDP loopback test; requires a private shadow server on 127.0.0.1.

Run scripts/run_protocol_test.sh. Never points at the user's desktop.
"""
import ctypes as c
import os
import subprocess
import sys
import time

lib = c.CDLL(sys.argv[1])
lib.lrdp_abi_version.restype = c.c_int
assert lib.lrdp_abi_version() == 5, "Build the ABI v5 native bridge"
lib.lrdp_create.restype = c.c_void_p
lib.lrdp_set.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
lib.lrdp_start.argtypes = [c.c_void_p]
lib.lrdp_state.argtypes = [c.c_void_p]
lib.lrdp_end_reason.argtypes = [c.c_void_p]
lib.lrdp_features.argtypes = [c.c_void_p]
lib.lrdp_read.argtypes = [c.c_void_p, c.c_int, c.c_void_p, c.c_size_t]
lib.lrdp_stop.argtypes = [c.c_void_p]
lib.lrdp_destroy.argtypes = [c.c_void_p]
lib.lrdp_input.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_int]
lib.lrdp_frame.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_int32), c.POINTER(c.c_int32), c.POINTER(c.c_uint64)]

def read(s, field):
    out = c.create_string_buffer(4096)
    n = lib.lrdp_read(s, field, out, len(out))
    return out.value.decode() if n >= 0 else ''

def connect(fingerprint=''):
    s = lib.lrdp_create()
    assert s, 'native allocation failed'
    try:
        for k, v in dict(host='127.0.0.1', port=os.environ.get('LRDP_TEST_PORT', '33991'),
                         username='test', password='', nla='0', width='1280', height='800',
                         fingerprint=fingerprint).items():
            assert lib.lrdp_set(s, k.encode(), v.encode()), k
        assert lib.lrdp_start(s)
        deadline = time.monotonic() + 15
        while lib.lrdp_state(s) == 1 and time.monotonic() < deadline:
            time.sleep(.02)
        return s
    except BaseException:
        lib.lrdp_destroy(s)
        raise

s = connect()
try:
    assert lib.lrdp_state(s) == 5, (lib.lrdp_state(s), read(s, 0))
    assert lib.lrdp_end_reason(s) == 4, 'Untrusted certificate must not be retryable'
    fingerprint = read(s, 1)
    assert len(fingerprint.replace(':', '')) == 64, fingerprint
    print('PASS: untrusted certificate rejected, SHA-256 fingerprint returned', flush=True)
finally:
    lib.lrdp_destroy(s)

s = connect('00:' * 31 + '00')
try:
    assert lib.lrdp_state(s) == 5, (lib.lrdp_state(s), read(s, 0))
    print('PASS: wrong certificate pin rejected', flush=True)
finally:
    lib.lrdp_destroy(s)

s = connect(fingerprint)
try:
    assert lib.lrdp_state(s) == 2, (lib.lrdp_state(s), read(s, 0))
    w, h, gen = c.c_int32(), c.c_int32(), c.c_uint64()
    data = c.create_string_buffer(4096 * 4096 * 4)
    def frame(timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            n = lib.lrdp_frame(s, data, len(data), c.byref(w), c.byref(h), c.byref(gen))
            if n > 0: return bytes(data.raw[:n])
            assert lib.lrdp_state(s) == 2, read(s, 0)
            time.sleep(.05)
        raise AssertionError('No decoded RDP frame')
    def frame_with_color(bgra, timeout=10):
        deadline = time.monotonic() + timeout
        actual = None
        actual = None
        while time.monotonic() < deadline:
            try:
                pixels = frame(timeout=max(.1, deadline - time.monotonic()))
            except AssertionError as error:
                raise AssertionError(f'Expected BGRA {bgra}; last={actual}; {error}') from error
            center = (400 * w.value + 640) * 4
            actual = list(pixels[center:center + 4])
            # Negotiated RDP image codecs may quantize color channels. Keep
            # alpha exact and require the actual server palette, not a blank.
            # Some shadow-server builds advertise AVC despite their -gfx flags.
            # Use the client's observed decode feature, rather than assuming
            # that the requested server configuration is the negotiated codec.
            tolerance = 4 if lib.lrdp_features(s) & 4 else 2
            if all(abs(actual[i] - bgra[i]) <= tolerance for i in range(3)) and actual[3] == bgra[3]:
                return pixels
        raise AssertionError(f'No real server frame with BGRA color {bgra}; last={actual}')
    pixels = frame_with_color([0x28, 0x2d, 0x18, 0xff])
    assert w.value == 1280 and h.value == 800, (w.value, h.value)
    assert len(pixels) == 1280 * 800 * 4
    print(f'PASS: TLS connection, GDI frame {w.value}x{h.value}, {len(pixels)} bytes', flush=True)
    # Change only the isolated X server to prove this is live decoded graphics.
    subprocess.run(['xsetroot', '-solid', '#2a8465'], check=True)
    changed = frame_with_color([0x65, 0x84, 0x2a, 0xff])
    assert pixels != changed, 'Frame pixels did not change'
    assert lib.lrdp_input(s, 0, 0x800, 200, 200)
    assert lib.lrdp_input(s, 1, 0, 0x1e, 0)
    assert lib.lrdp_input(s, 1, 0x8000, 0x1e, 0)
    print('PASS: live graphics update and input queue', flush=True)
    # Observe events on the private X server, not just successful queue writes.
    x11 = c.CDLL('libX11.so.6')
    def xfn(name, result, *args):
        fn = getattr(x11, name); fn.restype = result; fn.argtypes = list(args); return fn
    display = xfn('XOpenDisplay', c.c_void_p, c.c_char_p)(None)
    assert display, 'Cannot open private X display'
    root = xfn('XDefaultRootWindow', c.c_ulong, c.c_void_p)(display)
    window = xfn('XCreateSimpleWindow', c.c_ulong, c.c_void_p, c.c_ulong,
        c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_uint, c.c_ulong, c.c_ulong)(
        display, root, 40, 40, 400, 300, 0, 0, 0x2a8465)
    class XKeyEvent(c.Structure):
        _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
            ('display', c.c_void_p), ('window', c.c_ulong), ('root', c.c_ulong),
            ('subwindow', c.c_ulong), ('time', c.c_ulong), ('x', c.c_int), ('y', c.c_int),
            ('x_root', c.c_int), ('y_root', c.c_int), ('state', c.c_uint),
            ('keycode', c.c_uint), ('same_screen', c.c_int)]
    class XEvent(c.Union):
        _fields_ = [('type', c.c_int), ('key', XKeyEvent), ('pad', c.c_long * 24)]
    try:
        xfn('XSelectInput', c.c_int, c.c_void_p, c.c_ulong, c.c_long)(display, window, 15 | (1 << 6))
        xfn('XMapWindow', c.c_int, c.c_void_p, c.c_ulong)(display, window)
        sync = xfn('XSync', c.c_int, c.c_void_p, c.c_int)
        sync(display, 0)
        xfn('XSetInputFocus', c.c_int, c.c_void_p, c.c_ulong, c.c_int, c.c_ulong)(display, window, 2, 0)
        sync(display, 0)
        expected_key = xfn('XKeysymToKeycode', c.c_ubyte, c.c_void_p, c.c_ulong)(display, 0x61)
        assert lib.lrdp_input(s, 1, 0, 0x1e, 0)
        assert lib.lrdp_input(s, 1, 0x8000, 0x1e, 0)
        assert lib.lrdp_input(s, 0, 0x9000, 100, 100)
        assert lib.lrdp_input(s, 0, 0x1000, 100, 100)
        pending = xfn('XPending', c.c_int, c.c_void_p)
        next_event = xfn('XNextEvent', c.c_int, c.c_void_p, c.POINTER(XEvent))
        seen = set(); deadline = time.monotonic() + 5
        while time.monotonic() < deadline and seen != {2, 3, 4, 5}:
            while pending(display):
                event = XEvent(); next_event(display, c.byref(event))
                if event.type in (2, 3) and event.key.keycode == expected_key:
                    seen.add(event.type)
                elif event.type in (4, 5) and event.key.keycode == 1:
                    seen.add(event.type)
            time.sleep(.02)
        assert seen == {2, 3, 4, 5}, f'Missing actual remote events: {seen}'
        print('PASS: server delivered actual keyboard press/release and mouse click', flush=True)
        while pending(display):
            event = XEvent(); next_event(display, c.byref(event))
        # These are the exact right-button/wheel/drag flags emitted by the
        # touch surface. Verify delivery on the real private server desktop.
        for flags in (0xa800, 0x2800, 0x0200 | 0x0100 | (512 - 120),
                      0x0200 | 120, 0x0400 | 120, 0x0400 | 0x0100 | (512 - 120), 0x9800):
            assert lib.lrdp_input(s, 0, flags, 100, 100)
        assert lib.lrdp_input(s, 0, 0x0800, 240, 180)
        assert lib.lrdp_input(s, 0, 0x1800, 240, 180)
        expected_buttons = [(kind, button) for button in (3, 5, 4, 6, 7, 1) for kind in (4, 5)]
        buttons = []; drag_motion = False; right_at_target = False; release_at_target = False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (len(buttons) < len(expected_buttons) or not drag_motion):
            while pending(display):
                event = XEvent(); next_event(display, c.byref(event))
                if event.type in (4, 5): buttons.append((event.type, event.key.keycode))
                if event.type == 4 and event.key.keycode == 3:
                    right_at_target = (event.key.x_root, event.key.y_root) == (100, 100)
                if event.type == 5 and event.key.keycode == 1:
                    release_at_target = (event.key.x_root, event.key.y_root) == (240, 180)
                if event.type == 6 and event.key.state & (1 << 8):
                    drag_motion |= (event.key.x_root, event.key.y_root) == (240, 180)
            time.sleep(.02)
        assert buttons == expected_buttons, f'Actual right/wheel/drag button events: {buttons}'
        assert drag_motion, 'Missing remote motion with left button held at target coordinates'
        assert right_at_target and release_at_target, 'Remote click/release occurred at the wrong coordinates'
        print('PASS: actual remote right click, vertical/horizontal wheel in both directions and held-button drag/release', flush=True)
        query = xfn('XQueryPointer', c.c_int, c.c_void_p, c.c_ulong,
            c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_int),
            c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_uint))
        def pointer_mask():
            roots, child = c.c_ulong(), c.c_ulong()
            coords = [c.c_int() for _ in range(4)]; mask = c.c_uint()
            assert query(display, root, c.byref(roots), c.byref(child),
                *(c.byref(value) for value in coords), c.byref(mask))
            return mask.value
        assert lib.lrdp_input(s, 1, 0, 0x1d, 0)  # Ctrl down, without a matching up.
        assert lib.lrdp_input(s, 0, 0x9800, 240, 180)
        deadline = time.monotonic() + 5
        while pointer_mask() & 0x104 != 0x104 and time.monotonic() < deadline:
            time.sleep(.02)
        assert pointer_mask() & 0x104 == 0x104, 'Server did not receive held Ctrl and left button'
        lib.lrdp_stop(s)
        deadline = time.monotonic() + 5
        while (pointer_mask() & 0x104 or lib.lrdp_state(s) != 3) and time.monotonic() < deadline:
            time.sleep(.02)
        assert pointer_mask() & 0x104 == 0, f'Orderly stop left remote Ctrl/mouse held: mask={pointer_mask():#x}'
        assert lib.lrdp_state(s) == 3
        print('PASS: orderly stop releases actual remote Ctrl and held mouse button', flush=True)
    finally:
        xfn('XDestroyWindow', c.c_int, c.c_void_p, c.c_ulong)(display, window)
        xfn('XCloseDisplay', c.c_int, c.c_void_p)(display)

finally:
    lib.lrdp_stop(s)
    lib.lrdp_destroy(s)
print('PASS: deterministic stop and native resource release', flush=True)
