#!/usr/bin/env python3
"""Native Linux texture pixels captured from a real private X11 application."""
from contextlib import ExitStack
from pathlib import Path
import argparse,hashlib,json,os,socket,subprocess,tempfile,time
from PIL import ImageGrab

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--fail-gpu',action='store_true');args=parser.parse_args()
out=root/('build/video-ui-fallback-runtime' if args.fail_gpu else 'build/video-ui-runtime');out.mkdir(parents=True,exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)
def stop(p):
    if p.poll() is None:
        p.terminate()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait()
def until(ready,reason,timeout=40):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if ready():return
        time.sleep(.1)
    raise AssertionError(reason)
with tempfile.TemporaryDirectory(prefix='lrdp-video-ui-') as temporary,ExitStack() as cleanup:
    private=Path(temporary);displays=[]
    env=dict(os.environ,LRDP_FFMPEG_ROOT=str(root/'build/deps/ffmpeg/linux-x64'),LRDP_BUILD_JOBS='3',
        CMAKE_BUILD_PARALLEL_LEVEL='3',LRDP_VIDEO_TRACE='1',GDK_BACKEND='x11',GDK_SCALE='1',XDG_CONFIG_HOME=str(private/'config'))
    env.pop('LRDP_NATIVE_LIBRARY',None);env.pop('LRDP_DISABLE_TEXTURES',None)
    if args.fail_gpu:env['LRDP_VIDEO_TEST_FAIL_UPLOAD']='1'
    else:env.pop('LRDP_VIDEO_TEST_FAIL_UPLOAD',None)
    for side,size in [('server','1280x800'),('client','1400x1000')]:
        n=next(n for n in range(101,201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
        target=dict(env,DISPLAY=f':{n}')
        log=cleanup.enter_context((out/(side+'-display.log')).open('w'))
        p=subprocess.Popen(['Xvnc',target['DISPLAY'],'-geometry',size,'-depth','24','-SecurityTypes','None','-noreset',
            '-rfbport','-1','-rfbunixpath',str(private/(side+'.sock')),'-rfbunixmode','0600','-nolisten','tcp'],env=target,stdout=log,stderr=subprocess.STDOUT)
        cleanup.callback(stop,p);until(lambda:Path(f'/tmp/.X11-unix/X{n}').exists(),'Private X did not start')
        displays.append(target)
    server_env,client_env=displays
    def color(rgb):subprocess.run(['xsetroot','-solid',rgb],env=server_env,check=True)
    color('#182d28')
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    log=cleanup.enter_context((out/'server.log').open('w'))
    server=subprocess.Popen(['freerdp-shadow-cli3','/bind-address:127.0.0.1',f'/port:{port}','/sec:tls','-auth',
        '+may-view','+may-interact','-gfx-avc420','-gfx-avc444','/log-level:WARN'],env=server_env,stdout=log,stderr=subprocess.STDOUT)
    cleanup.callback(stop,server)
    until(lambda:any(l.split()[1]==f'0100007F:{port:04X}' and l.split()[3]=='0A' for l in Path('/proc/net/tcp').read_text().splitlines()[1:]),'Private RDP did not listen')
    client_env.update(LRDP_VIDEO_PORT=str(port),LRDP_VIDEO_CONTROL=str(private))
    log=cleanup.enter_context((out/'flutter.log').open('w'))
    client=subprocess.Popen(['flutter','test','integration_test/native_video_test.dart','-d','linux','--no-pub','--reporter','expanded'],
        cwd=root,env=client_env,stdout=log,stderr=subprocess.STDOUT);cleanup.callback(stop,client)
    seen=[];observed=[];deadline=time.monotonic()+600
    while client.poll() is None and time.monotonic()<deadline:
        path=private/'stage.json'
        if path.exists():
            meta=json.loads(path.read_text());name=meta['stage']
            if name not in seen:
                expected=[(meta['background'],meta['rgb'])]+list(zip(meta['cursor'],[[0,0,0],[255,255,255],meta['rgb'],[255-v for v in meta['rgb']]]))
                def pixels_match():
                    image=ImageGrab.grab(xdisplay=client_env['DISPLAY']).convert('RGB')
                    image.save(out/(name+'.png'))
                    return all(max(abs(a-b) for a,b in zip(image.getpixel(tuple(p)),rgb))<=5 for p,rgb in expected)
                (out/(name+'.json')).write_text(json.dumps(meta,indent=2)+'\n')
                until(pixels_match,'Native texture color/XOR mismatch at '+name,12)
                seen.append(name);observed.append(meta)
                (out/(name+'.json')).write_text(json.dumps(meta,indent=2)+'\n')
                if name=='base':color('#8a3bc1')
                elif name=='hidden':color('#2a8465')
                (private/(name+'.ack')).touch()
                print('PASS native texture pixels:',name,flush=True)
        time.sleep(.1)
    assert client.wait(timeout=10)==0,'Native video test failed: '+str(out/'flutter.log')
    assert seen==['base','updated','hidden','still-hidden','resumed','zoomed'],seen
    result=json.loads((private/'result.json').read_text());assert result['passed']
    bundle=root/'build/linux/x64/debug/bundle/lib'
    sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    result.update(platform='Linux GTK/X11 '+('forced GPU failure with CPU fallback' if args.fail_gpu else 'native Flutter GL texture')+', system screenshot',cases=observed,
        library_sha256=sha(bundle/'liblrdp.so'),plugin_sha256=sha(bundle/'liblrdp_native_plugin.so'))
    (out/'VERDICT.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS: '+('forced GPU fallback' if args.fail_gpu else 'native textures')+', real RDP color updates, XOR, zoom, freeze/resume, remount, three reconnects and released session resources',flush=True)
