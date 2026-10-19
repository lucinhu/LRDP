#!/usr/bin/env python3
"""Real Android RDPSND/focus/lifecycle checks on the private muted LRDP AVD.

Observes the app's actual Android playback configurations and mixer progress.
This does not claim speaker audibility or sample-level Android wave recording.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', default='emulator-5556')
parser.add_argument('--adb-port', type=int, default=5038)
parser.add_argument('--avd-name', default='LRDP_API36_16k')
args = parser.parse_args()
if not args.avd_name.startswith('LRDP_') or not args.serial.startswith('emulator-') or args.adb_port != 5038:
    raise SystemExit('Only a private LRDP emulator on the dedicated ADB port is supported')
sdk = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Android/Sdk')))
output = root / 'build/android-audio-runtime'
output.mkdir(parents=True, exist_ok=True)
(output / 'VERDICT.json').unlink(missing_ok=True)
package = 'dev.lrdp.lrdp'
fixture_package = 'dev.lrdp.audiofixture'
adb = [str(sdk / 'platform-tools/adb'), '-P', str(args.adb_port), '-s', args.serial]
environment = dict(os.environ, JAVA_HOME=os.environ.get('LRDP_JAVA_HOME', '/usr/lib/jvm/java-17-openjdk'),
    ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk),
    LRDP_OPENSSL_ROOT=str(root / 'build/deps/android-openssl'),
    LRDP_FFMPEG_ROOT=str(root / 'build/deps/ffmpeg/android'),
    LRDP_BUILD_JOBS='3', CMAKE_BUILD_PARALLEL_LEVEL='3',
    ADB_SERVER_SOCKET='tcp:5038', ANDROID_ADB_SERVER_PORT='5038',
    FLUTTER_TEST_OUTPUTS_DIR=str(output))
environment['PATH'] = environment['JAVA_HOME'] + '/bin:/opt/flutter/bin:' + environment['PATH']


def android(*parts, check=True):
    return subprocess.run([*adb, *parts], env=environment, check=check,
        capture_output=True, text=True, timeout=30)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()


def until(predicate, reason, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.15)
    raise AssertionError(reason)


def build_focus_fixture():
    """A different UID requests transient focus while LRDP stays foreground."""
    folder = output / 'focus-fixture'
    classes = folder / 'classes'; classes.mkdir(parents=True, exist_ok=True)
    dex = folder / 'dex'; dex.mkdir(exist_ok=True)
    source = root / 'native/tests/android_audio_focus'
    platform = sdk / 'platforms/android-36/android.jar'
    kit = sdk / 'build-tools/36.0.0'
    with (folder / 'build.log').open('w') as log:
        def run(command):
            subprocess.run(command, env=environment, check=True, stdout=log, stderr=subprocess.STDOUT)
        run([str(Path(environment['JAVA_HOME']) / 'bin/javac'), '-source', '8', '-target', '8',
            '-classpath', str(platform), '-d', str(classes), str(source / 'FocusService.java')])
        run([str(kit / 'd8'), '--min-api', '26', '--lib', str(platform), '--output', str(dex),
            *map(str, classes.rglob('*.class'))])
        raw, aligned, apk = [folder / name for name in ('raw.apk', 'aligned.apk', 'focus.apk')]
        run([str(kit / 'aapt2'), 'link', '-I', str(platform), '--manifest', str(source / 'AndroidManifest.xml'),
            '-o', str(raw)])
        import zipfile
        with zipfile.ZipFile(raw, 'a') as archive:
            archive.write(dex / 'classes.dex', 'classes.dex')
        run([str(kit / 'zipalign'), '-f', '4', str(raw), str(aligned)])
        signing = dict(environment, LRDP_FIXTURE_KEYSTORE_PASSWORD='android')
        subprocess.run([str(kit / 'apksigner'), 'sign', '--ks', str(Path.home() / '.android/debug.keystore'),
            '--ks-pass', 'env:LRDP_FIXTURE_KEYSTORE_PASSWORD', '--key-pass', 'env:LRDP_FIXTURE_KEYSTORE_PASSWORD',
            '--out', str(apk), str(aligned)], env=signing, check=True, stdout=log, stderr=subprocess.STDOUT)
    android('install', '-r', str(apk))


observations = []


def snapshot(stage):
    audio = android('shell', 'dumpsys', 'audio').stdout
    flinger = android('shell', 'dumpsys', 'media.audio_flinger').stdout
    (output / (stage + '-audio.txt')).write_text(audio)
    (output / (stage + '-flinger.txt')).write_text(flinger)
    pids = android('shell', 'pidof', package, check=False).stdout.split()
    assert len(pids) == 1 and pids[0].isdigit(), ('Missing test app process', pids)
    pid = int(pids[0])
    # AudioPlaybackConfiguration's dump includes the owning uid/pid and state.
    monitor = audio.split('PlaybackActivityMonitor dump time:', 1)[1]
    live = monitor.split('\n  players:\n', 1)[1].split('\n  ducked players', 1)[0]
    players = [line.strip() for line in live.splitlines()
        if re.search(r'u/pid:\s*\d+/' + str(pid) + r'\b', line)]
    active = [line for line in players if re.search(r'state:\s*started\b', line, re.I)]
    tracks = []
    for block in re.findall(r'\d+ Tracks of which \d+ are active\s*\n(.*?)\n\s*\d+ Effect Chains', flinger, re.S):
        for line in block.splitlines():
            client = re.match(r'^\s*(?:[A-Za-z]+\s+)*(\d+)\s+(yes|no)\s+(\d+)/\s*(\d+)\s+', line)
            if not client or int(client[3]) != pid:
                continue
            counters = re.search(r'\b(?:true|false)\s+([0-9a-fA-F]{8,16})\s+\d+\s+\d+\s+\S+\s+(\d+)\s+\d+\s+(?:true|false)\s+(?:true|false)', line)
            assert counters, ('Unrecognized Android track counters', line)
            tracks.append({'id': int(client[1]), 'active': client[2] == 'yes',
                'frames_consumed': int(counters[1], 16), 'underrun_frames': int(counters[2])})
    frames = sum(int(n) for n in re.findall(r'Frames written:\s*(\d+)', flinger))
    result = {'stage': stage, 'pid': pid, 'players': players, 'started': active,
        'tracks': tracks, 'mixer_frames_written': frames}
    observations.append(result)
    return result


def assert_playing(stage):
    first = snapshot(stage)
    assert first['started'], ('No started Android track belonging to LRDP', first)
    time.sleep(.5)
    second = snapshot(stage + '-progress')
    assert second['started'], second
    first_tracks = {track['id']: track for track in first['tracks']}
    progressing = [track for track in second['tracks'] if track['id'] in first_tracks and track['active']
        and track['frames_consumed'] - first_tracks[track['id']]['frames_consumed'] >= 12000]
    assert progressing, ('No LRDP-owned track consumed at least 250 ms of PCM', first, second)
    assert all(track['underrun_frames'] == first_tracks[track['id']]['underrun_frames'] for track in progressing), \
        ('LRDP track underruns during steady playback', first, second)


def assert_paused(stage):
    def quiet():
        current = snapshot(stage)
        return not current['players'] and not current['tracks']
    until(quiet, stage + ': LRDP retains a playback device')
    # A status flag alone is insufficient: the platform player must stop too.
    time.sleep(.3)
    stable = snapshot(stage + '-stable')
    assert not stable['players'] and not stable['tracks']


def foreground():
    android('shell', 'am', 'start', '--activity-reorder-to-front', '--activity-single-top',
        '-n', package + '/.MainActivity')


def release_companion():
    # This API36 shell image returns 255 even for "Service stopped". Verify
    # the authoritative service/focus state instead of treating that as failure.
    result = android('shell', 'am', 'stopservice', '--user', '0', '-n', fixture_package + '/.FocusService', check=False)
    assert 'Service stopped' in result.stdout + result.stderr, (result.stdout, result.stderr)
    until(lambda: 'ServiceRecord' not in android('shell', 'dumpsys', 'activity', 'services', fixture_package).stdout,
        'Companion service did not stop')


assert args.avd_name in android('emu', 'avd', 'name').stdout.splitlines(), 'Wrong AVD'
until(lambda: android('shell', 'getprop', 'sys.boot_completed', check=False).stdout.strip() == '1',
    'Private emulator still booting; re-poll the existing device', timeout=180)
assert android('shell', 'getconf', 'PAGE_SIZE').stdout.strip() == '16384'
assert int(android('shell', 'getprop', 'ro.build.version.sdk').stdout.strip()) == 36
view = root / 'build/android-sdk-view'
for relative in ('build-tools/36.0.0', 'platforms/android-36', 'platform-tools', 'emulator', 'cmdline-tools', 'ndk', 'cmake', 'licenses'):
    destination = view / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() and (sdk / relative).exists():
        destination.symlink_to(sdk / relative, target_is_directory=True)
drive_environment = dict(environment, ANDROID_HOME=str(view), ANDROID_SDK_ROOT=str(view))

with tempfile.TemporaryDirectory(prefix='lrdp-android-audio-') as temp, ExitStack() as cleanup:
    private = Path(temp)
    definitions = base64.b64encode(b'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false').decode()
    print('Building isolated x86_64 Android audio integration APK', flush=True)
    log = cleanup.enter_context((output / 'build.log').open('w'))
    subprocess.run([str(root / 'android/gradlew'), '--no-daemon', '--max-workers=3', '-Dorg.gradle.jvmargs=-Xmx2g',
        ':app:assembleDebug', '-Ptarget-platform=android-x64',
        f'-Ptarget={root / "integration_test/android_audio_test.dart"}', f'-Pdart-defines={definitions}'],
        cwd=root / 'android', env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    apk = output / 'audio-integration-x86_64.apk'
    shutil.copy2(root / 'build/app/outputs/apk/debug/app-debug.apk', apk)
    subprocess.run(['python3', str(root / 'scripts/check_android_apk.py'), str(apk), '--abi', 'x86_64', '--integration'],
        env=environment, check=True)
    build_focus_fixture()
    cleanup.callback(android, 'uninstall', fixture_package, check=False)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
        'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
    fixture = output / 'audio_fixture'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
        str(root / 'native/tests/audio_fixture.c'), '-o', str(fixture), *flags, '-lm'], check=True)
    cert, key = private / 'cert.pem', private / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    pin = ':'.join(f'{b:02x}' for b in hashlib.sha256(subprocess.check_output([
        'openssl', 'x509', '-in', str(cert), '-outform', 'DER'])).digest())
    peers, ports = [], []
    for i in range(2):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        ports.append(port)
        peer_log = cleanup.enter_context((output / f'peer-{i}.log').open('w'))
        # The first connection also covers two external focus interruptions;
        # keep sending new samples throughout the slower dumpsys observations.
        chunks = '1000' if i == 0 else '400'
        peer = subprocess.Popen([str(fixture), str(port), str(cert), str(key), 'on' if i == 0 else 'pcm8', '300000', chunks],
            stdout=peer_log, stderr=subprocess.STDOUT)
        peers.append(peer); cleanup.callback(stop, peer)
        until(lambda: any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
            for line in Path('/proc/net/tcp').read_text().splitlines()[1:]), 'Peer listener')
        android('reverse', f'tcp:{port}', f'tcp:{port}')
        cleanup.callback(android, 'reverse', '--remove', f'tcp:{port}', check=False)
    android('shell', 'am', 'force-stop', package)
    android('shell', 'run-as', package, 'rm', '-f', 'files/lrdp-audio-stage', check=False)
    driver_log = cleanup.enter_context((output / 'driver.log').open('w'))
    driver = subprocess.Popen(['flutter', 'drive', '--no-pub', '-d', args.serial,
        '--target', 'integration_test/android_audio_test.dart', '--driver', 'test_driver/android_runtime.dart',
        '--use-application-binary', str(apk)], env=drive_environment, cwd=root,
        stdout=driver_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, driver)
    cleanup.callback(android, 'shell', 'am', 'force-stop', package, check=False)
    cleanup.callback(android, 'shell', 'am', 'stopservice', '-n', fixture_package + '/.FocusService', check=False)
    stages = set(); deadline = time.monotonic() + 450
    while driver.poll() is None and time.monotonic() < deadline:
        stage = android('exec-out', 'run-as', package, 'cat', 'files/lrdp-audio-stage', check=False).stdout.strip()
        if re.fullmatch(r'[a-z]+(?:-[a-z0-9]+)*', stage) and stage not in stages:
            print('Android audio stage:', stage, flush=True)
            if stage == 'config':
                subprocess.run([*adb, 'shell', 'run-as', package, 'tee', 'files/lrdp-audio-config.tmp'],
                    input=json.dumps({'ports': ports, 'pin': pin}), env=environment, text=True, check=True, capture_output=True)
                android('shell', 'run-as', package, 'mv', 'files/lrdp-audio-config.tmp', 'files/lrdp-audio-config.json')
            elif stage.startswith(('playing-', 'resumed-', 'reactivated-', 'focus-restored-')):
                assert_playing(stage)
            elif stage.startswith(('before-', 'paused-', 'inactive-', 'closed-', 'focus-paused-')):
                assert_paused(stage)
            elif stage.startswith('background-'):
                android('shell', 'input', 'keyevent', 'KEYCODE_HOME')
            elif stage.startswith('foreground-'):
                foreground()
            elif stage.startswith('steal-'):
                gain = '3' if stage == 'steal-duck' else '2'
                android('shell', 'am', 'start-foreground-service', '-n', fixture_package + '/.FocusService', '--ei', 'gain', gain)
                state = android('shell', 'dumpsys', 'audio').stdout
                (output / (stage + '-focus.txt')).write_text(state)
                until(lambda: fixture_package in android('shell', 'dumpsys', 'audio').stdout.split(
                    'Audio Focus stack entries', 1)[1].split('No external focus policy', 1)[0], 'Companion service did not acquire focus')
            elif stage.startswith('release-'):
                release_companion()
            elif stage.startswith('stream-complete-'):
                i = int(stage.rsplit('-', 1)[1])
                until(lambda: '"audio_stream_complete":true' in (output / f'peer-{i}.log').read_text(),
                    'RDP peer did not finish streaming', timeout=80)
            else:
                raise AssertionError('Unexpected audio stage: ' + stage)
            android('shell', 'run-as', package, 'touch', f'files/lrdp-audio-{stage}.ack')
            stages.add(stage)
        time.sleep(.2)
    assert driver.poll() == 0, 'Android integration failed; see ' + str(output / 'driver.log')
    assert 'All tests passed!' in (output / 'driver.log').read_text(), 'Driver did not report test success'
    for i, peer in enumerate(peers):
        assert peer.wait(timeout=10) == 0, (output / f'peer-{i}.log').read_text()[-3000:]
    expected = {'config'} | {f'{name}-{i}' for i in range(2) for name in (
        'before', 'playing', 'background', 'paused', 'foreground', 'resumed', 'inactive', 'reactivated', 'stream-complete', 'closed')}
    expected |= {f'{name}-{kind}' for name in ('steal', 'focus-paused', 'release', 'focus-restored') for kind in ('transient', 'duck')}
    assert expected.issubset(stages), expected - stages
    import zipfile
    with zipfile.ZipFile(apk) as archive:
        native = archive.read('lib/x86_64/liblrdp.so')
    verdict = {'passed': True, 'native_abi': 5, 'platform': 'Android API36 x86_64 16KiB',
        'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'library_sha256': hashlib.sha256(native).hexdigest(), 'iterations': 2,
        'stages': sorted(stages), 'observations': observations,
        'scope': 'actual LRDP-owned Android playback tracks, mixer frame progress, background/inactive/focus loss and regain, device release; host output disabled',
        'physical_device': False, 'waveform_capture': False}
    (output / 'VERDICT.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print('PASS: actual Android audio playback, background/inactive/focus policy and release', flush=True)
