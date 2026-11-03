#!/usr/bin/env python3
"""Private TLS visibility/CPU oracle; no native rebuild, Flutter, Xvnc or credentials.

Example: python3 scripts/run_visibility_test.py --baseline-library /tmp/lrdp-before-cpu.so
CPU is time.process_time() in one fresh client process per library, excluding
fixture/server CPU. The producer targets 240 Hz with 320x240 raw BGRA bitmaps;
this is not an AVC benchmark or a measurement of whole-machine CPU.
"""
import argparse
from contextlib import ExitStack
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/visibility-runtime'


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def wait_for(predicate, message, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise RuntimeError(message)


def controls(path):
    return [int(line.rsplit('=', 1)[1]) for line in path.read_text().splitlines()
            if line.startswith('SuppressOutput allow=')]


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def client(spec):
    """Only this subprocess loads the tested shared library."""
    lib = C.CDLL(spec['library'])
    ptr, integer = C.c_void_p, C.c_int
    i32p, u64p = C.POINTER(C.c_int32), C.POINTER(C.c_uint64)
    signatures = {
        'lrdp_initialize': ([C.c_char_p], integer),
        'lrdp_create': ([], ptr),
        'lrdp_set': ([ptr, C.c_char_p, C.c_char_p], integer),
        'lrdp_start': ([ptr], integer),
        'lrdp_state': ([ptr], integer),
        'lrdp_read': ([ptr, integer, ptr, C.c_size_t], integer),
        'lrdp_video_ticket': ([ptr], C.c_uint64),
        'lrdp_video_open': ([C.c_uint64], ptr),
        'lrdp_video_info': ([ptr, i32p, i32p, u64p], integer),
        'lrdp_video_close': ([ptr], None),
        'lrdp_frame': ([ptr, ptr, C.c_size_t, i32p, i32p, u64p], integer),
        'lrdp_input': ([ptr, integer, integer, integer, integer], integer),
        'lrdp_stop': ([ptr], None),
        'lrdp_destroy': ([ptr], None),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(lib, name)
        function.argtypes, function.restype = arguments, result
    visible = getattr(lib, 'lrdp_set_visible', None)
    if visible:
        visible.argtypes, visible.restype = [ptr, integer], integer
    baseline = spec['baseline']
    suppress_supported = spec['suppress_supported']
    check(baseline or visible is not None, 'Current library lacks lrdp_set_visible')
    check(lib.lrdp_initialize(spec['private'].encode()), 'Private initialization failed')
    session = lib.lrdp_create()
    check(session, 'Session creation failed')
    video = None
    report = {'passed': False, 'baseline_local_hide_only': baseline,
              'server_supports_suppress_output': suppress_supported,
              'set_visible_symbol_available': visible is not None, 'samples': {}}
    server_log = Path(spec['server_log'])

    def connected():
        state = lib.lrdp_state(session)
        error = C.create_string_buffer(1024)
        lib.lrdp_read(session, 0, error, len(error))
        check(state == 2, f'Expected connected, state={state}: {error.value.decode(errors="replace")}')

    def info():
        width, height, generation = C.c_int32(), C.c_int32(), C.c_uint64()
        present = lib.lrdp_video_info(video, C.byref(width), C.byref(height), C.byref(generation))
        if present:
            check((width.value, height.value) == (320, 240), 'Unexpected desktop dimensions')
        return generation.value

    def switch(value):
        if not baseline:
            check(visible(session, value) == 1, f'Visibility {value} rejected')
            if suppress_supported:
                wait_for(lambda: controls(server_log)[-1:] == [value],
                         f'Server did not acknowledge SuppressOutput allow={value}')
        time.sleep(.3)  # Exclude requests, in-flight frames and transition work.
        connected()

    def sample(name, duration, hidden=False):
        connected()
        generation = info()
        wall, cpu = time.monotonic(), time.process_time()
        time.sleep(duration)
        cpu = time.process_time() - cpu
        wall = time.monotonic() - wall
        end = info()
        connected()
        delta = end - generation
        report['samples'][name] = {
            'wall_seconds': wall, 'client_cpu_seconds': cpu,
            'client_cpu_percent_one_core': cpu / wall * 100,
            'generation_start': generation, 'generation_end': end,
            'generation_delta': delta, 'published_frames_per_second': delta / wall,
        }
        check(delta == 0 if hidden and suppress_supported and not baseline else delta > 0,
              f'{name}: unexpected generation delta {delta}')

    def release_key(code):
        check(lib.lrdp_input(session, 1, 0, code, 0) == 1, f'Scancode {code:#x} down rejected')
        check(lib.lrdp_input(session, 1, 0x8000, code, 0) == 1, f'Scancode {code:#x} release rejected')

    def full_frame():
        pixels = (C.c_uint8 * (320 * 240 * 4))()
        width, height, generation = C.c_int32(), C.c_int32(), C.c_uint64()
        size = lib.lrdp_frame(session, pixels, len(pixels), C.byref(width),
                              C.byref(height), C.byref(generation))
        check(size == len(pixels) and (width.value, height.value) == (320, 240),
              'Resume did not yield a complete 320x240 frame')
        data = bytes(pixels)
        check(data[2] == 0x75 and data == data[:4] * (320 * 240),
              'Restored frame has incomplete/incorrect fixture pixels')
        return {'generation': generation.value, 'uniform_bgra': list(data[:4]),
                'producer_sequence_low16': data[0] + 256 * data[1], 'bytes': size}

    try:
        for key, value in {
            'host': '127.0.0.1', 'port': str(spec['port']), 'username': 'visibility-test',
            'fingerprint': spec['pin'], 'config_path': spec['private'],
            'width': '320', 'height': '240', 'nla': '0', 'clipboard': '0', 'audio': '0',
        }.items():
            check(lib.lrdp_set(session, key.encode(), value.encode()), f'Setting {key} rejected')
        if not baseline:
            check(visible(None, 0) == 0 and visible(session, -1) == 0 and
                  visible(session, 2) == 0, 'Invalid visibility requests accepted')
            check(visible(session, 0) == 1, 'Pre-connect hidden request rejected')
        check(lib.lrdp_start(session), 'Start failed')
        wait_for(lambda: lib.lrdp_state(session) not in (0, 1), 'Connect timed out', 10)
        connected()
        video = lib.lrdp_video_open(lib.lrdp_video_ticket(session))
        check(video, 'Video handle creation failed')
        switch(0)
        sample('initial_hidden', 1, hidden=True)
        switch(1)
        sample('foreground', spec['seconds'])
        report['first_complete_frame'] = full_frame()
        switch(0)
        sample('background', spec['seconds'], hidden=True)
        paused_generation = info()
        switch(1)
        wait_for(lambda: info() > paused_generation, 'Resume did not publish a new frame')
        sample('restored', spec['seconds'])
        report['restored_complete_frame'] = full_frame()
        if not baseline:
            for index in range(200):
                check(visible(session, index & 1) == 1, 'Rapid toggle rejected')
            switch(0)
            sample('rapid_final_hidden', .5, hidden=True)
            paused_generation = info()
            switch(1)
            wait_for(lambda: info() > paused_generation, 'Rapid toggle recovery failed')
            report['rapid_restored_complete_frame'] = full_frame()
            report['rapid_toggle_requests'] = 200
        if not baseline and suppress_supported:
            switch(0)
            previous_controls = len(controls(server_log))
            release_key(0x30)  # B: same-size reactivation resets server output state.
            wait_for(lambda: 'Reactivate suppress_supported=1' in server_log.read_text(),
                     'B did not request same-capability reactivation')
            wait_for(lambda: len(controls(server_log)) > previous_controls and
                     controls(server_log)[-1:] == [0], 'Hidden state was not replayed after reactivation')
            time.sleep(.3)
            sample('reactivated_hidden', .5, hidden=True)
            switch(1)
            sample('reactivated_restored', .5)
            report['reactivated_complete_frame'] = full_frame()
            switch(0)
            previous_controls = len(controls(server_log))
            release_key(0x2e)  # C: server removes SuppressOutput during reactivation.
            wait_for(lambda: 'Reactivate suppress_supported=0' in server_log.read_text(),
                     'C did not request capability-removing reactivation')
            suppress_supported = False
            time.sleep(.3)
            sample('capability_removed_hidden', .5, hidden=True)
            switch(1)
            sample('capability_removed_restored', .5)
            report['capability_removed_complete_frame'] = full_frame()
            check(len(controls(server_log)) == previous_controls,
                  'Client sent SuppressOutput after capability removal')
            report['reactivation_hidden_replayed'] = True
            report['capability_removal_safely_degraded'] = True
        switch(0)
        # A release is a server-side oracle: receiving input while hidden exits 0.
        release_key(0x1e)
        wait_for(lambda: 'client acknowledged=1' in server_log.read_text(),
                 'Hidden session did not deliver A release')
        report['input_while_hidden_acknowledged'] = True
        started = time.monotonic()
        lib.lrdp_stop(session)
        if not baseline:
            check(visible(session, 0) == 0 and visible(session, 1) == 0,
                  'Stopped session accepted visibility')
        lib.lrdp_destroy(session)
        session = None
        report['stop_and_destroy_seconds'] = time.monotonic() - started
        check(report['stop_and_destroy_seconds'] < 2, 'Stop/destroy exceeded two seconds')
        report['passed'] = True
    finally:
        if session:
            lib.lrdp_stop(session)
            lib.lrdp_destroy(session)
        if video:
            lib.lrdp_video_close(video)
        Path(spec['result']).write_text(json.dumps(report, indent=2) + '\n')


def run_case(library, baseline, fixture, cert, key, pin, private, seconds, suppress_supported=True):
    name = 'baseline' if baseline else 'current' if suppress_supported else 'current-no-suppress'
    library_digest = hashlib.sha256(library.read_bytes()).hexdigest()
    directory = private / name
    directory.mkdir(mode=0o700)
    environment = dict(os.environ, XDG_CONFIG_HOME=str(directory / 'config'),
                       XDG_CACHE_HOME=str(directory / 'cache'), XDG_DATA_HOME=str(directory / 'data'),
                       WLOG_LEVEL='WARN')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    log_path = OUT / f'{name}-server.log'
    result = OUT / f'{name}-client.json'
    spec = {'library': str(library), 'baseline': baseline, 'port': port, 'pin': pin,
            'suppress_supported': suppress_supported,
            'private': str(directory), 'server_log': str(log_path),
            'result': str(result), 'seconds': seconds}
    spec_path = directory / 'client.json'
    spec_path.write_text(json.dumps(spec))
    with ExitStack() as cleanup:
        server_log = cleanup.enter_context(log_path.open('w'))
        command = [str(fixture), str(port), str(cert), str(key)]
        if not suppress_supported:
            command.append('--no-suppress')
        server = subprocess.Popen(command, env=environment, stdout=server_log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, server)

        def listening():
            check(server.poll() is None, f'{name} fixture exited early; see {log_path}')
            # A TCP probe consumes this one-peer fixture; inspect Linux sockets instead.
            return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                       for line in Path('/proc/net/tcp').read_text().splitlines()[1:])

        wait_for(listening, 'Private loopback fixture did not listen')
        client_log = cleanup.enter_context((OUT / f'{name}-client.log').open('w'))
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), '--client-config', str(spec_path)],
            env=environment, stdout=client_log, stderr=subprocess.STDOUT, timeout=27)
        client_log.flush()
        check(completed.returncode == 0,
              f'{name} client failed: ' + (OUT / f'{name}-client.log').read_text()[-3500:])
        check(server.wait(timeout=3) == 0, 'Fixture did not acknowledge completion key')
    report = json.loads(result.read_text())
    check(hashlib.sha256(library.read_bytes()).hexdigest() == library_digest,
          'Library changed during measurement; rerun after rebuilding')
    report.update(library=str(library), library_sha256=library_digest,
                  server_suppress_output_allow=controls(log_path), server_exit_code=server.returncode)
    observed = report['server_suppress_output_allow']
    if baseline or not suppress_supported:
        check(not observed, 'Local-hide baseline/unsupported server unexpectedly sent SuppressOutput')
    else:
        # Rapid toggles may coalesce; stable transitions must be present in order.
        check(observed[:4] == [0, 1, 0, 1] and observed[-1:] == [0],
              f'Missing stable suppress/resume transitions: {observed}')
    check(report['passed'], f'{name} client validation failed')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=ROOT / 'build/native/liblrdp.so')
    parser.add_argument('--baseline-library', type=Path,
                        help='Prior library, always tested with local hiding and no visibility calls')
    parser.add_argument('--seconds', type=float, default=2,
                        help='CPU window in seconds (1 to 3; default 2)')
    parser.add_argument('--client-config', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.client_config:
        client(json.loads(args.client_config.read_text()))
        return
    check(1 <= args.seconds <= 3, '--seconds must be between 1 and 3')
    OUT.mkdir(parents=True, exist_ok=True)
    verdict = {'passed': False, 'protocol_passed': False,
               'scope': 'Private TLS RDP on random 127.0.0.1 ports; 320x240 raw BGRA bitmap '
                        'producer targeting 240 Hz; ctypes native client only; not AVC, Flutter '
                        'rendering, or whole-machine CPU.',
               'cpu_method': 'time.process_time()/time.monotonic() in a fresh client process '
                             'per library; includes native network/decode threads, excludes server; '
                             '100% equals one CPU core; transition/connection costs excluded.',
               'cases': {}}
    try:
        library = args.library.resolve(strict=True)
        baseline = args.baseline_library.resolve(strict=True) if args.baseline_library else None
        flags = shlex.split(subprocess.check_output([
            'pkg-config', '--cflags', '--libs', 'freerdp3', 'freerdp-server3', 'winpr3'], text=True))
        fixture = OUT / 'frame_rate_fixture'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                        str(ROOT / 'native/tests/frame_rate_fixture.c'), '-o', str(fixture), *flags], check=True)
        with tempfile.TemporaryDirectory(prefix='lrdp-visibility-') as temporary:
            private = Path(temporary)
            cert, key = private / 'cert.pem', private / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc',
                            '-days', '1', '-subj', '/CN=localhost', '-keyout', str(key),
                            '-out', str(cert)], check=True, capture_output=True)
            key.chmod(0o600)
            der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
            pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
            verdict['cases']['current'] = run_case(library, False, fixture, cert, key, pin, private, args.seconds)
            verdict['cases']['current-no-suppress'] = run_case(
                library, False, fixture, cert, key, pin, private, args.seconds, suppress_supported=False)
            check(verdict['cases']['current']['library_sha256'] ==
                  verdict['cases']['current-no-suppress']['library_sha256'],
                  'Current-library cases used different builds; rerun')
            if baseline:
                verdict['cases']['baseline'] = run_case(baseline, True, fixture, cert, key, pin, private, args.seconds)
        verdict['protocol_passed'] = True
        samples = verdict['cases']['current']['samples']
        foreground = samples['foreground']['client_cpu_percent_one_core']
        background = samples['background']['client_cpu_percent_one_core']
        verdict['cpu_comparison'] = {
            'current_foreground_cpu_percent_one_core': foreground,
            'current_background_cpu_percent_one_core': background,
            'background_reduction_vs_foreground_percent': (1 - background / foreground) * 100,
            'interpretation': 'Descriptive short-window CPU samples; no hard performance threshold '
                              'because host load varies. Protocol/generation checks decide pass/fail.',
        }
        if baseline:
            previous = verdict['cases']['baseline']['samples']['background']['client_cpu_percent_one_core']
            verdict['cpu_comparison'].update(
                baseline_local_hide_background_cpu_percent_one_core=previous,
                background_reduction_vs_baseline_percent=(1 - background / previous) * 100)
        verdict['passed'] = True
    except Exception as error:
        verdict['error'] = f'{type(error).__name__}: {error}'
    (OUT / 'VERDICT.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    if not verdict['passed']:
        sys.exit(1)


if __name__ == '__main__':
    main()
