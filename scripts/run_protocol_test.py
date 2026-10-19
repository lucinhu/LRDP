#!/usr/bin/env python3
"""Launch a private virtual desktop and RDP server and always clean up.

Requires Xvnc, freerdp-shadow-cli3, xsetroot and Python 3 on Linux.
Uses a Unix socket for VNC and loopback TCP for RDP. No user desktop access.
"""
from contextlib import ExitStack
from pathlib import Path
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
arguments = [arg for arg in sys.argv[1:] if arg not in ('--flutter', '--nla', '--auth-ui', '--avc', '--ui', '--release', '--live-ui', '--phone-ui', '--recovery')]
library = Path(arguments[0]).resolve() if arguments else root / 'build/native/liblrdp.so'
for tool in (['Xvnc', 'xsetroot'] if '--ui' in sys.argv or '--release' in sys.argv else ['Xvnc', 'freerdp-shadow-cli3', 'xsetroot']):
    if not shutil.which(tool): sys.exit(f'Missing test dependency: {tool}')
if not {'--ui', '--release'}.intersection(sys.argv) and not library.is_file(): sys.exit(f'Build the native bridge first: {library}')
if '--release' in sys.argv and not shutil.which('xprop'): sys.exit('Missing test dependency: xprop')

def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()

with tempfile.TemporaryDirectory(prefix='lrdp-test-') as temp, ExitStack() as cleanup:
    env = dict(os.environ, XDG_CONFIG_HOME=temp)
    display = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
    env['DISPLAY'] = f':{display}'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    env['LRDP_TEST_PORT'] = str(port)
    logs = root / 'build/protocol-logs'; logs.mkdir(parents=True, exist_ok=True)
    display_log = cleanup.enter_context((logs / 'display.log').open('w'))
    server_log = cleanup.enter_context((logs / 'server.log').open('w'))
    desktop = subprocess.Popen(['Xvnc', env['DISPLAY'], '-geometry', '1440x1000' if '--release' in sys.argv else '1280x800', '-depth', '24',
        '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath', f'{temp}/vnc.sock',
        '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=env, stdout=display_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, desktop)
    for _ in range(100):
        if Path(f'/tmp/.X11-unix/X{display}').exists(): break
        if desktop.poll() is not None: sys.exit('Private desktop failed; see build/protocol-logs/display.log')
        time.sleep(.05)
    subprocess.run(['xsetroot', '-solid', '#182d28'], env=env, check=True)
    if '--release' in sys.argv:
        # Exercise the actual release main(), including path_provider and the
        # registered platform plugins, under private XDG directories and X server.
        import ctypes as c
        from PIL import ImageGrab
        env.update(GDK_BACKEND='x11', XDG_DATA_HOME=f'{temp}/data', XDG_CACHE_HOME=f'{temp}/cache')
        release_log = cleanup.enter_context((root / 'build/release-startup.log').open('w'))
        application = subprocess.Popen([str(root / 'build/linux/x64/release/bundle/lrdp')], cwd=temp,
            env=env, stdout=release_log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, application)
        x11 = c.CDLL('libX11.so.6')
        x11.XOpenDisplay.argtypes = [c.c_char_p]; x11.XOpenDisplay.restype = c.c_void_p
        x11.XDefaultRootWindow.argtypes = [c.c_void_p]; x11.XDefaultRootWindow.restype = c.c_ulong
        x11.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
        x11.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_char_p)]
        x11.XFree.argtypes = [c.c_void_p]; x11.XCloseDisplay.argtypes = [c.c_void_p]
        connection = x11.XOpenDisplay(env['DISPLAY'].encode()); assert connection
        cleanup.callback(x11.XCloseDisplay, connection)
        root_window = x11.XDefaultRootWindow(connection)
        found = False
        window_id = None
        for _ in range(200):
            if application.poll() is not None: break
            parent, root_return, count = c.c_ulong(), c.c_ulong(), c.c_uint()
            children = c.POINTER(c.c_ulong)()
            if x11.XQueryTree(connection, root_window, c.byref(root_return), c.byref(parent), c.byref(children), c.byref(count)):
                for i in range(count.value):
                    name = c.c_char_p()
                    if x11.XFetchName(connection, children[i], c.byref(name)) and name:
                        if name.value == b'LRDP':
                            found = True
                            window_id = children[i]
                        x11.XFree(name)
                if children: x11.XFree(children)
            if found: break
            time.sleep(.05)
        assert found, 'Release did not open its LRDP window; see build/release-startup.log'
        # Check the actual X11 window property, not just the source asset.
        import re
        from PIL import Image
        icon_property = subprocess.check_output([
            'xprop', '-id', str(window_id), '-notype', '-f', '_NET_WM_ICON', '32c',
            '_NET_WM_ICON'], env=env, text=True)
        assert '=' in icon_property, 'Release window has no icon'
        values = [int(value) for value in re.findall(r'\d+', icon_property.split('=', 1)[1])]
        icon = Image.open(root / 'assets/branding/lrdp-128.png').convert('RGBA')
        pixels = icon.tobytes()
        expected = [(pixels[i+3] << 24) | (pixels[i] << 16) | (pixels[i+1] << 8) | pixels[i+2]
                    for i in range(0, len(pixels), 4)]
        assert values == [*icon.size, *expected], 'Window icon differs from LRDP artwork'
        print('PASS: actual Linux window icon matches all 128 x 128 LRDP pixels')
        # Poll for the painted first frame. A fixed short delay is flaky while
        # other native builds are loading the machine and shader cache is cold.
        painted = False
        for _ in range(150):
            assert application.poll() is None, 'Release exited during startup'
            capture = ImageGrab.grab(xdisplay=env['DISPLAY'])
            if len(capture.resize((100, 100)).getcolors(10001)) > 20:
                painted = True; break
            time.sleep(.2)
        screenshot = root / 'build/release-startup.png'; capture.save(screenshot)
        assert painted, 'Release window did not draw within 30 seconds'
        release_log.flush()
        output = (root / 'build/release-startup.log').read_text()
        assert 'Unhandled Exception' not in output and 'ERROR:flutter/runtime' not in output, output
        print('PASS: actual Linux release startup, private storage initialization and rendered window')
        sys.exit(0)
    if '--ui' in sys.argv:
        env['GDK_BACKEND'] = 'x11'
        env['LRDP_PROJECT_ROOT'] = str(root)
        result = subprocess.run(['flutter', 'test', 'integration_test/workspace_test.dart',
            '-d', 'linux', '--no-pub'], cwd=root, env=env)
        sys.exit(result.returncode)
    security = ['/sec:tls', '-auth']
    if {'--nla', '--auth-ui'}.intersection(sys.argv):
        # SAM format is user:domain:LM-hash:NT-hash:. This is a disposable test
        # identity, separate from the machine's user accounts.
        digest = subprocess.run(['openssl', 'dgst', '-md4', '-provider', 'legacy'],
            input='LRDP-test-password-2026'.encode('utf-16le'), capture_output=True, check=True)
        nt_hash = digest.stdout.decode().strip().split()[-1]
        domain = 'LRDPTEST' if '--auth-ui' in sys.argv else ''
        sam = Path(temp) / 'SAM'; sam.write_text(f'lrdptest:{domain}::{nt_hash}:\n'); sam.chmod(0o600)
        security = ['/sec:nla', f'/sam-file:{sam}']
    server = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1', f'/port:{port}',
        *security, '+may-view', '+may-interact',
        '+gfx-avc420' if '--avc' in sys.argv else '-gfx-avc420', '-gfx-avc444',
        '/log-level:WARN'], env=env, stdout=server_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, server)
    # Inspect the kernel's listener table without starting an incomplete RDP
    # handshake. Startup can take longer on loaded builders (especially NLA).
    ready = False
    for _ in range(200):
        if server.poll() is not None: break
        for entry in Path('/proc/net/tcp').read_text().splitlines()[1:]:
            columns = entry.split()
            if columns[1] == f'0100007F:{port:04X}' and columns[3] == '0A': ready = True
        if ready: break
        time.sleep(.05)
    if not ready: sys.exit('RDP server did not listen; see build/protocol-logs/server.log')
    subprocess.run(['xsetroot', '-solid', '#182d28'], env=env, check=True)
    if '--recovery' in sys.argv:
        import json
        import select
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); alternate_port = sock.getsockname()[1]
        alternate_config = Path(temp) / 'alternate'; alternate_config.mkdir()
        alternate_log = cleanup.enter_context((logs / 'alternate-server.log').open('w'))
        alternate = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1',
            f'/port:{alternate_port}', '/sec:tls', '-auth', '+may-view', '+may-interact',
            '-gfx-avc420', '-gfx-avc444', '/log-level:WARN'],
            env=dict(env, XDG_CONFIG_HOME=str(alternate_config)),
            stdout=alternate_log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, alternate)
        for _ in range(200):
            if alternate.poll() is not None: sys.exit('Alternate server failed')
            if any(line.split()[1] == f'0100007F:{alternate_port:04X}' and line.split()[3] == '0A'
                   for line in Path('/proc/net/tcp').read_text().splitlines()[1:]): break
            time.sleep(.05)
        else: sys.exit('Alternate server did not listen')
        control = str(Path(temp) / 'fault-control.sock')
        proxy_log = cleanup.enter_context((logs / 'proxy.log').open('w'))
        proxy = subprocess.Popen([sys.executable, str(root / 'scripts/recovery_proxy.py'),
            '--port', str(port), '--alternate-port', str(alternate_port), '--control', control],
            stdout=subprocess.PIPE, stderr=proxy_log, text=True)
        cleanup.callback(stop, proxy)
        assert select.select([proxy.stdout], [], [], 10)[0], 'Proxy startup timed out'
        response = proxy.stdout.readline()
        assert response, 'Proxy failed; see proxy.log'
        env.update(LRDP_TEST_PORT=str(json.loads(response)['port']),
                   LRDP_RECOVERY_CONTROL=control, LRDP_NATIVE_LIBRARY=str(library))
        result = subprocess.run(['flutter', 'test', 'test/session_recovery_protocol_test.dart',
            '--reporter', 'expanded', '--no-pub'], cwd=root, env=env)
    elif {'--live-ui', '--phone-ui'}.intersection(sys.argv):
        # The client has a second private display so it cannot capture itself
        # recursively through the shadow server's desktop.
        client_display = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
        client_env = dict(env, DISPLAY=f':{client_display}', GDK_BACKEND='x11', LRDP_PROJECT_ROOT=str(root))
        client_env.pop('LRDP_NATIVE_LIBRARY', None)
        client_env['LRDP_DISABLE_TEXTURES'] = '1'  # This suite captures Dart images; native pixels have separate OS screenshot coverage.
        if '--phone-ui' in sys.argv: client_env['LRDP_PHONE_UI'] = '1'
        client_log = cleanup.enter_context((logs / 'client-display.log').open('w'))
        client_desktop = subprocess.Popen(['Xvnc', client_env['DISPLAY'], '-geometry', '1280x900', '-depth', '24',
            '-SecurityTypes', 'None', '-rfbport', '-1', '-rfbunixpath', f'{temp}/client-vnc.sock',
            '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=client_env, stdout=client_log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, client_desktop)
        for _ in range(100):
            if Path(f'/tmp/.X11-unix/X{client_display}').exists(): break
            if client_desktop.poll() is not None: sys.exit('Private client display failed')
            time.sleep(.05)
        result = subprocess.run(['flutter', 'test', 'integration_test/connection_test.dart', '-d', 'linux', '--no-pub'], cwd=root, env=client_env)
    elif '--avc' in sys.argv:
        import hashlib
        import json
        env['LRDP_NATIVE_LIBRARY'] = str(library)
        env['WLOG_FILTER'] = 'com.freerdp.channels.rdpgfx.client:DEBUG'
        env['LRDP_TEST_CODEC'] = 'avc420'
        mode = 'flutter' if '--flutter' in sys.argv else 'native'
        if arguments:
            mode += '-release' if library.parent == root / 'build/linux/x64/release/bundle/lib' else '-custom'
        output = root / 'build/avc-runtime' / mode
        output.mkdir(parents=True, exist_ok=True)
        (output / 'VERDICT.json').unlink(missing_ok=True)
        wire = output / 'wire.log'
        wire.unlink(missing_ok=True)
        env.update(WLOG_APPENDER='FILE', WLOG_FILEAPPENDER_OUTPUT_FILE_PATH=str(output),
            WLOG_FILEAPPENDER_OUTPUT_FILE_NAME=wire.name, LRDP_AVC_WIRE_LOG=str(wire))
        client_log = cleanup.enter_context((output / 'client.log').open('w'))
        command = (['flutter', 'test', 'test/rdp_session_test.dart', '--reporter', 'expanded', '--no-pub']
            if '--flutter' in sys.argv else [sys.executable, str(root / 'scripts/protocol_smoke.py'), str(library)])
        result = subprocess.run(command, cwd=root, env=env, stdout=client_log, stderr=subprocess.STDOUT)
        client_log.flush()
        diagnostic = (output / 'client.log').read_text() + (wire.read_text() if wire.exists() else '')
        if result.returncode or 'Got GFX RDPGFX_CODECID_AVC420' not in diagnostic:
            print(diagnostic[-6000:])
            sys.exit(result.returncode or 'AVC420 was not exercised; refusing a fallback-only pass')
        (output / 'VERDICT.json').write_text(json.dumps({'passed': True, 'mode': mode,
            'codec': 'RDPGFX_CODECID_AVC420', 'library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
            'native_abi': 5, 'actual_decoded_frame': True, 'native_pixel_rgb_tolerance': 4}, indent=2) + '\n')
        print(f'PASS: actual AVC420 RDPGFX decode and graphics/input/lifecycle ({mode}); {output}')
    elif '--auth-ui' in sys.argv:
        env['LRDP_NATIVE_LIBRARY'] = str(library)
        result = subprocess.run(['flutter', 'test', 'test/workspace_auth_protocol_test.dart',
            '--reporter', 'expanded', '--no-pub'], cwd=root, env=env)
    elif '--nla' in sys.argv:
        result = subprocess.run([sys.executable, str(root / 'scripts/nla_smoke.py'), str(library)], env=env)
    elif '--flutter' in sys.argv:
        env['LRDP_NATIVE_LIBRARY'] = str(library)
        result = subprocess.run(['flutter', 'test', 'test/rdp_session_test.dart', '--reporter', 'expanded'], cwd=root, env=env)
    else:
        result = subprocess.run([sys.executable, str(root / 'scripts/protocol_smoke.py'), str(library)], env=env)
    sys.exit(result.returncode)
