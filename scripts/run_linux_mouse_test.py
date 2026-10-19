#!/usr/bin/env python3
"""OS mouse -> actual Linux main Release -> private RDP -> real X11 window.

Both displays, application data and D-Bus are disposable. No personal desktop,
credentials or external host is used. This complements the KRDP-precedence TLS
oracle in run_input_stop_test.py; the X11 shadow server itself is not KRDP.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import time
from PIL import ImageGrab
from rdp_test_desktop import Desktop

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--window-manager', type=Path, help='Optional Openbox binary for actual full-screen/restore verification')
args = parser.parse_args()
bundle = root / 'build/linux/x64/release/bundle'
out = root / 'build/linux-mouse-runtime'
out.mkdir(parents=True, exist_ok=True)
(out / 'VERDICT.json').unlink(missing_ok=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


with tempfile.TemporaryDirectory(prefix='lrdp-linux-mouse-') as temporary, ExitStack() as cleanup:
    private = Path(temporary)
    base = dict(os.environ, XDG_CONFIG_HOME=str(private / 'config'),
        XDG_DATA_HOME=str(private / 'data'), XDG_CACHE_HOME=str(private / 'cache'),
        GDK_BACKEND='x11', WAYLAND_DISPLAY='', WLOG_LEVEL='WARN')
    displays = []
    for side, size in [('client', '1440x1000'), ('server', '1280x800')]:
        number = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
        env = dict(base, DISPLAY=f':{number}')
        log = cleanup.enter_context((out / f'{side}-display.log').open('w'))
        process = subprocess.Popen(['Xvnc', env['DISPLAY'], '-geometry', size, '-depth', '24',
            '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath',
            str(private / f'{side}.sock'), '-rfbunixmode', '0600', '-nolisten', 'tcp'],
            env=env, stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, process)
        for _ in range(200):
            assert process.poll() is None
            if Path(f'/tmp/.X11-unix/X{number}').exists():
                break
            time.sleep(.05)
        else:
            raise AssertionError('Private display did not start')
        subprocess.run(['xsetroot', '-solid', '#182d28'], env=env, check=True)
        displays.append(env)
    client_env, server_env = displays
    if args.window_manager:
        manager = args.window_manager.resolve()
        assert manager.is_file()
        prefix = manager.parent.parent
        wm_env = dict(client_env, LD_LIBRARY_PATH=str(prefix/'lib'),
            XDG_DATA_DIRS=str(prefix/'share')+':/usr/share')
        log = cleanup.enter_context((out/'window-manager.log').open('w'))
        wm = subprocess.Popen([str(manager), '--sm-disable'], env=wm_env, stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, wm)
        for _ in range(100):
            assert wm.poll() is None, 'Private window manager failed'
            probe = subprocess.check_output(['xprop', '-root', '_NET_SUPPORTING_WM_CHECK'],env=client_env,text=True)
            if 'window id #' in probe: break
            time.sleep(.05)
        else: raise AssertionError('Window manager did not register')
    desktop = Desktop(server_env['DISPLAY'])
    cleanup.callback(desktop.close)
    desktop.movable_window()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    log = cleanup.enter_context((out / 'rdp-server.log').open('w'))
    server_env = dict(server_env, XDG_CONFIG_HOME=str(private / 'server-config'))
    server = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1', f'/port:{port}',
        '/sec:tls', '-auth', '+may-view', '+may-interact', '-gfx-avc420', '-gfx-avc444',
        '/log-level:WARN'], env=server_env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, server)
    for _ in range(200):
        assert server.poll() is None
        if any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
            for line in Path('/proc/net/tcp').read_text().splitlines()[1:]):
            break
        time.sleep(.05)
    else:
        raise AssertionError('Private RDP server did not start')
    profile = {'id': 'isolated-linux-mouse', 'name': 'Linux mouse test', 'host': '127.0.0.1',
        'port': port, 'username': 'fixture', 'width': 1280, 'height': 800,
        'nla': False, 'autoReconnect': False, 'rememberPassword': False}
    # Keep the pixel-based mouse oracle independent of the host's accent and
    # scheduled dark mode. Appearance has its own system/UI regression.
    preferences = {'flutter.profiles.v1': json.dumps([profile]),
        'flutter.themeMode': 'light', 'flutter.systemColors': False, 'flutter.language': 'zh-CN'}
    for application in ['dev.lrdp.lrdp', 'lrdp']:
        folder = private / 'data' / application
        folder.mkdir(parents=True)
        (folder / 'shared_preferences.json').write_text(json.dumps(preferences))
    log = cleanup.enter_context((out / 'application.log').open('w'))
    app = subprocess.Popen(['dbus-run-session', '--', str(bundle / 'lrdp')],
        cwd=private, env=client_env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, app)

    def wait_for(predicate, reason, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert app.poll() is None, 'LRDP exited'
            desktop.pump()
            if predicate():
                return
            time.sleep(.04)
        ImageGrab.grab(xdisplay=client_env['DISPLAY']).save(out / 'failure.png')
        raise AssertionError(reason)

    def os_input(*args):
        subprocess.run(['xdotool', *map(str, args)], env=client_env, check=True, timeout=10)

    def click(x, y, button=1):
        os_input('mousemove', x, y, 'mousedown', button)
        time.sleep(.08)
        os_input('mouseup', button)

    def capture(name):
        ImageGrab.grab(xdisplay=client_env['DISPLAY']).save(out / f'{name}.png')

    def dialog_action():
        # Locate the filled action inside the modal; distinguish the wider
        # certificate confirmation from the login action without timing guesses.
        image = ImageGrab.grab(xdisplay=client_env['DISPLAY']).convert('RGB')
        pixels = image.load()
        # The disconnected-session page also has a wide primary button. Only
        # accept an action when the light modal and dark outside scrim coexist.
        geometry = window_geometry()
        cx, cy = geometry['X']+geometry['WIDTH']//2, geometry['Y']+geometry['HEIGHT']//2
        if pixels[cx-140, cy-20][0] < 180 or pixels[cx-340, cy+200][0] > 180:
            return None
        points = {(x, y) for y in range(max(0,cy-300), min(image.height,cy+300)) for x in range(max(0,cx-300), min(image.width,cx+300))
            if (color := pixels[x, y])[0] < 60 and 70 < color[1] < 140 and
                50 < color[2] < 120 and color[1] > color[0] * 1.5 and color[2] > color[0] * 1.2}
        candidates = []
        while points:
            todo = [points.pop()]; component = []
            while todo:
                x, y = todo.pop(); component.append((x, y))
                for neighbor in [(x-1, y), (x+1, y), (x, y-1), (x, y+1)]:
                    if neighbor in points:
                        points.remove(neighbor); todo.append(neighbor)
            left = min(p[0] for p in component); right = max(p[0] for p in component)
            top = min(p[1] for p in component); bottom = max(p[1] for p in component)
            if right-left >= 50 and bottom-top >= 24 and len(component) > (right-left)*(bottom-top)*.45:
                candidates.append([left, (top+bottom)//2, right])
        if not candidates or pixels[300, 700][0] > 180:
            return None
        return max(candidates, key=lambda value: value[1])

    def wait_action(wide=False):
        action = None
        def ready():
            nonlocal action
            action = dialog_action()
            return action is not None and (not wide or action[2]-action[0] > 120)
        wait_for(ready, 'Expected modal action did not paint', timeout=45)
        return action

    wait_for(lambda: len(ImageGrab.grab(xdisplay=client_env['DISPLAY']).resize((100, 100)).getcolors(10001)) > 20,
        'Main Release did not paint its workspace', timeout=40)
    windows = subprocess.check_output(['xdotool', 'search', '--name', '^LRDP$'],
        env=client_env, text=True).splitlines()
    assert windows
    def window_geometry():
        output = subprocess.check_output(['xdotool', 'getwindowgeometry', '--shell', windows[-1]],env=client_env,text=True)
        return {key:int(value) for line in output.splitlines() if '=' in line for key,value in [line.split('=',1)]}
    def window_fullscreen():
        return '_NET_WM_STATE_FULLSCREEN' in subprocess.check_output(
            ['xprop','-id',windows[-1],'_NET_WM_STATE'],env=client_env,text=True)
    os_input('windowfocus', windows[-1])
    # Fixed 1280x840 default window, private 1440x1000 screen, scale 1. These
    # clicks exercise the real customer UI, including temporary certificate trust.
    capture('workspace')
    initial_geometry = window_geometry()
    click(initial_geometry['X']+1158, initial_geometry['Y']+545)
    wait_action()
    time.sleep(.3)
    capture('login')
    action = wait_action()
    print('Login action', action, flush=True)
    click((action[0] + action[2]) // 2, action[1])
    wait_action(wide=True)
    time.sleep(.3)
    capture('certificate')
    action = wait_action(wide=True)
    print('Certificate action', action, flush=True)
    click((action[0] + action[2]) // 2, action[1])
    time.sleep(1)
    capture('connected')
    if args.window_manager:
        wait_for(lambda: window_fullscreen() and window_geometry()['WIDTH']==1440 and window_geometry()['HEIGHT']==1000,
            'Session did not enter actual OS full screen')

    # Locate the fitted remote desktop from its known synthetic window header.
    # Do not infer acceptance just from the existence of a native process.
    def viewport():
        image = ImageGrab.grab(xdisplay=client_env['DISPLAY']).convert('RGB')
        pixels = image.load()
        # Restrict to the remote area: antialiased toolbar text can contain the
        # same color as this deliberately plain synthetic window header.
        points = [(x, y) for y in range(image.height) for x in range(image.width)
            if all(abs(pixels[x, y][i] - (127, 187, 168)[i]) <= 4 for i in range(3))]
        if len(points) < 100:
            return None
        left = min(p[0] for p in points)
        top = min(p[1] for p in points)
        right = max(p[0] for p in points)
        scale = (right - left + 1) / 400
        return [left - 80 * scale, top - 80 * scale, scale]

    layout = None
    def ready():
        global layout
        layout = viewport()
        return layout is not None
    wait_for(ready, 'Customer UI did not connect to the private desktop')
    print('Remote viewport', layout, flush=True)

    def move(x, y):
        os_input('mousemove', round(layout[0] + x * layout[2]), round(layout[1] + y * layout[2]))

    move(100, 95)
    os_input('mousedown', 1)
    wait_for(lambda: desktop.dragging, 'Remote window did not start dragging')
    for x, y in [(140, 115), (180, 135), (220, 155)]:
        move(x, y)
        wait_for(lambda: abs(desktop.pointer()['x'] - x) <= 1, 'Drag motion missing')
    os_input('mouseup', 1)
    wait_for(lambda: not desktop.dragging and desktop.pointer()['mask'] & 0x700 == 0,
        'Mouse stayed held after dragging')
    dragged = desktop.geometry()
    assert abs(dragged[0] - 200) <= 2 and abs(dragged[1] - 140) <= 2, dragged
    move(260, 240)
    wait_for(lambda: abs(desktop.pointer()['x'] - 260) <= 1, 'Hover missing after release')
    assert desktop.geometry() == dragged, 'Window continued moving after release'
    for button, x in [(1, 260), (3, 280), (2, 300)]:
        start = len(desktop.events)
        move(x, 240)
        os_input('click', button)
        wait_for(lambda: sum(e['type'] in (4, 5) for e in desktop.events[start:]) == 2,
            'Follow-up click missing')
        events = [e for e in desktop.events[start:] if e['type'] in (4, 5)]
        assert [(e['type'], e['button']) for e in events] == [(4, button), (5, button)], events
        assert all(abs(e['x'] - x) <= 1 and abs(e['y'] - 240) <= 1 for e in events), events
    # Real GTK multi-button stream: the first release is a PointerMoveEvent in
    # Flutter while the other button is still held.
    move(320, 240)
    os_input('mousedown', 1, 'mousedown', 3)
    wait_for(lambda: desktop.pointer()['mask'] & 0x500 == 0x500, 'Chord did not press both buttons')
    os_input('mouseup', 1)
    wait_for(lambda: desktop.pointer()['mask'] & 0x700 == 0x400,
        'Intermediate left release missing while right remains down')
    os_input('mouseup', 3)
    wait_for(lambda: desktop.pointer()['mask'] & 0x700 == 0, 'Final right release missing')
    move(340, 240)
    os_input('key', 'Escape', 'click', 1)
    wait_for(lambda: any(e['type'] == 5 and e['button'] == 1 and abs(e['x'] - 340) <= 1
        for e in desktop.events), 'Click after Escape did not work')
    capture('passed')
    fullscreen_case = []
    if args.window_manager:
        # First floating action is Back to computers. The panel has seven 68px
        # actions, a 52px drag header and an 8px margin on this 1440x1000 screen.
        click(1440-340-8+68, 8+52+1+6+32)
        wait_for(lambda: not window_fullscreen() and window_geometry()['WIDTH']==initial_geometry['WIDTH']
            and window_geometry()['HEIGHT']==initial_geometry['HEIGHT'], 'Leaving the session did not restore the OS window')
        capture('window-restored')
        fullscreen_case = ['actual OS full screen and original window size restored through floating Back action']
    (out / 'events.json').write_text(json.dumps(desktop.events, indent=2) + '\n')
    report = {'passed': True, 'entrypoint': 'lib/main.dart Linux Release', 'backend': 'GTK/X11',
        'native_abi': 5, 'library_sha256': hashlib.sha256((bundle / 'lib/liblrdp.so').read_bytes()).hexdigest(),
        'aot_sha256': hashlib.sha256((bundle / 'lib/libapp.so').read_bytes()).hexdigest(),
        'plugin_sha256': hashlib.sha256((bundle / 'lib/liblrdp_native_plugin.so').read_bytes()).hexdigest(),
        'window_after_drag': dragged, 'pointer_after_tests': desktop.pointer(),
        'cases': ['actual X11 window drag/release', 'no window movement after release',
            'subsequent left/right/middle click', 'stationary multi-button release', 'click after Escape']+fullscreen_case,
        'os_fullscreen_verified': bool(args.window_manager),
        'scope': 'private X11 shadow server; KRDP event precedence verified separately; no external host'}
    (out / 'VERDICT.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: Linux main Release, OS mouse drag/release, follow-up clicks and multi-button state')
