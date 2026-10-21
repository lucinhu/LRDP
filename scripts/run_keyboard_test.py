#!/usr/bin/env python3
"""Phone IME edits -> Flutter -> actual RDP -> isolated X11 key events."""
from contextlib import ExitStack
from pathlib import Path
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import time
from rdp_test_desktop import Desktop

root = Path(__file__).resolve().parent.parent
out = root/'build/keyboard-runtime'; out.mkdir(parents=True, exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()


with tempfile.TemporaryDirectory(prefix='lrdp-keys-') as temporary, ExitStack() as cleanup:
    private = Path(temporary)
    display = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
    env = dict(os.environ, DISPLAY=f':{display}', XDG_CONFIG_HOME=str(private/'config'),
        LRDP_NATIVE_LIBRARY=str(root/'build/native/liblrdp.so'))
    log = cleanup.enter_context((out/'display.log').open('w'))
    desktop_process = subprocess.Popen(['Xvnc', env['DISPLAY'], '-geometry', '1280x800', '-depth', '24',
        '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath', str(private/'vnc.sock'),
        '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, desktop_process)
    for _ in range(200):
        assert desktop_process.poll() is None
        if Path(f'/tmp/.X11-unix/X{display}').exists(): break
        time.sleep(.05)
    else: raise AssertionError('Private display did not start')
    desktop = Desktop(env['DISPLAY']); cleanup.callback(desktop.close)
    desktop.movable_window(); desktop.pump()
    with socket.socket() as sock: sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    env.update(LRDP_KEYBOARD_PORT=str(port), LRDP_KEYBOARD_CONFIG=str(private/'client'))
    log = cleanup.enter_context((out/'server.log').open('w'))
    server = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1', f'/port:{port}',
        '/sec:tls', '-auth', '+may-view', '+may-interact', '-gfx-avc420', '-gfx-avc444',
        '/log-level:WARN'], env=env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, server)
    for _ in range(200):
        assert server.poll() is None
        if any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
            for line in Path('/proc/net/tcp').read_text().splitlines()[1:]): break
        time.sleep(.05)
    else: raise AssertionError('Private RDP listener did not start')
    log = cleanup.enter_context((out/'flutter.log').open('w'))
    subprocess.run(['flutter', 'test', '--no-pub', '--reporter', 'expanded',
        'test/session_keyboard_protocol_test.dart'], cwd=root, env=env,
        stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    desktop.pump()
    typed = [e['text'] for e in desktop.keys if e['type'] == 2 and e['text']]
    assert typed == ['\x00', 'a', 'A', 'b', 'a', 'A', '1', '!', '\b', '\r', '\x00', 'A', 'B', '\b', '\r', '\b', 'c'], desktop.keys
    downs = [e for e in desktop.keys if e['type'] == 2]
    assert len([e for e in downs if e['symbol'] == 32 and e['state'] & 4]) == 2, desktop.keys
    assert all(not e['state'] & 5 for e in downs if e['text'] in ('a', 'b', 'c')), desktop.keys
    assert [e['symbol'] for e in downs if 65470 <= e['symbol'] <= 65481] == list(range(65470, 65482)), desktop.keys
    assert all(e['state'] & 1 for e in downs if e['text'] in ('A', 'B')), desktop.keys
    assert len([e for e in downs if e['symbol'] == 65505]) == 5, desktop.keys
    arrows = [e for e in downs if 65361 <= e['symbol'] <= 65364]
    assert [e['symbol'] for e in arrows] == [65361, 65361, 65361, 65363, 65362, 65364], desktop.keys
    assert arrows[0]['state'] & 4 and not arrows[1]['state'] & 4, desktop.keys
    pressed = [e['symbol'] for e in desktop.keys if e['type'] == 2]
    released = [e['symbol'] for e in desktop.keys if e['type'] == 3]
    # Shift changes lookup of alphabetic releases, so compare physical pairing
    # through sorted keysyms; all modifiers must have a matching release.
    assert sorted(pressed) == sorted(released), desktop.keys
    report = {'passed': True, 'library_sha256': hashlib.sha256((root/'build/native/liblrdp.so').read_bytes()).hexdigest(),
        'typed': typed, 'events': desktop.keys, 'composing_commit_duplicated': False, 'latched_ctrl_space': True, 'sticky_shift_preserved': True, 'function_keys': list(range(1, 13)), 'held_alt_released_on_dispose': True,
        'ime_empty_backspace': True, 'raw_enter_backspace': True, 'raw_arrow_keys': ['Left','Right','Up','Down'],
        'one_shot_ctrl_space': True, 'one_shot_shift_ime_batch': True, 'one_shot_raw_ctrl_left': True, 'modifier_lock_enabled': True, 'disable_lock_releases_modifiers': True,
        'platform': 'Flutter headless + actual TLS RDP + isolated X11, not Android IME'}
    (out/'VERDICT.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS: actual RDP one-shot/locked modifiers, Latin IME, F1-F12 and modifier release')
