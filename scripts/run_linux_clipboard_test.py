#!/usr/bin/env python3
"""Actual Flutter Linux plugin and independent GTK owner on private Xvnc."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent.parent
out=ROOT/'build/image-clipboard/linux-os';out.mkdir(parents=True,exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)
flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','gtk+-3.0'],text=True))
subprocess.run(['cc','-Wall','-Wextra','-Werror',str(ROOT/'native/tests/linux_clipboard_peer.c'),'-o',str(out/'peer'),*flags],check=True)
processes=[]
try:
    with tempfile.TemporaryDirectory(prefix='lrdp-os-image-') as temporary:
        directory=Path(temporary)
        number=next(n for n in range(101,201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
        env=dict(os.environ,DISPLAY=f':{number}',GDK_BACKEND='x11',WAYLAND_DISPLAY='',
            XDG_CONFIG_HOME=str(directory/'config'),XDG_DATA_HOME=str(directory/'data'),
            XDG_CACHE_HOME=str(directory/'cache'),LRDP_IMAGE_CONTROL=temporary,LRDP_BUILD_JOBS='3',
            CMAKE_BUILD_PARALLEL_LEVEL='3',LRDP_FFMPEG_ROOT=str(ROOT/'build/deps/ffmpeg/linux-x64'))
        with (out/'display.log').open('w') as log:
            display=subprocess.Popen(['Xvnc',env['DISPLAY'],'-geometry','1000x800','-depth','24',
                '-SecurityTypes','None','-noreset','-rfbport','-1','-rfbunixpath',str(directory/'vnc.sock'),
                '-rfbunixmode','0600','-nolisten','tcp'],env=env,stdout=log,stderr=subprocess.STDOUT)
            processes.append(display)
            for _ in range(200):
                assert display.poll() is None
                if Path(f'/tmp/.X11-unix/X{number}').exists(): break
                time.sleep(.05)
            else: raise AssertionError('private display')
            with (out/'peer.log').open('w') as peer_log:
                peer=subprocess.Popen([str(out/'peer'),temporary],env=env,stdout=peer_log,stderr=subprocess.STDOUT)
                processes.append(peer)
                for _ in range(200):
                    assert peer.poll() is None
                    if (directory/'ready').exists(): break
                    time.sleep(.05)
                else: raise AssertionError('GTK clipboard owner')
                with (out/'flutter.log').open('w') as flutter_log:
                    subprocess.run(['dbus-run-session','--','flutter','test','integration_test/clipboard_image_test.dart',
                        '-d','linux','--no-pub','--reporter','expanded'],cwd=ROOT,env=env,stdout=flutter_log,
                        stderr=subprocess.STDOUT,check=True,timeout=600)
                result=json.loads((directory/'verified.json').read_text());assert result['passed']
                (out/'VERDICT.json').write_text(json.dumps({'passed':True,'platform':'Linux X11',
                    'plugin_sha256':hashlib.sha256((ROOT/'build/linux/x64/debug/bundle/lib/liblrdp_native_plugin.so').read_bytes()).hexdigest(),
                    'clipboard_dart_sha256':hashlib.sha256((ROOT/'lib/ui/image_clipboard.dart').read_bytes()).hexdigest(),
                    'scope':'real Flutter method channel, independent GTK read/write, 8 repeated roundtrips, invalid-write preservation'},indent=2)+'\n')
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
