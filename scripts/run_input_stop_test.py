#!/usr/bin/env python3
"""Private TLS input-release oracle plus actual TCP backpressure cancellation."""
from contextlib import ExitStack
from pathlib import Path
import argparse
import hashlib
import json
import os
import shlex
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
assert not (args.library and args.wine)
build = (args.build or root/('build/windows-x64' if args.wine else 'build/native')).resolve()
library = (args.library or build/('lrdp.dll' if args.wine else 'liblrdp.so')).resolve()
kind = 'wine' if args.wine else 'asan' if 'asan' in build.name else 'native'
if args.library: kind += '-custom'
out = root/'build/input-stop-runtime'/kind
out.mkdir(parents=True, exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()


flags = shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','freerdp-server3','freerdp3','winpr3'], text=True))
fixture = out/'input_stop_fixture'
subprocess.run(['cc','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations',
    str(root/'native/tests/input_stop_fixture.c'),'-o',str(fixture),*flags],check=True)
client = build/('lrdp_input_stop_test.exe' if args.wine else 'lrdp_input_stop_test')
assert client.exists(), 'Build the input stop client first'
environment = dict(os.environ, WLOG_LEVEL='WARN', LD_LIBRARY_PATH=str(library.parent)+':'+os.environ.get('LD_LIBRARY_PATH',''))
if kind == 'asan':
    environment.update(ASAN_OPTIONS='detect_leaks=1:halt_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
if args.wine:
    prefix = root/'build/windows-runtime/wineprefix'
    assert (prefix/'.update-timestamp').exists(), 'Initialize the private Wine prefix first'
    environment.update(WINEPREFIX=str(prefix),WINEDEBUG='-all',DISPLAY='',WINEDLLOVERRIDES='mscoree,mshtml=')
results = []
with tempfile.TemporaryDirectory(prefix='lrdp-input-stop-') as temporary:
    private = Path(temporary)
    cert, key = private/'cert.pem', private/'key.pem'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-noenc','-days','1','-subj','/CN=localhost',
        '-keyout',str(key),'-out',str(cert)],capture_output=True,check=True)
    der = subprocess.check_output(['openssl','x509','-in',str(cert),'-outform','DER'])
    pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
    for mode in ('normal','blocked'):
        with ExitStack() as cleanup:
            config = str(private/mode)
            if args.wine:
                config = subprocess.check_output(['winepath','-w',config],env=environment,text=True).strip()
            with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
            server_log = cleanup.enter_context((out/(mode+'-server.log')).open('w'))
            server = subprocess.Popen([str(fixture),str(port),str(cert),str(key),mode],env=environment,
                stdout=server_log,stderr=subprocess.STDOUT);cleanup.callback(stop,server)
            deadline = time.monotonic()+10
            while time.monotonic()<deadline:
                if any(line.split()[1]==f'0100007F:{port:04X}' and line.split()[3]=='0A'
                    for line in Path('/proc/net/tcp').read_text().splitlines()[1:]):break
                assert server.poll() is None, (out/(mode+'-server.log')).read_text()
                time.sleep(.05)
            else:raise AssertionError('Private input fixture did not listen')
            log = cleanup.enter_context((out/(mode+'-client.log')).open('w'))
            completed = subprocess.run((['wine'] if args.wine else [])+[str(client),str(port),pin,config,mode],
                env=environment,stdout=log,stderr=subprocess.STDOUT,timeout=45)
            log.flush();server_log.flush()
            assert completed.returncode==0, (out/(mode+'-client.log')).read_text()[-3500:]
            report = next(json.loads(line) for line in (out/(mode+'-client.log')).read_text().splitlines()
                if line.startswith('{"passed"'))
            assert '{"drag_and_clicks_acknowledged":true}' in (out/(mode+'-server.log')).read_text()
            report['drag_and_follow_up_clicks'] = True
            if mode=='normal':
                assert server.wait(timeout=5)==0, (out/(mode+'-server.log')).read_text()[-3500:]
                report['wire_releases'] = next(json.loads(line) for line in (out/(mode+'-server.log')).read_text().splitlines()
                    if line.startswith('{"passed"'))
                assert report['wire_releases']['passed']
                assert report['wire_releases']['drag_and_follow_up_clicks']
                assert report['wire_releases']['combined_mouse_events'] == 0
            else:
                assert '{"held_acknowledged":true}' in (out/(mode+'-server.log')).read_text()
                assert report['pressure_inputs']>1024
                report['remote_release_guaranteed'] = False
            results.append(report)
            print('PASS: actual input stop '+kind+' '+mode,flush=True)
(out/'VERDICT.json').write_text(json.dumps({'passed':True,'native_abi':5,
    'library_sha256':hashlib.sha256(library.read_bytes()).hexdigest(),'cases':results,
    'scope':'actual TLS input PDUs with KRDP DOWN/MOVE/RELEASE precedence; drag, follow-up left/right/middle clicks and exact coordinates; delivered states only, modifier order, Unicode units, three mouse buttons; bounded stop with receiver not reading'},indent=2)+'\n')
