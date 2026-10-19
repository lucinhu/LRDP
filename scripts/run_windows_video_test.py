#!/usr/bin/env python3
"""Actual Flutter Windows engine/plugin pixels under a private Wine/X11 host.

Captures OS pixels rather than a Dart image. This does not prove the MSVC
main application, Windows Credential Manager, or a physical Windows GPU.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import ctypes as c
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
parser.add_argument('--fail-upload', action='store_true')
parser.add_argument('--gdb', action='store_true', help='Capture a native Wine abort stack')
parser.add_argument('--wine-memory-trace', action='store_true')
parser.add_argument('--wine-legacy-allocator', action='store_true',
    help="Select Dart's legacy allocator in this test host for Wine 11.20")
args = parser.parse_args()
build = root / 'build/windows-video-host'
runtime = root / 'build/windows-video-runtime'
out = runtime / ('fallback' if args.fail_upload else 'native')
out.mkdir(parents=True, exist_ok=True)
(out / 'VERDICT.json').unlink(missing_ok=True)


def sha(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


metadata = json.loads((build / 'BUILD_INFO.json').read_text())
for name, expected in metadata['source_files_sha256'].items():
    assert sha(root / name) == expected, 'Rebuild changed source: ' + name
for name, expected in metadata['artifacts_sha256'].items():
    assert sha(build / name) == expected, 'Rebuild changed artifact: ' + name


def windows_path(path):
    return 'Z:' + str(Path(path).resolve()).replace('/', '\\')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def until(ready, reason, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ready():
            return
        time.sleep(.1)
    raise AssertionError(reason)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


with tempfile.TemporaryDirectory(prefix='lrdp-windows-video-') as temporary, ExitStack() as cleanup:
    private = Path(temporary)
    environment = dict(os.environ, WINEPREFIX=str(runtime / 'wineprefix'),
        WINEARCH='win64', WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=',
        WINPR_NATIVE_SSPI='0', XDG_CONFIG_HOME=str(private / 'config'),
        XDG_DATA_HOME=str(private / 'data'))
    environment.pop('LRDP_NATIVE_LIBRARY', None)
    environment.pop('LRDP_DISABLE_TEXTURES', None)
    if args.fail_upload:
        environment['LRDP_VIDEO_TEST_FAIL_UPLOAD'] = '1'
    else:
        environment.pop('LRDP_VIDEO_TEST_FAIL_UPLOAD', None)
    displays = []
    for side, size in [('server', '1280x800'), ('client', '1400x1000')]:
        number = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
        env = dict(environment, DISPLAY=f':{number}')
        log = cleanup.enter_context((out / (side + '-display.log')).open('w'))
        process = subprocess.Popen(['Xvnc', env['DISPLAY'], '-geometry', size, '-depth', '24',
            '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath',
            str(private / (side + '.sock')), '-rfbunixmode', '0600', '-nolisten', 'tcp'],
            env=env, stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, process)
        until(lambda: Path(f'/tmp/.X11-unix/X{number}').exists(), 'Private X did not start')
        displays.append(env)
    server_env, client_env = displays
    cleanup.callback(subprocess.run, ['wineserver', '-k'], env=client_env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    log = cleanup.enter_context((out / 'wineboot.log').open('w'))
    print('Initializing owned Windows-video Wine prefix', flush=True)
    if not (runtime / 'wineprefix/.update-timestamp').exists():
        try:
            subprocess.run(['wineboot', '--init'], env=client_env, stdout=log,
                stderr=subprocess.STDOUT, timeout=120, check=True)
        except subprocess.TimeoutExpired:
            # The bootstrap command is terminal, but Wine services may still
            # be starting. Probe the same prefix; do not restart on observation.
            print('Wine bootstrap command reached its deadline; probing the same prefix', flush=True)
    subprocess.run(['wine', 'cmd', '/c', 'ver'], env=client_env, stdout=log,
        stderr=subprocess.STDOUT, timeout=90, check=True)
    unit = cleanup.enter_context((out / 'unit.log').open('w'))
    unit_env = dict(client_env)
    unit_env.pop('LRDP_VIDEO_TEST_FAIL_UPLOAD', None)
    for arguments in ([], ['--fail-upload']):
        subprocess.run(['wine', str(root / 'build/windows-x64/lrdp_windows_video_test.exe'),
                        *arguments], env=unit_env, stdout=unit, stderr=subprocess.STDOUT,
                       timeout=60, check=True)
    print('PASS: Windows PE buffer tests, including failure and late release', flush=True)

    desktop = Desktop(server_env['DISPLAY'])
    cleanup.callback(desktop.close)

    def color(rgb):
        subprocess.run(['xsetroot', '-solid', rgb], env=server_env, check=True)
        gc = desktop.fn('XCreateGC', c.c_void_p, c.c_void_p, c.c_ulong,
                        c.c_ulong, c.c_void_p)(desktop.display, desktop.root, 0, None)
        for x, y, value in [(32, 32, 0xd34120), (1184, 704, 0x2550c6)]:
            desktop.fn('XSetForeground', c.c_int, c.c_void_p, c.c_void_p,
                       c.c_ulong)(desktop.display, gc, value)
            desktop.fn('XFillRectangle', c.c_int, c.c_void_p, c.c_ulong, c.c_void_p,
                       c.c_int, c.c_int, c.c_uint, c.c_uint)(
                           desktop.display, desktop.root, gc, x, y, 64, 64)
        desktop.fn('XFreeGC', c.c_int, c.c_void_p, c.c_void_p)(desktop.display, gc)
        desktop.sync()

    color('#182d28')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    log = cleanup.enter_context((out / 'server.log').open('w'))
    server = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1', f'/port:{port}',
        '/sec:tls', '-auth', '+may-view', '+may-interact', '-gfx-avc420', '-gfx-avc444',
        '/log-level:WARN'], env=server_env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, server)
    until(lambda: any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
        for line in Path('/proc/net/tcp').read_text().splitlines()[1:]), 'Private RDP did not listen')
    client_env.update(LRDP_VIDEO_PORT=str(port), LRDP_VIDEO_CONTROL=windows_path(private))
    log = cleanup.enter_context((out / 'flutter.log').open('w'))
    command = ['wine', str(build / 'video_host.exe'),
        windows_path(build / 'flutter_assets'), windows_path(build / 'icudtl.dat'),
        windows_path(private)]
    if args.gdb:
        command = ['gdb', '--batch', '-ex', 'set debuginfod enabled off',
                   '-ex', 'handle SIGSEGV nostop noprint pass',
                   '-ex', 'handle SIGILL nostop noprint pass',
                   '-ex', 'handle SIGUSR1 nostop noprint pass',
                   '-ex', 'run', '-ex', 'thread apply all bt 12', '--args', *command]
    host_env = dict(client_env)
    if args.wine_memory_trace:
        host_env['WINEDEBUG'] = '-all,+virtual,+loaddll'
    if args.wine_legacy_allocator:
        host_env['LRDP_TEST_WINE_LEGACY_ALLOCATOR'] = '1'
    else:
        host_env.pop('LRDP_TEST_WINE_LEGACY_ALLOCATOR', None)
    client = subprocess.Popen(command, cwd=build, env=host_env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, client)
    seen, observed = [], []
    deadline = time.monotonic() + 360
    while client.poll() is None and time.monotonic() < deadline:
        stage = read_json(private / 'stage.json')
        window = read_json(private / 'window.json')
        if stage and window and stage['stage'] not in seen:
            name = stage['stage']
            expected = [(stage['background'], stage['rgb'])] + list(zip(stage['cursor'],
                [[0, 0, 0], [255, 255, 255], stage['rgb'], [255 - v for v in stage['rgb']]]))
            expected += list(zip(stage.get('markers', []), [[211, 65, 32], [37, 80, 198]]))

            def pixels_match():
                frame = ImageGrab.grab(xdisplay=client_env['DISPLAY']).convert('RGB')
                frame.save(out / (name + '.png'))
                return all(max(abs(a - b) for a, b in zip(
                    frame.getpixel((point[0] + window['left'], point[1] + window['top'])), rgb)) <= 5
                    for point, rgb in expected)

            (out / (name + '.json')).write_text(json.dumps({'stage': stage, 'window': window}, indent=2) + '\n')
            until(pixels_match, 'Windows native color/XOR/orientation mismatch at ' + name, 15)
            seen.append(name)
            observed.append(stage)
            if name == 'base':
                color('#8a3bc1')
            elif name == 'hidden':
                color('#2a8465')
            (private / (name + '.ack')).touch()
            print('PASS Windows OS texture pixels:', name, flush=True)
        time.sleep(.1)
    assert client.poll() is not None, 'Flutter Windows acceptance host still running after deadline'
    result = read_json(private / 'result.json')
    if result:
        (out / 'RESULT.json').write_text(json.dumps(result, indent=2) + '\n')
    assert client.wait() == 0 and result and result['passed'], f'Windows video failed: {result}; see {out / "flutter.log"}'
    assert seen == ['base', 'updated', 'hidden', 'still-hidden', 'resumed', 'zoomed'], seen
    assert result['reconnections'] == 3 and result['native_texture'] == (not args.fail_upload)
    if args.wine_legacy_allocator:
        assert 'Dart legacy VirtualAlloc fallback selected' in (out / 'flutter.log').read_text()
    if not args.fail_upload:
        assert result['decoded_frames_initial'] == result['decoded_frames_final']
    else:
        assert result['diagnostics']['uploadFailures'] == 4
    result.update(platform='Windows x64 Debug Flutter engine under Wine; OS X11 pixels',
                  main_application=False, physical_windows=False, cases=observed, build=metadata,
                  wine_legacy_allocator=args.wine_legacy_allocator,
                  engine_file_modified=False)
    (out / 'VERDICT.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: actual Windows Flutter native textures/fallback, color/XOR/zoom/freeze/remount and three reconnects', flush=True)
