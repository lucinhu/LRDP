#!/usr/bin/env python3
"""Private TLS native frame-publication pacing and descriptive client CPU samples.

Run after the native library is built:
  python3 scripts/run_frame_pacing_test.py --baseline-library /tmp/lrdp-before-cpu-round2.so

For the larger descriptive profile, add:
  --width 1920 --height 1080 --source-fps 60 --rates 30 --output build/frame-pacing-runtime-1080p

Each library runs in a fresh ctypes client process. The server defaults to 240 Hz
with 320x240 raw BGRA bitmaps. This measures native publication and client
process CPU, not AVC, Flutter rendering, whole-machine CPU or Android hardware.
Only the standalone server fixture is compiled by this script.
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

from run_visibility_test import ROOT, check, stop, wait_for


def stage_list(rates):
    stages = [('default_unlimited', None)]
    seen = {}
    for rate in rates:
        seen[rate] = seen.get(rate, 0) + 1
        suffix = '' if seen[rate] == 1 else '_again' if seen[rate] == 2 else f'_{seen[rate]}'
        stages.append((f'{rate}{suffix}', rate))
    return stages


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def client(spec):
    width, height = spec['width'], spec['height']
    source_fps = spec['source_fps']
    strict = (width, height, source_fps) == (320, 240, 240)
    stages = stage_list(spec['rates'])
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
    pacing = getattr(lib, 'lrdp_set_frame_rate', None)
    if pacing:
        pacing.argtypes, pacing.restype = [ptr, integer], integer
    baseline = spec['baseline']
    check(baseline or pacing is not None, 'Current library lacks lrdp_set_frame_rate')
    check(lib.lrdp_initialize(spec['private'].encode()), 'Private initialization failed')
    if not baseline:
        check(pacing(None, 30) == 0, 'NULL session accepted a frame rate')
        unstarted = lib.lrdp_create()
        check(unstarted, 'Unstarted session creation failed')
        try:
            for invalid in (-1, 0, 241):
                check(pacing(unstarted, invalid) == 0, f'Invalid rate {invalid} accepted')
            for valid in (1, 30, 120, 240):
                check(pacing(unstarted, valid) == 1, f'Pre-connect rate {valid} rejected')
            lib.lrdp_stop(unstarted)
            check(pacing(unstarted, 30) == 0, 'Stopped session accepted a frame rate')
        finally:
            lib.lrdp_destroy(unstarted)
    session = lib.lrdp_create()
    check(session, 'Session creation failed')
    video = None
    report = {'passed': False, 'baseline_no_pacing_calls': baseline,
              'frame_rate_symbol_available': pacing is not None, 'samples': {}}

    def connected():
        state = lib.lrdp_state(session)
        error = C.create_string_buffer(1024)
        lib.lrdp_read(session, 0, error, len(error))
        check(state == 2, f'Expected connected, state={state}: {error.value.decode(errors="replace")}')

    def info():
        w, h, generation = C.c_int32(), C.c_int32(), C.c_uint64()
        present = lib.lrdp_video_info(video, C.byref(w), C.byref(h), C.byref(generation))
        if present:
            check((w.value, h.value) == (width, height), 'Unexpected dimensions')
        return generation.value

    def frame():
        pixels = (C.c_uint8 * (width * height * 4))()
        w, h, generation = C.c_int32(), C.c_int32(), C.c_uint64()
        size = lib.lrdp_frame(session, pixels, len(pixels), C.byref(w), C.byref(h), C.byref(generation))
        check(size == len(pixels) and (w.value, h.value) == (width, height),
              f'Expected a complete {width}x{height} frame')
        return bytes(pixels), generation.value

    def snapshot():
        data, generation = frame()
        check(data[2] == 0x75 and data[3] == 255 and data == data[:4] * (width * height),
              'Partial or incorrect fixture frame')
        return {'generation': generation, 'producer_sequence_low16': data[0] + 256 * data[1],
                'uniform_bgra': list(data[:4]), 'bytes': len(data)}

    try:
        for key, value in {
            'host': '127.0.0.1', 'port': str(spec['port']), 'username': 'frame-pacing-test',
            'fingerprint': spec['pin'], 'config_path': spec['private'], 'width': str(width),
            'height': str(height), 'nla': '0', 'clipboard': '0', 'audio': '0',
        }.items():
            check(lib.lrdp_set(session, key.encode(), value.encode()), f'Setting {key} rejected')
        check(lib.lrdp_start(session), 'Start failed')
        wait_for(lambda: lib.lrdp_state(session) not in (0, 1), 'Connect timed out', 10)
        connected()
        video = lib.lrdp_video_open(lib.lrdp_video_ticket(session))
        check(video, 'Video handle creation failed')
        wait_for(lambda: info() > 0, 'No native frame published')
        for name, target in stages:
            if target and not baseline:
                check(pacing(session, target) == 1, f'Dynamic rate {target} rejected')
            time.sleep(.25)
            connected()
            before = snapshot()
            generation = info()
            wall, cpu = time.monotonic(), time.process_time()
            time.sleep(1 if target is None and strict else spec['seconds'])
            cpu = time.process_time() - cpu
            wall = time.monotonic() - wall
            end = info()
            after = snapshot()
            connected()
            delta = end - generation
            fps = delta / wall
            sequence_delta = (after['producer_sequence_low16'] - before['producer_sequence_low16']) % 65536
            expected = source_fps if baseline or target is None else min(source_fps, target)
            sample = {
                'requested_rate': target, 'expected_publication_rate': expected,
                'wall_seconds': wall, 'client_cpu_seconds': cpu,
                'client_cpu_percent_one_core': cpu / wall * 100,
                'generation_start': generation, 'generation_end': end, 'generation_delta': delta,
                'published_frames_per_second': fps, 'producer_sequence_delta': sequence_delta,
                'producer_frames_per_second': sequence_delta / wall,
                'source_below_90_percent_target': sequence_delta / wall < source_fps * .9,
                'complete_frame': after,
            }
            report['samples'][name] = sample
            # Allow event-loop scheduling and host-load variation, while rejecting
            # an ignored rate request, a stalled stream or an unchanged local timer.
            if strict:
                check(expected * .90 <= fps <= expected * 1.10 + 2,
                      f'{name}: publication rate {fps:.2f} outside expected range for {expected} Hz')
            elif not baseline and target == 30 and source_fps >= 30:
                check(20 <= fps <= 35, f'{name}: publication rate {fps:.2f} outside 20..35 Hz')
            else:
                check(0 < fps <= expected * 1.10 + 2, f'{name}: publication rate {fps:.2f} is invalid')
            check(sequence_delta > 0, f'{name}: fixture pixels did not advance')
        if not baseline:
            rates = report['samples']
            if strict and all(str(rate) in rates for rate in (30, 120, 240)):
                check(rates['120']['published_frames_per_second'] >
                      rates['30']['published_frames_per_second'] * 2, '120 Hz did not exceed 30 Hz')
                check(rates['240']['published_frames_per_second'] >
                      rates['120']['published_frames_per_second'] * 1.3, '240 Hz did not exceed 120 Hz')
            for index in range(100):
                check(pacing(session, (30, 120, 240)[index % 3]) == 1, 'Rapid rate change rejected')
            check(pacing(session, 30) == 1, 'Final rate rejected')
        # D sends one full base plus two disjoint 2x2 updates, then the
        # producer is silent. A pending paced frame must flush without another PDU.
        # 2x2 avoids upstream's degenerate (0,0,1,1) invalidation edge case.
        expected_pixels = bytearray(bytes((128, 69, 117, 255)) * (width * height))
        for y in (0, 1):
            expected_pixels[y * width * 4:y * width * 4 + 8] = bytes((17, 41, 177, 255)) * 2
        for y in (height - 2, height - 1):
            offset = (y * width + width - 2) * 4
            expected_pixels[offset:offset + 8] = bytes((231, 59, 93, 255)) * 2
        expected_pixels = bytes(expected_pixels)
        settled = {}
        report['silent_final_damage'] = settled
        started = time.monotonic()
        check(lib.lrdp_input(session, 1, 0, 0x20, 0) == 1, 'D down rejected')
        check(lib.lrdp_input(session, 1, 0x8000, 0x20, 0) == 1, 'D release rejected')
        deadline = started + .3
        while True:
            pixels, generation = frame()
            matched = pixels == expected_pixels
            observed = time.monotonic()
            if matched or observed >= deadline:
                break
            time.sleep(min(.01, deadline - observed))
        settled.update(passed=matched and observed <= deadline,
                       observed_after_seconds=observed - started,
                       flush_latency_seconds=observed - started if matched else None,
                       generation=generation, complete_bytes=len(pixels),
                       top_left_bgra=list(pixels[:4]), bottom_right_bgra=list(pixels[-4:]),
                       center_bgra=list(pixels[((height // 2) * width + width // 2) * 4:][:4]))
        if not settled['passed']:
            settled['error'] = 'Silent final frame or disjoint damage was lost within 300ms'
            settled['wrong_byte_count'] = sum(actual != expected for actual, expected in zip(pixels, expected_pixels))
            settled['mismatched_coordinates'] = []
            for offset in range(0, len(pixels), 4):
                if pixels[offset:offset + 4] != expected_pixels[offset:offset + 4]:
                    settled['mismatched_coordinates'].append({
                        'x': (offset // 4) % width, 'y': offset // (width * 4),
                        'actual_bgra': list(pixels[offset:offset + 4]),
                        'expected_bgra': list(expected_pixels[offset:offset + 4]),
                    })
                    if len(settled['mismatched_coordinates']) == 8:
                        break
        check(settled['passed'], settled.get('error', 'Silent final frame was late'))
        check('Settled disjoint damage then silence' in Path(spec['server_log']).read_text(),
              'Fixture did not enter silent damage mode')
        generation = info()
        time.sleep(.1)
        settled['quiet_generation_delta'] = info() - generation
        check(0 <= settled['quiet_generation_delta'] <= 1, 'Repeated publications after producer silence')
        if matched:
            check(frame()[0] == expected_pixels, 'Settled frame was not preserved')
        check(lib.lrdp_input(session, 1, 0, 0x1e, 0) == 1, 'A down rejected')
        check(lib.lrdp_input(session, 1, 0x8000, 0x1e, 0) == 1, 'A release rejected')
        wait_for(lambda: 'client acknowledged=1' in Path(spec['server_log']).read_text(),
                 'Server did not receive completion input')
        report['input_acknowledged'] = True
        started = time.monotonic()
        lib.lrdp_stop(session)
        if not baseline:
            check(pacing(session, 30) == 0, 'Stopped session accepted a frame rate')
        lib.lrdp_destroy(session)
        session = None
        report['stop_and_destroy_seconds'] = time.monotonic() - started
        check(report['stop_and_destroy_seconds'] < 2, 'Stop/destroy exceeded two seconds')
        report['measurement_completed'] = True
        report['passed'] = settled['passed']
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        if session:
            lib.lrdp_stop(session)
            lib.lrdp_destroy(session)
        if video:
            lib.lrdp_video_close(video)
        Path(spec['result']).write_text(json.dumps(report, indent=2) + '\n')


def run_case(library, baseline, fixture, cert, key, pin, private, args):
    out = args.output.resolve()
    name = 'baseline' if baseline else 'current'
    library_digest = digest(library)
    directory = private / name
    directory.mkdir(mode=0o700)
    environment = dict(os.environ, XDG_CONFIG_HOME=str(directory / 'config'),
                       XDG_CACHE_HOME=str(directory / 'cache'), XDG_DATA_HOME=str(directory / 'data'),
                       WLOG_LEVEL='WARN')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    log_path = out / f'{name}-server.log'
    result_path = out / f'{name}-client.json'
    spec = {'library': str(library), 'baseline': baseline, 'port': port, 'pin': pin,
            'private': str(directory), 'server_log': str(log_path),
            'result': str(result_path), 'seconds': args.seconds, 'width': args.width,
            'height': args.height, 'source_fps': args.source_fps, 'rates': args.rates}
    spec_path = directory / 'client.json'
    spec_path.write_text(json.dumps(spec))
    with ExitStack() as cleanup:
        server_log = cleanup.enter_context(log_path.open('w'))
        server = subprocess.Popen([str(fixture), str(port), str(cert), str(key),
                                   '--size', str(args.width), str(args.height), '--fps', str(args.source_fps)],
                                  env=environment, stdout=server_log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, server)

        def listening():
            check(server.poll() is None, f'Fixture exited early; see {log_path}')
            # Connecting would consume the fixture's single peer.
            return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                       for line in Path('/proc/net/tcp').read_text().splitlines()[1:])

        wait_for(listening, 'Private fixture did not listen')
        log = cleanup.enter_context((out / f'{name}-client.log').open('w'))
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), '--client-config', str(spec_path)],
            env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=27)
        log.flush()
        check(completed.returncode == 0,
              f'{name} client failed: ' + (out / f'{name}-client.log').read_text()[-3500:])
        check(server.wait(timeout=3) == 0, 'Fixture did not acknowledge completion input')
    check(digest(library) == library_digest, 'Library changed during measurement; rerun')
    report = json.loads(result_path.read_text())
    report.update(library=str(library), library_sha256=library_digest, server_exit_code=server.returncode)
    check(report['passed'], f'{name} client validation failed')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=ROOT / 'build/native/liblrdp.so')
    parser.add_argument('--baseline-library', type=Path)
    parser.add_argument('--seconds', type=float, default=2, help='Per-rate CPU window, 1 to 3 seconds')
    parser.add_argument('--width', type=int, default=320)
    parser.add_argument('--height', type=int, default=240)
    parser.add_argument('--source-fps', type=int, default=240)
    parser.add_argument('--rates', type=int, nargs='+', default=[30, 120, 240, 30],
                        help='1 to 4 dynamic rates after the default unlimited window')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/frame-pacing-runtime')
    parser.add_argument('--client-config', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.client_config:
        client(json.loads(args.client_config.read_text()))
        return
    check(1 <= args.seconds <= 3, '--seconds must be between 1 and 3')
    check(200 <= args.width <= 1920 and 200 <= args.height <= 1080,
          'Client dimensions must be between 200x200 and 1920x1080')
    check(1 <= args.source_fps <= 240, '--source-fps must be between 1 and 240')
    check(1 <= len(args.rates) <= 4 and all(1 <= rate <= 240 for rate in args.rates),
          '--rates requires 1 to 4 rates in 1..240')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    stages = stage_list(args.rates)
    verdict = {
        'passed': False, 'protocol_passed': False,
        'scope': f'Linux private TLS loopback native ctypes client; {args.width}x{args.height} raw BGRA bitmaps '
                 f'at server target {args.source_fps} Hz; native published generation, not a UI timer. '
                 'Not AVC, Flutter rendering, whole-machine CPU or Android-device validation.',
        'fixture': {'width': args.width, 'height': args.height, 'source_target_fps': args.source_fps,
                    'dynamic_rates': args.rates, 'silent_corner_patch_size': '2x2'},
        'rate_validation': '320x240/240Hz: within 10% of min(requested, source), plus 2fps upper tolerance. '
                           'Other profiles: the 30Hz cap must publish 20..35fps; source shortfall is recorded. '
                           'CPU has no hard performance threshold.',
        'cpu_method': 'time.process_time()/time.monotonic() in a fresh client process per library; '
                      'includes native network/decode threads, excludes server and frame-copy probes; '
                      '100% equals one CPU core. Short descriptive samples, no hard CPU threshold.',
        'baseline_role': 'Optional unlimited CPU reference without any pacing calls; both libraries '
                         'must pass the complete-frame, silent-damage, input and stop checks.',
        'cases': {},
    }
    try:
        library = args.library.resolve(strict=True)
        baseline = args.baseline_library.resolve(strict=True) if args.baseline_library else None
        flags = shlex.split(subprocess.check_output([
            'pkg-config', '--cflags', '--libs', 'freerdp3', 'freerdp-server3', 'winpr3'], text=True))
        fixture = out / 'frame_rate_fixture'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                        str(ROOT / 'native/tests/frame_rate_fixture.c'), '-o', str(fixture), *flags], check=True)
        with tempfile.TemporaryDirectory(prefix='lrdp-frame-pacing-') as temporary:
            private = Path(temporary)
            cert, key = private / 'cert.pem', private / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
                            '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)],
                           check=True, capture_output=True)
            key.chmod(0o600)
            der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
            pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
            verdict['cases']['current'] = run_case(library, False, fixture, cert, key, pin, private, args)
            if baseline:
                verdict['cases']['baseline'] = run_case(baseline, True, fixture, cert, key, pin, private, args)
        verdict['protocol_passed'] = True
        current = verdict['cases']['current']['samples']
        verdict['cpu_comparison'] = {}
        for name, target in stages:
            comparison = {'current_cpu_percent_one_core': current[name]['client_cpu_percent_one_core']}
            if baseline:
                previous = verdict['cases']['baseline']['samples'][name]['client_cpu_percent_one_core']
                comparison.update(baseline_unlimited_cpu_percent_one_core=previous,
                                  reduction_vs_baseline_percent=(1 - comparison['current_cpu_percent_one_core'] / previous) * 100)
            verdict['cpu_comparison'][name] = comparison
        verdict['passed'] = True
    except Exception as error:
        verdict['error'] = f'{type(error).__name__}: {error}'
    (out / 'VERDICT.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    if not verdict['passed']:
        sys.exit(1)


if __name__ == '__main__':
    main()
