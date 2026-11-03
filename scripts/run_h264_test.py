#!/usr/bin/env python3
"""Real AVC420 over a private TLS RDPGFX loopback; no user desktop or credentials.

Requires system freerdp-server3 development packages, ffmpeg/libx264 and openssl.
Only the standalone server is compiled here; the client library must exist.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 320, 240
FRAME_BYTES = WIDTH * HEIGHT * 4
BACKENDS = {0: 'pending', 1: 'CPU', 2: 'VAAPI', 3: 'CUDA'}


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for(predicate, message, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError(message)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def run(command, **kwargs):
    return subprocess.run(command, check=True, timeout=30, **kwargs)


def generate(output):
    """AUD-delimited AU packets: one baseline IDR then eight predicted frames."""
    colors = [(190, 45, 45), (45, 190, 45), (45, 45, 190)]
    raw = b''.join(bytes(color) * (WIDTH * HEIGHT) * 3 for color in colors)
    stream = output / 'frames.h264'
    # RDP's graphics YUV conversion uses BT.709 full range. Specify both the
    # actual RGB->YUV transform and SPS metadata so FFmpeg's reference agrees.
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo',
         '-pixel_format', 'rgb24', '-video_size', f'{WIDTH}x{HEIGHT}', '-framerate', '3',
         '-i', 'pipe:0', '-an', '-vf', 'scale=out_color_matrix=bt709:out_range=pc',
         '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'baseline',
         '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'pc',
         '-preset', 'fast', '-tune', 'zerolatency', '-qp', '20', '-x264-params',
         'aud=1:repeat-headers=1:keyint=120:min-keyint=120:scenecut=0:bframes=0',
         '-f', 'h264', str(stream)], input=raw)
    encoded = stream.read_bytes()
    starts = list(re.finditer(b'\x00\x00\x00?\x01', encoded))
    units = [(m.start(), encoded[m.end()] & 31) for m in starts]
    aud = [offset for offset, kind in units if kind == 9]
    check(len(aud) == 9 and aud[0] == 0, f'Expected 9 AUD access units, got {len(aud)}')
    check({1, 5, 7, 8}.issubset({kind for _, kind in units}), 'Missing P/IDR/SPS/PPS NAL units')
    paths = []
    for index, start in enumerate(aud):
        path = output / f'au-{index:02}.h264'
        path.write_bytes(encoded[start:aud[index + 1] if index + 1 < len(aud) else len(encoded)])
        paths.append(path)
    reference = output / 'reference.bgra'
    run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(stream),
         '-f', 'rawvideo', '-pix_fmt', 'bgra', str(reference)])
    check(reference.stat().st_size == 9 * FRAME_BYTES, 'Unexpected FFmpeg reference dimensions')
    return paths, {'frames': 9, 'profile': 'baseline', 'pixel_format': 'yuv420p', 'qp': 20,
                   'color_matrix': 'bt709', 'color_range': 'full',
                   'nal_types': sorted({kind for _, kind in units}),
                   'h264_sha256': hashlib.sha256(encoded).hexdigest()}


def client(spec):
    lib = C.CDLL(spec['library'])
    ptr, integer = C.c_void_p, C.c_int
    i32p, u64p = C.POINTER(C.c_int32), C.POINTER(C.c_uint64)
    signatures = {
        'lrdp_initialize': ([C.c_char_p], integer), 'lrdp_create': ([], ptr),
        'lrdp_set': ([ptr, C.c_char_p, C.c_char_p], integer), 'lrdp_start': ([ptr], integer),
        'lrdp_state': ([ptr], integer), 'lrdp_features': ([ptr], integer),
        'lrdp_get_decoder_backend': ([ptr], integer),
        'lrdp_read': ([ptr, integer, ptr, C.c_size_t], integer),
        'lrdp_frame': ([ptr, ptr, C.c_size_t, i32p, i32p, u64p], integer),
        'lrdp_input': ([ptr, integer, integer, integer, integer], integer),
        'lrdp_stop': ([ptr], None), 'lrdp_destroy': ([ptr], None),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(lib, name)
        function.argtypes, function.restype = arguments, result
    report = {'passed': False, 'observed_colors': [], 'backend_history': []}
    session = None
    try:
        check(lib.lrdp_initialize(spec['private'].encode()), 'Private initialization failed')
        session = lib.lrdp_create()
        check(session, 'Session creation failed')
        for key, value in {
            'host': '127.0.0.1', 'port': str(spec['port']), 'username': 'h264-loopback',
            'fingerprint': spec['pin'], 'config_path': spec['private'], 'width': str(WIDTH),
            'height': str(HEIGHT), 'nla': '0', 'clipboard': '0', 'audio': '0', 'quality': '0',
        }.items():
            check(lib.lrdp_set(session, key.encode(), value.encode()), f'Setting {key} rejected')
        check(lib.lrdp_get_decoder_backend(session) == 0, 'Backend reported before decoding')
        check(lib.lrdp_start(session), 'Start failed')
        wait_for(lambda: lib.lrdp_state(session) not in (0, 1), 'Connect timed out')
        error = C.create_string_buffer(2048)
        lib.lrdp_read(session, 0, error, len(error))
        check(lib.lrdp_state(session) == 2, f'Connect failed: {error.value.decode(errors="replace")}')
        references = Path(spec['reference']).read_bytes()
        expected = [references[i * FRAME_BYTES:(i + 1) * FRAME_BYTES] for i in (0, 3, 6)]
        pixels = (C.c_uint8 * FRAME_BYTES)()
        w, h, generation = C.c_int32(), C.c_int32(), C.c_uint64()
        seen = set()
        deadline = time.monotonic() + 12
        last_generation = 0
        while time.monotonic() < deadline:
            state = lib.lrdp_state(session)
            lib.lrdp_read(session, 0, error, len(error))
            check(state == 2, f'Connection ended during AVC420: {error.value.decode(errors="replace")}')
            backend = lib.lrdp_get_decoder_backend(session)
            if not report['backend_history'] or report['backend_history'][-1] != backend:
                report['backend_history'].append(backend)
            size = lib.lrdp_frame(session, pixels, len(pixels), C.byref(w), C.byref(h), C.byref(generation))
            if size > 0:
                check(size == FRAME_BYTES and (w.value, h.value) == (WIDTH, HEIGHT), 'Unexpected decoded dimensions')
                frame = bytes(pixels)
                samples = [4 * (y * WIDTH + x) for x, y in ((0, 0), (160, 120), (319, 239))]
                report.setdefault('snapshots', []).append({'generation': generation.value,
                    'samples_bgra': [list(frame[p:p + 4]) for p in samples],
                    'expected_bgra': [list(reference[:4]) for reference in expected],
                    'backend': backend, 'features': lib.lrdp_features(session)})
                for index, reference in enumerate(expected):
                    if index in seen:
                        continue
                    if all(abs(frame[p + c] - reference[p + c]) <= 5 for p in samples for c in range(3)):
                        # Compare every RGB pixel, not just a frame counter or feature bit.
                        maximum = max(abs(a - b) for p in range(0, FRAME_BYTES, 4)
                                      for a, b in zip(frame[p:p + 3], reference[p:p + 3]))
                        check(maximum <= 5, f'Partial/incorrect color {index}: max RGB error {maximum}')
                        seen.add(index)
                        report['observed_colors'].append({'index': index, 'generation': generation.value,
                            'bgra': list(frame[:4]), 'max_rgb_error_vs_ffmpeg': maximum})
                last_generation = generation.value
            if seen == {0, 1, 2} and 'AVC420 final frame then silence' in Path(spec['server_log']).read_text():
                break
            time.sleep(.02)
        check(seen == {0, 1, 2}, f'Missing decoded color transitions: {sorted(seen)}')
        feature_mask = lib.lrdp_features(session)
        backend = lib.lrdp_get_decoder_backend(session)
        check(feature_mask & 4, 'No successfully decoded AVC420 feature bit')
        check(backend in (1, 2, 3), f'No actual decoder backend: {backend}')
        time.sleep(.2)
        # The last access unit is not followed by another packet that could flush it.
        generation.value = 0
        size = lib.lrdp_frame(session, pixels, len(pixels), C.byref(w), C.byref(h), C.byref(generation))
        check(size == FRAME_BYTES, 'Missing final silent snapshot')
        reference = expected[2]
        check(all(abs(pixels[p + c] - reference[p + c]) <= 5
                  for p in range(0, FRAME_BYTES, 4) for c in range(3)), 'Final silent frame incorrect')
        report.update(features=feature_mask, backend=backend, backend_name=BACKENDS[backend],
                      final_generation=generation.value, prior_generation=last_generation)
        check(lib.lrdp_input(session, 1, 0, 0x1e, 0), 'A key press rejected')
        check(lib.lrdp_input(session, 1, 0x8000, 0x1e, 0), 'A key release rejected')
        wait_for(lambda: 'Input A acknowledged' in Path(spec['server_log']).read_text(), 'Server did not receive input A')
        start = time.monotonic()
        lib.lrdp_stop(session)
        lib.lrdp_destroy(session)
        session = None
        report['stop_destroy_seconds'] = time.monotonic() - start
        check(report['stop_destroy_seconds'] < 3, 'Stop/destroy stalled')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
    finally:
        if session:
            lib.lrdp_stop(session)
            lib.lrdp_destroy(session)
        Path(spec['result']).write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=ROOT / 'build/native/liblrdp.so')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/h264-runtime')
    parser.add_argument('--prepare-only', action='store_true', help='Compile server and generate/reference AVC420 without loading client')
    parser.add_argument('--client-config', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.client_config:
        return client(json.loads(args.client_config.read_text()))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    verdict = {'passed': False, 'scope': 'private 127.0.0.1 TLS RDPGFX AVC420, baseline YUV420P IDR/P, FFmpeg pixel oracle; no user desktop',
               'library': str(args.library.resolve()), 'hardware_required': False}
    try:
        fixture = output / 'h264_gfx_fixture'
        flags = shlex.split(run(['pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'],
                                capture_output=True, text=True).stdout)
        command = ['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                   str(ROOT / 'native/tests/h264_gfx_fixture.c'), '-o', str(fixture), *flags]
        run(command, capture_output=True, text=True)
        verdict['compile_command'] = command
        packets, verdict['stream'] = generate(output)
        if args.prepare_only:
            verdict['prepared_only'] = True
            print(json.dumps(verdict, indent=2))
            return 0
        check(args.library.is_file(), f'Client library missing: {args.library}')
        verdict['library_sha256'] = hashlib.sha256(args.library.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix='lrdp-h264-') as temporary:
            private = Path(temporary)
            cert, key = private / 'certificate.pem', private / 'private-key.pem'
            run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', '1', '-nodes',
                 '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], capture_output=True)
            key.chmod(0o600)
            der = run(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'], capture_output=True).stdout
            pin = ':'.join(f'{byte:02x}' for byte in hashlib.sha256(der).digest())
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            server_log = output / 'server.log'
            with server_log.open('w') as server_output:
                server = subprocess.Popen([str(fixture), str(port), str(cert), str(key), *map(str, packets)],
                                          stdout=server_output, stderr=subprocess.STDOUT)
                try:
                    def listening():
                        check(server.poll() is None, 'Fixture exited before listening')
                        return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                                   for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
                    wait_for(listening, 'Private fixture did not listen')
                    spec = {'library': str(args.library.resolve()), 'port': port, 'pin': pin,
                            'private': str(private), 'reference': str(output / 'reference.bgra'),
                            'server_log': str(server_log), 'result': str(output / 'client-result.json')}
                    spec_path = private / 'client-spec.json'
                    spec_path.write_text(json.dumps(spec))
                    with (output / 'client.log').open('w') as client_output:
                        result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                                 '--client-config', str(spec_path)],
                                                stdout=client_output, stderr=subprocess.STDOUT, timeout=23)
                    if Path(spec['result']).is_file():
                        verdict['client'] = json.loads(Path(spec['result']).read_text())
                    check(result.returncode == 0, f'Client failed; see {output / "client.log"} and client-result.json')
                    server.wait(timeout=3)
                    check(server.returncode == 0, f'Fixture failed ({server.returncode}); see server.log')
                    verdict['passed'] = True
                finally:
                    stop(server)
    except Exception as error:
        verdict['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            verdict['command_stderr'] = (error.stderr or b'').decode(errors='replace') if isinstance(error.stderr, bytes) else error.stderr
    finally:
        (output / 'VERDICT.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    return 0 if verdict['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
