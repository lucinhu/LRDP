"""Private X11 input oracle shared by desktop and Android OS tests."""
import ctypes as c


class MouseEvent(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
        ('display', c.c_void_p), ('window', c.c_ulong), ('root', c.c_ulong),
        ('subwindow', c.c_ulong), ('time', c.c_ulong), ('x', c.c_int), ('y', c.c_int),
        ('x_root', c.c_int), ('y_root', c.c_int), ('state', c.c_uint),
        ('button', c.c_uint), ('same_screen', c.c_int)]


class Event(c.Union):
    _fields_ = [('type', c.c_int), ('mouse', MouseEvent), ('pad', c.c_long * 24)]


class Desktop:
    def __init__(self, display):
        self.x = c.CDLL('libX11.so.6')
        self.display = self.fn('XOpenDisplay', c.c_void_p, c.c_char_p)(display.encode())
        assert self.display
        self.root = self.fn('XDefaultRootWindow', c.c_ulong, c.c_void_p)(self.display)
        self.events = []
        self.keys = []
        self.double_clicks = 0
        self.detect_double_clicks = False
        self.last_press = None
        self.dragging = False
        self.position = (80, 80)
        self.window = None

    def fn(self, name, result, *args):
        f = getattr(self.x, name)
        f.restype, f.argtypes = result, list(args)
        return f

    def movable_window(self):
        self.window = self.fn('XCreateSimpleWindow', c.c_ulong, c.c_void_p,
            c.c_ulong, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_uint, c.c_ulong,
            c.c_ulong)(self.display, self.root, 80, 80, 400, 300, 0, 0, 0x31564c)
        self.fn('XStoreName', c.c_int, c.c_void_p, c.c_ulong, c.c_char_p)(
            self.display, self.window, b'LRDP isolated drag target')
        self.fn('XSelectInput', c.c_int, c.c_void_p, c.c_ulong, c.c_long)(
            self.display, self.window, 1 | 2 | 4 | 8 | 64 | (1 << 15))
        self.fn('XMapWindow', c.c_int, c.c_void_p, c.c_ulong)(self.display, self.window)
        self.paint()
        self.fn('XSetInputFocus', c.c_int, c.c_void_p, c.c_ulong, c.c_int,
            c.c_ulong)(self.display, self.window, 1, 0)
        self.sync()

    def paint(self):
        gc = self.fn('XCreateGC', c.c_void_p, c.c_void_p, c.c_ulong,
            c.c_ulong, c.c_void_p)(self.display, self.window, 0, None)
        self.fn('XSetForeground', c.c_int, c.c_void_p, c.c_void_p, c.c_ulong)(
            self.display, gc, 0x7fbba8)
        self.fn('XFillRectangle', c.c_int, c.c_void_p, c.c_ulong, c.c_void_p,
            c.c_int, c.c_int, c.c_uint, c.c_uint)(
                self.display, self.window, gc, 0, 0, 400, 32)
        self.fn('XFreeGC', c.c_int, c.c_void_p, c.c_void_p)(self.display, gc)
        self.sync()

    def sync(self):
        self.fn('XSync', c.c_int, c.c_void_p, c.c_int)(self.display, 0)

    def pump(self):
        self.sync()
        pending = self.fn('XPending', c.c_int, c.c_void_p)
        next_event = self.fn('XNextEvent', c.c_int, c.c_void_p, c.POINTER(Event))
        while pending(self.display):
            event = Event()
            next_event(self.display, c.byref(event))
            e = event.mouse
            if event.type == 12:
                self.paint()
            elif event.type in (2, 3):
                text = c.create_string_buffer(64)
                symbol = c.c_ulong()
                size = self.fn('XLookupString', c.c_int, c.POINTER(MouseEvent),
                    c.c_char_p, c.c_int, c.POINTER(c.c_ulong), c.c_void_p)(
                        c.byref(e), text, 64, c.byref(symbol), None)
                self.keys.append({'type': event.type, 'symbol': symbol.value,
                    'text': text.raw[:size].decode('utf-8', errors='replace'), 'state': e.state})
            elif event.type in (4, 5, 6):
                self.events.append({'type': event.type, 'button': e.button if event.type != 6 else None,
                    'x': e.x_root, 'y': e.y_root, 'state': e.state})
                if event.type == 4 and e.button == 1 and e.y < 32:
                    if self.detect_double_clicks and self.last_press is not None:
                        stamp, x, y = self.last_press
                        if e.time - stamp < 500 and abs(e.x_root-x) < 8 and abs(e.y_root-y) < 8:
                            self.double_clicks += 1
                            self.last_press = None
                            self.dragging = False
                            continue
                    self.last_press = (e.time, e.x_root, e.y_root)
                    self.dragging = True
                    self.anchor = (e.x_root - self.position[0], e.y_root - self.position[1])
                elif event.type == 5 and e.button == 1:
                    self.dragging = False
                elif event.type == 6 and self.dragging:
                    self.position = (e.x_root - self.anchor[0], e.y_root - self.anchor[1])
                    self.fn('XMoveWindow', c.c_int, c.c_void_p, c.c_ulong, c.c_int, c.c_int)(
                        self.display, self.window, *self.position)
        self.sync()

    def pointer(self):
        returned_root, child = c.c_ulong(), c.c_ulong()
        coords = [c.c_int() for _ in range(4)]
        mask = c.c_uint()
        assert self.fn('XQueryPointer', c.c_int, c.c_void_p, c.c_ulong,
            c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_int),
            c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_uint))(
                self.display, self.root, c.byref(returned_root), c.byref(child),
                *(c.byref(value) for value in coords), c.byref(mask))
        return {'x': coords[0].value, 'y': coords[1].value, 'mask': mask.value}

    def geometry(self):
        returned_root = c.c_ulong()
        x, y = c.c_int(), c.c_int()
        values = [c.c_uint() for _ in range(4)]
        assert self.fn('XGetGeometry', c.c_int, c.c_void_p, c.c_ulong,
            c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_int),
            *([c.POINTER(c.c_uint)] * 4))(
                self.display, self.window, c.byref(returned_root), c.byref(x), c.byref(y),
                *(c.byref(value) for value in values))
        return [x.value, y.value, values[0].value, values[1].value]

    def close(self):
        self.fn('XCloseDisplay', c.c_int, c.c_void_p)(self.display)
