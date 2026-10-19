#!/usr/bin/env python3
"""Actual TLS/RDPSND playback into a private PulseAudio null sink, never hardware."""
from contextlib import ExitStack
from pathlib import Path
import argparse
import array
import hashlib
import json
import math
import os
import shlex
import signal
import statistics
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path)
parser.add_argument('--library', type=Path)
parser.add_argument('--wine', action='store_true')
args = parser.parse_args()
assert not (args.wine and args.library), 'Wine loads the DLL beside its matching test executable'
build = (args.build or root / ('build/windows-x64' if args.wine else 'build/native-audio')).resolve()
library = (args.library or build / ('lrdp.dll' if args.wine else 'liblrdp.so')).resolve()
mode_name = 'wine' if args.wine else 'asan' if 'asan' in build.name else 'native'
if args.library:
    mode_name += '-custom'
output = root / 'build/audio-runtime' / mode_name
output.mkdir(parents=True, exist_ok=True)
(output / 'VERDICT.json').unlink(missing_ok=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def stop_private_group(process):
    if process.poll() is None:
        assert os.getpgid(process.pid) == process.pid
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def until(predicate, message, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(message)


def analyze(path, expect_audio):
    pcm = array.array('h', path.read_bytes())
    assert len(pcm) % 2 == 0 and len(pcm) > 48000, 'missing stereo monitor capture'
    frames = len(pcm) // 2
    active = [i for i in range(frames) if max(abs(pcm[2*i]), abs(pcm[2*i+1])) > 16]
    if not expect_audio:
        assert not active, 'muted/unsupported stream produced sound'
        return {'silent': True, 'captured_frames': frames}
    assert len(active) > 45000, 'less than 937 ms of actual playback'
    first, last = active[0], active[-1]
    assert last - first >= 47000
    samples = 480  # 10 ms, integer periods at both synthetic frequencies.
    def amplitude(start, channel, frequency):
        re = im = 0.0
        for i in range(samples):
            value = pcm[2 * (start + i) + channel]
            angle = 2 * math.pi * frequency * i / 48000
            re += value * math.cos(angle)
            im += value * math.sin(angle)
        return 2 * math.hypot(re, im) / samples
    windows = []
    for start in range(first, last - samples, samples):
        if max(abs(pcm[2 * i]) for i in range(start, start + samples)) < 100:
            continue
        windows.append((amplitude(start, 0, 500), amplitude(start, 1, 1000),
            amplitude(start, 0, 1000), amplitude(start, 1, 500)))
    assert len(windows) >= 90, 'less than 900 ms of captured tone windows'
    left = statistics.median(w[0] for w in windows)
    right = statistics.median(w[1] for w in windows)
    assert 4000 < left < 8000 and 2500 < right < 5500, (left, right)
    assert statistics.median(w[2] for w in windows) < left / 10
    assert statistics.median(w[3] for w in windows) < right / 10
    return {'silent': False, 'active_frames': len(active), 'rate': 48000,
        'channels': 2, 'left_500_hz_amplitude': left, 'right_1000_hz_amplitude': right,
        'tone_windows_10ms': len(windows),
        'frequency_separation_db': '>20'}


def analyze_lifecycle(path):
    pcm = array.array('h', path.read_bytes())
    assert len(pcm) % 2 == 0
    count = len(pcm) // 2
    silence = longest = 0
    for i in range(count):
        silence = silence + 1 if max(abs(pcm[2*i]), abs(pcm[2*i+1])) <= 16 else 0
        longest = max(longest, silence)
    assert longest >= 48000 * 2.5, 'No sustained silence during pause'
    phases = [0, 0, 0]
    for start in range(0, count - 480, 480):
        def amplitude(channel, frequency):
            real = imag = 0.0
            for i in range(480):
                angle = 2 * math.pi * frequency * i / 48000
                value = pcm[2*(start+i)+channel]
                real += value * math.cos(angle); imag += value * math.sin(angle)
            return 2 * math.hypot(real, imag) / 480
        for phase in range(3):
            if amplitude(0, 500 + phase * 1000) > 2500 and amplitude(1, 1000 + phase * 1000) > 1500:
                phases[phase] += 1
    assert phases[0] >= 10, ('Missing initial playback', phases)
    assert phases[2] >= 60, ('Missing resumed fresh playback', phases)
    assert phases[1] == 0, ('Paused audio was played or replayed after resume', phases)
    return {'longest_silence_seconds': longest / 48000,
        'tone_windows_10ms': {'initial': phases[0], 'paused_data_forbidden': phases[1], 'fresh_resumed': phases[2]},
        'no_paused_audio_replay': True}


flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
    'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
fixture = output / 'audio_fixture'
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
    str(root / 'native/tests/audio_fixture.c'), '-o', str(fixture), *flags, '-lm'], check=True)
binary = build / ('lrdp_audio_test.exe' if args.wine else 'lrdp_audio_test')
assert binary.exists(), 'Build lrdp_audio_test first'
results = []
with tempfile.TemporaryDirectory(prefix='lrdp-audio-') as private, ExitStack() as cleanup:
    directory = Path(private)
    runtime = directory / 'runtime'; runtime.mkdir(mode=0o700)
    pulse_socket = directory / 'pulse.sock'
    environment = dict(os.environ, XDG_RUNTIME_DIR=str(runtime),
        PULSE_SERVER='unix:' + str(pulse_socket), PULSE_SINK='lrdp_test', WLOG_LEVEL='WARN')
    if mode_name == 'asan':
        environment.update(ASAN_OPTIONS='detect_leaks=1:halt_on_error=1',
            UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    if args.wine:
        prefix = root / 'build/windows-runtime/wineprefix'
        assert (prefix / '.update-timestamp').exists(), 'Initialize the private Wine prefix first'
        environment.update(WINEPREFIX=str(prefix), WINEDEBUG='-all', DISPLAY='',
            WINEDLLOVERRIDES='mscoree,mshtml=')
        # This is only LRDP's disposable prefix. Force Pulse so Wine cannot
        # fall back to ALSA or another device outside the isolated null sink.
        subprocess.run(['wine', 'reg', 'add', r'HKCU\Software\Wine\Drivers',
            '/v', 'Audio', '/t', 'REG_SZ', '/d', 'pulse', '/f'],
            env=environment, check=True, capture_output=True)
    pulse_log = cleanup.enter_context((output / 'pulse.log').open('w'))
    # -n disables the default startup script: no hardware module can be loaded.
    pulse = subprocess.Popen(['dbus-run-session', '--', 'pulseaudio', '-n', '--daemonize=no', '--exit-idle-time=-1',
        '--use-pid-file=no', '--disable-shm=true',
        '--load=module-native-protocol-unix socket=' + str(pulse_socket) + ' auth-anonymous=1',
        '--load=module-null-sink sink_name=lrdp_test rate=48000 channels=2'],
        env=environment, stdout=pulse_log, stderr=subprocess.STDOUT, start_new_session=True)
    cleanup.callback(stop_private_group, pulse)
    until(lambda: pulse_socket.exists() or pulse.poll() is not None, 'private Pulse socket')
    assert pulse.poll() is None, (output / 'pulse.log').read_text()
    modules = subprocess.check_output(['pactl', 'list', 'short', 'modules'], env=environment, text=True)
    assert 'module-alsa' not in modules and 'module-udev' not in modules
    (output / 'private-modules.txt').write_text(modules)
    cert, key = directory / 'cert.pem', directory / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
    drive = directory / 'drive'; drive.mkdir()
    for mode in ('on', 'on_drive', 'off', 'unsupported', 'lifecycle', 'pcm8', 'dynamic'):
        config_path = str(directory / mode)
        drive_path = str(drive) if mode == 'on_drive' else ''
        if args.wine:
            def windows_path(path):
                return subprocess.check_output(['winepath', '-w', path], env=environment, text=True).strip()
            # Wine may initialize services while translating paths. Complete
            # that before starting the peer's bounded accept deadline.
            config_path = windows_path(config_path)
            if drive_path:
                drive_path = windows_path(drive_path)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        with ExitStack() as case:
            log = case.enter_context((output / (mode + '.log')).open('w'))
            server = subprocess.Popen([str(fixture), str(port), str(cert), str(key), mode],
                env=environment, stdout=log, stderr=subprocess.STDOUT)
            case.callback(stop, server)
            def listening():
                return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                    for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
            until(listening, mode + ': fixture listener')
            captured = output / (mode + '.pcm')
            data = case.enter_context(captured.open('wb'))
            record_log = case.enter_context((output / (mode + '-record.log')).open('w'))
            recorder = subprocess.Popen(['parec', '--device=lrdp_test.monitor', '--raw',
                '--format=s16le', '--rate=48000', '--channels=2', '--latency-msec=20'], env=environment,
                stdout=data, stderr=record_log)
            case.callback(stop, recorder)
            until(lambda: subprocess.check_output(['pactl', 'list', 'short', 'source-outputs'],
                env=environment, text=True).strip(), 'monitor recording stream')
            # A registered stream can still be priming its capture buffer.
            # Observe real initial silence before sending the one-second tone.
            until(lambda: captured.stat().st_size >= 19200,
                'monitor must deliver 100 ms of initial silence before playback')
            client_log = case.enter_context((output / (mode + '-client.log')).open('w'))
            subprocess.run((['wine'] if args.wine else []) + [str(binary), str(port), pin,
                '0' if mode == 'off' else '1', config_path, drive_path] +
                (['lifecycle'] if mode in ('lifecycle', 'dynamic') else []), env=dict(environment,
                LD_LIBRARY_PATH=str(library.parent) + ':' + environment.get('LD_LIBRARY_PATH', '')),
                stdout=client_log, stderr=subprocess.STDOUT, check=True, timeout=25)
            assert server.wait(timeout=8) == 0, (output / (mode + '.log')).read_text()[-4000:]
            stop(recorder); data.flush()
            report = next(json.loads(line) for line in (output / (mode + '.log')).read_text().splitlines()
                if line.startswith('{"mode"'))
            assert report['passed'], report
            report['actual_sink_capture'] = (analyze_lifecycle(captured) if mode in ('lifecycle', 'dynamic')
                else analyze(captured, mode in ('on', 'on_drive', 'pcm8', 'dynamic')))
            assert not subprocess.check_output(['pactl', 'list', 'short', 'sink-inputs'],
                env=environment, text=True).strip(), 'Playback device leaked after client closed'
            results.append(report)
            print('PASS: actual RDPSND playback ' + mode, flush=True)
(output / 'VERDICT.json').write_text(json.dumps({'passed': True, 'native_abi': 5,
    'library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
    'backend': 'WinMM/Wine Pulse driver' if args.wine else 'PulseAudio',
    'sink': 'private null sink; no hardware modules', 'cases': results}, indent=2) + '\n')
