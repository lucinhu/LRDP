#!/usr/bin/env python3
"""OS-injected Android gestures through production LRDP to a private X11 RDP desktop.

Only LRDP_API36_16k on dedicated ADB 5038 is accepted. The helper runs as shell
on that emulator, never ships in the app, and cannot target personal devices.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import base64
import ctypes as c
import hashlib
import io
import json
import math
import os
import re
import select
import shutil
import socket
import subprocess
import tempfile
import time
from PIL import Image

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reuse-apk', action='store_true', help='Require an unchanged, hash-checked integration APK')
args = parser.parse_args()
sdk = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home()/'Android/Sdk')))
adb = [str(sdk/'platform-tools/adb'), '-P', '5038', '-s', 'emulator-5556']
package = 'dev.lrdp.lrdp'
output = root/'build/android-gestures-runtime'
output.mkdir(parents=True, exist_ok=True)
(output/'VERDICT.json').unlink(missing_ok=True)
environment = dict(os.environ, JAVA_HOME='/usr/lib/jvm/java-17-openjdk',
    ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk),
    LRDP_OPENSSL_ROOT=str(root/'build/deps/android-openssl'),
    LRDP_FFMPEG_ROOT=str(root/'build/deps/ffmpeg/android'),
    LRDP_BUILD_JOBS='3', CMAKE_BUILD_PARALLEL_LEVEL='3',
    ADB_SERVER_SOCKET='tcp:5038', ANDROID_ADB_SERVER_PORT='5038',
    FLUTTER_TEST_OUTPUTS_DIR=str(output))
environment['PATH'] = environment['JAVA_HOME']+'/bin:/opt/flutter/bin:'+environment['PATH']


def sha(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def android(*parts, check=True):
    result = subprocess.run(adb+list(parts), capture_output=True, text=True, timeout=30)
    if check and result.returncode:
        raise RuntimeError((parts, result.stdout, result.stderr))
    return result


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()


def until(predicate, reason, timeout=30):
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(reason)


def apk_inputs():
    assert not subprocess.check_output(['git','-C','third_party/FreeRDP','status','--porcelain'],cwd=root), 'FreeRDP must remain unmodified'
    paths = sorted(set(subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).split(b'\0'))-{b''})
    h = hashlib.sha256(b'LRDP-Android-gesture-APK-v1\0')
    for path in paths:
        name = path.decode()
        if name.startswith(('lib/','assets/','android/','native/src/','native/include/','packages/')) or name in (
            'pubspec.yaml','pubspec.lock','native/CMakeLists.txt','integration_test/android_gestures_test.dart'):
            h.update(path+b'\0'+(root/name).read_bytes()+b'\0')
    h.update(subprocess.check_output(['git','-C','third_party/FreeRDP','rev-parse','HEAD'],cwd=root))
    for folder in ['build/deps/android-openssl/x86_64/lib','build/deps/ffmpeg/android/x86_64/lib']:
        for library in sorted((root/folder).glob('*.a')):
            h.update(library.name.encode()+sha(library).encode())
    return h.hexdigest()


class XMouse(c.Structure):
    _fields_ = [('type',c.c_int),('serial',c.c_ulong),('send_event',c.c_int),
        ('display',c.c_void_p),('window',c.c_ulong),('root',c.c_ulong),('subwindow',c.c_ulong),
        ('time',c.c_ulong),('x',c.c_int),('y',c.c_int),('x_root',c.c_int),('y_root',c.c_int),
        ('state',c.c_uint),('button',c.c_uint),('same_screen',c.c_int)]


class XEvent(c.Union):
    _fields_ = [('type',c.c_int),('mouse',XMouse),('padding',c.c_long*24)]


class Desktop:
    def __init__(self, display):
        self.x = c.CDLL('libX11.so.6')
        def fn(name, result, *arguments):
            f=getattr(self.x,name); f.restype=result; f.argtypes=list(arguments); return f
        self.display = fn('XOpenDisplay',c.c_void_p,c.c_char_p)(display.encode())
        assert self.display
        self.root = fn('XDefaultRootWindow',c.c_ulong,c.c_void_p)(self.display)
        self.window = fn('XCreateSimpleWindow',c.c_ulong,c.c_void_p,c.c_ulong,c.c_int,c.c_int,
            c.c_uint,c.c_uint,c.c_uint,c.c_ulong,c.c_ulong)(self.display,self.root,0,0,2560,1600,0,0,0x182d28)
        fn('XSelectInput',c.c_int,c.c_void_p,c.c_ulong,c.c_long)(self.display,self.window,4|8|64)
        fn('XMapWindow',c.c_int,c.c_void_p,c.c_ulong)(self.display,self.window)
        self.sync=fn('XSync',c.c_int,c.c_void_p,c.c_int)
        self.sync(self.display,0)
        gc=fn('XCreateGC',c.c_void_p,c.c_void_p,c.c_ulong,c.c_ulong,c.c_void_p)(self.display,self.window,0,None)
        fn('XSetForeground',c.c_int,c.c_void_p,c.c_void_p,c.c_ulong)(self.display,gc,0x64b79a)
        draw=fn('XDrawRectangle',c.c_int,c.c_void_p,c.c_ulong,c.c_void_p,c.c_int,c.c_int,c.c_uint,c.c_uint)
        text=fn('XDrawString',c.c_int,c.c_void_p,c.c_ulong,c.c_void_p,c.c_int,c.c_int,c.c_char_p,c.c_int)
        for y in range(0,1600,160):
            for x in range(0,2560,160):
                draw(self.display,self.window,gc,x,y,159,159)
                label=f'{x},{y}'.encode(); text(self.display,self.window,gc,x+16,y+26,label,len(label))
        fn('XFreeGC',c.c_int,c.c_void_p,c.c_void_p)(self.display,gc)
        self.sync(self.display,0)
        self.pending=fn('XPending',c.c_int,c.c_void_p)
        self.next=fn('XNextEvent',c.c_int,c.c_void_p,c.POINTER(XEvent))
        self.query=fn('XQueryPointer',c.c_int,c.c_void_p,c.c_ulong,c.POINTER(c.c_ulong),c.POINTER(c.c_ulong),
            c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_uint))
        self.close_x=fn('XCloseDisplay',c.c_int,c.c_void_p)

    def pointer(self):
        root_return,child=c.c_ulong(),c.c_ulong()
        x,y,local_x,local_y=c.c_int(),c.c_int(),c.c_int(),c.c_int(); mask=c.c_uint()
        assert self.query(self.display,self.root,c.byref(root_return),c.byref(child),c.byref(x),c.byref(y),c.byref(local_x),c.byref(local_y),c.byref(mask))
        return {'x':x.value,'y':y.value,'mask':mask.value}

    def events(self):
        self.sync(self.display,0); result=[]
        while self.pending(self.display):
            event=XEvent(); self.next(self.display,c.byref(event))
            if event.type in (4,5,6):
                e=event.mouse
                result.append({'type':event.type,'x':e.x_root,'y':e.y_root,'state':e.state,
                    'button':e.button if event.type in (4,5) else None})
        return result

    def close(self): self.close_x(self.display)


class Injector:
    def __init__(self, log):
        self.process=subprocess.Popen(adb+['shell','env','CLASSPATH=/data/local/tmp/lrdp-gesture-injector.dex',
            'app_process','/system/bin','TouchInjector'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=log,text=True,bufsize=1)
        self.reply('ready')

    def reply(self,key):
        assert select.select([self.process.stdout],[],[],30)[0], 'Android input injector did not respond'
        line=self.process.stdout.readline()
        assert line and json.loads(line).get(key), ('Input helper response',line,self.process.poll())

    def send(self,action,**kwargs):
        self.process.stdin.write(json.dumps({'action':action,**kwargs})+'\n'); self.process.stdin.flush()
        self.reply('ok')

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try: self.process.wait(timeout=8)
            except subprocess.TimeoutExpired: stop(self.process)


class Mouse:
    """A kernel input device: Android generates genuine mouse HOVER_MOVE events."""
    def __init__(self, binary, log):
        self.remote='/data/local/tmp/lrdp-gesture-uinput-mouse'
        android('push',str(binary),self.remote);android('shell','chmod','700',self.remote)
        self.process=subprocess.Popen(adb+['shell',self.remote],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=log,text=True,bufsize=1)
        assert select.select([self.process.stdout],[],[],20)[0]
        assert self.process.stdout.readline().strip()=='READY','Virtual mouse creation failed'
        def registered():
            data=android('shell','dumpsys','input').stdout
            devices=re.findall(r'^  Device (\d+): LRDP gesture test mouse$',data,re.M)
            if len(devices)!=1:return False
            self.device=int(devices[0]);return True
        until(registered,'Virtual mouse was not registered')

    def relative(self,x,y):
        self.process.stdin.write(f'M {x} {y}\n');self.process.stdin.flush()
        assert select.select([self.process.stdout],[],[],20)[0],'Virtual mouse move timed out'
        assert self.process.stdout.readline().strip()=='OK','Virtual mouse move failed'

    def position(self):
        data=android('shell','dumpsys','input').stdout
        rows=[line for line in data.splitlines() if f'MotionEvent(deviceId={self.device},' in line and 'source=MOUSE,' in line]
        assert rows,'Missing kernel mouse event in Android dispatcher history'
        value=re.search(r'xCursorPosition=([\d.]+), yCursorPosition=([\d.]+)',rows[-1])
        assert value,rows[-1]
        x,y=map(float,value.groups())
        # Android dispatcher history stores unrotated coordinates. Apply the
        # actual display transform to compare against Flutter/screenshot pixels.
        transform=re.search(r'MousePointerControllers:.*?Transform[^\n]*\n\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\n\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)',data,re.S)
        if not transform:
            assert re.search(r'MousePointerControllers:.*?Transform[^\n]*\(IDENTITY\)',data,re.S),'Missing Android mouse display transform'
            return (x,y)
        a,b,tx,d,e,ty=map(float,transform.groups())
        return (a*x+b*y+tx,d*x+e*y+ty)

    def move_to(self,point):
        # Refresh the cursor position after touchscreen events replace the
        # dispatcher's short history. Closed-loop movement tolerates acceleration.
        self.relative(1,0)
        for _ in range(12):
            x,y=self.position();dx,dy=point[0]-x,point[1]-y
            if max(abs(dx),abs(dy))<=2:return (x,y)
            self.relative(round(dx/2),round(dy/2))
        raise AssertionError(('Mouse did not reach target',point,self.position()))

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:stop(self.process)
        android('shell','rm','-f',self.remote,check=False)


def center(meta,x=.5,y=.5):
    left,top,width,height=meta['bounds'];return [left+x*width,top+y*height]


def remote_point(meta, point):
    left,top,width,height=meta['bounds']; ratio=meta['ratio']
    remote_width,remote_height=meta['remote']; matrix=meta['matrix']
    width,height=width/ratio,height/ratio
    base=min(width/remote_width,height/remote_height)
    return [max(0,min(limit-1,math.floor((((value-start)/ratio-offset)/zoom-origin)/base+.5)))
        for value,start,offset,zoom,origin,limit in [
            (point[0],left,matrix[12],matrix[0],(width-remote_width*base)/2,remote_width),
            (point[1],top,matrix[13],matrix[5],(height-remote_height*base)/2,remote_height)]]


def screenshot(name):
    image=subprocess.check_output(adb+['exec-out','screencap','-p'],timeout=30)
    assert image.startswith(b'\x89PNG\r\n\x1a\n')
    (output/(name+'.png')).write_bytes(image)


until(lambda:android('shell','getprop','sys.boot_completed',check=False).stdout.strip()=='1','Own emulator did not boot',180)
assert 'LRDP_API36_16k' in android('emu','avd','name').stdout.splitlines()
assert android('shell','getprop','ro.build.version.sdk').stdout.strip()=='36'
assert android('shell','getprop','ro.product.cpu.abi').stdout.strip()=='x86_64'
assert android('shell','getconf','PAGE_SIZE').stdout.strip()=='16384'
apk=output/'gestures-integration-x86_64.apk'; proof=output/'APK_INPUTS.json'
inputs=apk_inputs()
with ExitStack() as cleanup, tempfile.TemporaryDirectory(prefix='lrdp-os-gestures-') as temporary:
    private=Path(temporary)
    if android('shell','id','-u').stdout.strip()!='0':
        android('root')
        until(lambda:android('shell','id','-u',check=False).stdout.strip()=='0','Own debug AVD did not permit the test mouse')
        cleanup.callback(android,'unroot',check=False)
    if args.reuse_apk:
        cached=json.loads(proof.read_text())
        assert cached=={'inputs':inputs,'apk':sha(apk)}, 'APK or compilation inputs changed; rebuild'
        print('Reusing hash-checked integration APK with unchanged compilation inputs',flush=True)
    else:
        log=cleanup.enter_context((output/'build.log').open('w'))
        defines=base64.b64encode(b'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false').decode()
        print('Building private x86_64 OS gestures integration APK',flush=True)
        subprocess.run([str(root/'android/gradlew'),'--no-daemon','--max-workers=3','-Dorg.gradle.jvmargs=-Xmx2g',
            ':app:assembleDebug','-Ptarget-platform=android-x64',f'-Ptarget={root/"integration_test/android_gestures_test.dart"}',
            f'-Pdart-defines={defines}'],cwd=root/'android',env=environment,stdout=log,stderr=subprocess.STDOUT,check=True)
        assert apk_inputs()==inputs, 'Compilation inputs changed while building'
        shutil.copy2(root/'build/app/outputs/apk/debug/app-debug.apk',apk)
        proof.write_text(json.dumps({'inputs':inputs,'apk':sha(apk)})+'\n')
    subprocess.run(['python3',str(root/'scripts/check_android_apk.py'),str(apk),'--abi','x86_64','--integration'],env=environment,check=True)
    classes=private/'classes';classes.mkdir()
    dex=private/'dex';dex.mkdir()
    subprocess.run([environment['JAVA_HOME']+'/bin/javac','--release','8','-cp',str(sdk/'platforms/android-36/android.jar'),
        '-d',str(classes),str(root/'native/tests/android_gestures/TouchInjector.java')],check=True)
    subprocess.run([str(sdk/'build-tools/36.0.0/d8'),'--lib',str(sdk/'platforms/android-36/android.jar'),
        '--output',str(dex),*[str(p) for p in classes.glob('*.class')]],env=environment,check=True)
    android('push',str(dex/'classes.dex'),'/data/local/tmp/lrdp-gesture-injector.dex')
    cleanup.callback(android,'shell','rm','-f','/data/local/tmp/lrdp-gesture-injector.dex',check=False)
    clang=sorted(sdk.glob('ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang'))[-1]
    mouse_binary=private/'uinput-mouse'
    subprocess.run([str(clang),'-std=c11','-D_POSIX_C_SOURCE=200809L','-Wall','-Wextra','-Werror',
        '-Wl,-z,max-page-size=16384',str(root/'native/tests/android_gestures/uinput_mouse.c'),'-o',str(mouse_binary)],check=True)
    display=next(n for n in range(101,201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
    server_env=dict(os.environ,DISPLAY=f':{display}',XDG_CONFIG_HOME=str(private/'config'))
    xlog=cleanup.enter_context((output/'display.log').open('w'))
    xvnc=subprocess.Popen(['Xvnc',server_env['DISPLAY'],'-geometry','2560x1600','-depth','24','-SecurityTypes','None',
        '-noreset','-rfbport','-1','-rfbunixpath',str(private/'vnc.sock'),'-rfbunixmode','0600','-nolisten','tcp'],
        env=server_env,stdout=xlog,stderr=subprocess.STDOUT);cleanup.callback(stop,xvnc)
    until(lambda:Path(f'/tmp/.X11-unix/X{display}').exists(),'Private X display did not start')
    desktop=Desktop(server_env['DISPLAY']);cleanup.callback(desktop.close)
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    log=cleanup.enter_context((output/'rdp-server.log').open('w'))
    peer=subprocess.Popen(['freerdp-shadow-cli3','/bind-address:127.0.0.1',f'/port:{port}','/sec:tls','-auth',
        '+may-view','+may-interact','+gfx-avc420','-gfx-avc444','/log-level:WARN'],env=server_env,stdout=log,stderr=subprocess.STDOUT)
    cleanup.callback(stop,peer)
    until(lambda:any(line.split()[1]==f'0100007F:{port:04X}' and line.split()[3]=='0A'
        for line in Path('/proc/net/tcp').read_text().splitlines()[1:]),'Private RDP peer did not listen')
    certificates=list((private/'config').glob('**/shadow.crt'));assert len(certificates)==1,certificates
    der=subprocess.check_output(['openssl','x509','-in',str(certificates[0]),'-outform','DER'])
    pin=':'.join(f'{b:02x}' for b in hashlib.sha256(der).digest())
    android('reverse',f'tcp:{port}',f'tcp:{port}')
    cleanup.callback(android,'reverse','--remove',f'tcp:{port}',check=False)
    for name in ('window_animation_scale','transition_animation_scale','animator_duration_scale'):
        android('shell','settings','put','global',name,'0')
    android('shell','wm','size','720x1600');android('shell','wm','density','280')
    android('shell','settings','put','system','accelerometer_rotation','0')
    android('shell','settings','put','system','user_rotation','0')
    cleanup.callback(android,'shell','settings','put','system','user_rotation','0',check=False)
    android('shell','wm','dismiss-keyguard');android('shell','svc','power','stayon','true')
    android('shell','am','force-stop',package)
    android('shell','run-as',package,'rm','-f','files/lrdp-gesture-stage.json',check=False)
    view=root/'build/android-sdk-view'
    drive_environment=dict(environment,ANDROID_HOME=str(view),ANDROID_SDK_ROOT=str(view))
    driver_log=cleanup.enter_context((output/'driver.log').open('w'))
    driver=subprocess.Popen(['flutter','drive','--no-pub','-d','emulator-5556','--target','integration_test/android_gestures_test.dart',
        '--driver','test_driver/android_runtime.dart','--use-application-binary',str(apk)],cwd=root,env=drive_environment,
        stdout=driver_log,stderr=subprocess.STDOUT);cleanup.callback(stop,driver)
    cleanup.callback(android,'shell','am','force-stop',package,check=False)
    injector=Injector(cleanup.enter_context((output/'injector.log').open('w')));cleanup.callback(injector.close)
    mouse=Mouse(mouse_binary,cleanup.enter_context((output/'mouse.log').open('w')));cleanup.callback(mouse.close)
    def failure_snapshot(exc_type, exc, traceback):
        if exc_type is not None:
            screenshot('failure')
            for service in ('window','input','power'):
                (output/('failure-'+service+'.txt')).write_text(android('shell','dumpsys',service,check=False).stdout)
        return False
    cleanup.push(failure_snapshot)
    def connections():
        return [tuple(line.split()[i] for i in (1,2,9))
            for line in Path('/proc/net/tcp').read_text().splitlines()[1:]
            if line.split()[1]==f'0100007F:{port:04X}' and line.split()[3]=='01']
    def live_geometry(stage):
        result = None
        def matching():
            nonlocal result
            raw = android('exec-out','run-as',package,'cat','files/lrdp-gesture-live.json',check=False).stdout
            try: result = json.loads(raw)
            except json.JSONDecodeError: return False
            return result.get('stage') == stage and 'matrix' in result
        until(matching,'No current viewport snapshot for '+stage)
        return result

    def same_viewport(before, after):
        assert before['trackpad']==after['trackpad'] and before['pan']==after['pan'], (before,after)
        assert before['remote']==after['remote'] and before['bounds']==after['bounds'], (before,after)
        assert all(abs(a-b)<1e-6 for a,b in zip(before['matrix'],after['matrix'])), ('Viewport reset',before,after)

    stages=set();cases={}; connection=None; deadline=time.monotonic()+540
    while driver.poll() is None and time.monotonic()<deadline:
        raw=android('exec-out','run-as',package,'cat','files/lrdp-gesture-stage.json',check=False).stdout
        try: meta=json.loads(raw)
        except json.JSONDecodeError: time.sleep(.2);continue
        stage=meta['stage']
        if stage in stages:time.sleep(.2);continue
        print('Android OS gesture stage:',stage,flush=True)
        if stage=='config':
            subprocess.run(adb+['shell','run-as',package,'tee','files/lrdp-gesture-config.json'],
                input=json.dumps({'port':port,'pin':pin}),text=True,capture_output=True,check=True)
        elif stage=='frame-color':
            assert meta['native_texture'] and meta['texture_uploads']>0,meta
            left,top,width,height=meta['bounds'];ratio=meta['ratio'];rw,rh=meta['remote'];matrix=meta['matrix']
            base=min(width/ratio/rw,height/ratio/rh)
            logical=[(width/ratio-rw*base)/2+100*base,(height/ratio-rh*base)/2+100*base]
            point=[round(left+(logical[0]*matrix[0]+matrix[12])*ratio),round(top+(logical[1]*matrix[5]+matrix[13])*ratio)]
            def frame_pixel():
                data=subprocess.check_output(adb+['exec-out','screencap','-p'],timeout=25)
                frame=Image.open(io.BytesIO(data)).convert('RGB');pixel=frame.getpixel(tuple(point))
                (output/'native-frame.png').write_bytes(data)
                return max(abs(a-b) for a,b in zip(pixel,[24,45,40]))<=5
            until(frame_pixel,'Native gesture desktop color did not reach Android compositor')
            (output/'native-frame.json').write_text(json.dumps({'screen_point':point,'expected_rgb':[24,45,40],'metadata':meta},indent=2)+'\n')
        elif stage.startswith('start-'):
            name=stage[6:];desktop.events();before=desktop.pointer()
            case=cases[name]={'before':meta,'pointer_before':before,'events':[]}
            active=connections();assert len(active)==1,active
            if connection is None:connection=active[0]
            assert active==[connection],('RDP TCP connection changed',connection,active)
            case['tcp_connection']=connection
            window=android('shell','dumpsys','window').stdout
            case['window_focus']=[line.strip() for line in window.splitlines() if 'mCurrentFocus=' in line]
            assert any(package in line for line in case['window_focus']),case['window_focus']
            if name=='pinch':
                point=center(meta)
                android('shell','input','tap',str(round(point[0])),str(round(point[1])))
                time.sleep(.4)
                case['shell_tap_preflight']=desktop.events()
                assert [(e['type'],e['button']) for e in case['shell_tap_preflight'] if e['type'] in (4,5)]==[(4,1),(5,1)],case
                screenshot('before-pinch')
            if name.startswith('tap-'):
                assert meta['trackpad']==(name!='tap-direct') and not meta['pan'],meta
                case['expected_clicks']=[]
                for point in [center(meta,.35,.48),center(meta,.65,.54),center(meta,.5,.5)]:
                    case['expected_clicks'].append(remote_point(meta,point) if name=='tap-direct'
                        else [before['x'],before['y']])
                    injector.send('tap',**{'from':[point],'duration':70})
                    until(lambda:not desktop.pointer()['mask']&256,'Point tap left remote button held')
                    time.sleep(.4)
            elif name.startswith('pinch'):
                injector.send('swipe',**{'from':[center(meta,.42,.5),center(meta,.58,.5)],
                    'to':[center(meta,.26,.5),center(meta,.74,.5)],'duration':500})
            elif name in ('follow','bounds'):
                for _ in range(2 if name=='follow' else 18):
                    injector.send('swipe',**{'from':[center(meta,.22,.35)],'to':[center(meta,.85,.68)],'duration':300})
            elif name in ('right-tap','long-press'):
                injector.send('tap',**{'from':[center(meta,.45,.5),center(meta,.55,.5)] if name=='right-tap' else [center(meta)],
                    'duration':70 if name=='right-tap' else 650})
            elif name.startswith('scroll-'):
                dx,dy={'scroll-down':(0,.18),'scroll-up':(0,-.18),'scroll-left':(-.35,0),'scroll-right':(.35,0)}[name]
                starts=[center(meta,.46,.4),center(meta,.54,.4)]
                ends=[[p[0]+dx*meta['bounds'][2],p[1]+dy*meta['bounds'][3]] for p in starts]
                injector.send('swipe',**{'from':starts,'to':ends,'duration':500})
            elif name in ('drag','cancel','background','rotate','inactive'):
                # Start inside the current visible desktop so a preceding
                # boundary test cannot clamp every drag movement to one pixel.
                injector.send('swipe',**{'from':[center(meta,.8,.7)],'to':[center(meta,.2,.3)],'duration':300})
                time.sleep(.2)
                desktop.events()
                injector.send('drag',**{'from':[center(meta,.3,.4)],'to':[center(meta,.6,.5)],'duration':350,'hold':True})
                until(lambda:desktop.pointer()['mask']&256,'Double-tap drag did not hold remote left button')
                time.sleep(.2)
                case['held']=desktop.pointer();case['events']+=desktop.events()
                assert any(e['type']==6 and e['state']&256 for e in case['events']),('No held-button remote motion',case)
                if name=='drag':injector.send('up')
                elif name=='cancel':injector.send('cancel')
                elif name=='background':
                    android('shell','input','keyevent','KEYCODE_HOME')
                    until(lambda:not desktop.pointer()['mask']&256,'Background left button stuck')
                    injector.send('cancel')
                    android('shell','am','start','--activity-reorder-to-front','--activity-single-top','-n',package+'/.MainActivity')
                elif name=='rotate':
                    android('shell','settings','put','system','user_rotation','1')
                    until(lambda:not desktop.pointer()['mask']&256,'Rotation left button stuck')
                    injector.send('cancel');time.sleep(1)
                else:
                    case['before_leaving'] = live_geometry(stage)
                    injector.send('aux-tap',**{'from':[meta['back']],'duration':70})
                    until(lambda:not desktop.pointer()['mask']&256,'Inactive session left button stuck')
                    injector.send('cancel')
                until(lambda:not desktop.pointer()['mask']&256,'Remote left button was not released')
            elif name=='portrait':
                android('shell','settings','put','system','user_rotation','0');time.sleep(1)
            elif name=='hardware-edge':
                point=center(meta)
                case['mouse_center']=mouse.move_to(point);time.sleep(.2)
                case['center_pointer']=desktop.pointer()
                point=center(meta,.995,.5)
                case['mouse_edge']=mouse.move_to(point);time.sleep(.7)
            elif name=='hardware-stop':
                point=center(meta)
                case['mouse_center']=mouse.move_to(point);time.sleep(.2)
                case['stopped_pointer']=desktop.pointer();time.sleep(.7)
            elif name=='mode-return':
                assert not meta['trackpad'] and meta['pan'], meta
                injector.send('tap',**{'from':[meta['back']],'duration':70})
            else:raise AssertionError(name)
            time.sleep(.2);case['events']+=desktop.events();case['pointer_after']=desktop.pointer()
        elif stage.startswith('end-'):
            name=stage[4:];case=cases[name];case['after']=meta;case['events']+=desktop.events()
            (output/(name+'.json')).write_text(json.dumps(case,indent=2)+'\n')
            buttons=[(e['type'],e['button']) for e in case['events'] if e['type'] in (4,5)]
            if name.startswith('tap-'):
                assert buttons==[(kind,1) for _ in range(3) for kind in (4,5)],(name,buttons)
                actual=[e for e in case['events'] if e['type'] in (4,5)]
                for i,expected in enumerate(case['expected_clicks']):
                    assert all(abs(e['x']-expected[0])<=1 and abs(e['y']-expected[1])<=1
                        for e in actual[i*2:i*2+2]),(name,expected,actual)
                assert not desktop.pointer()['mask']&256,(name,'Tap left button held')
            elif name.startswith('pinch'):
                assert meta['matrix'][0]>2.5 and not buttons,(name,meta,buttons)
            elif name=='follow':
                assert meta['matrix'][12]<case['before']['matrix'][12]-10,(name,case)
                assert case['pointer_after']['x']>case['pointer_before']['x']+100,(name,case)
            elif name in ('right-tap','long-press'):assert buttons==[(4,3),(5,3)],(name,buttons)
            elif name.startswith('scroll-'):
                # Names denote finger travel. Leftward fingers send positive
                # RDP HWHEEL (Windows: scroll right). The unmodified FreeRDP
                # X11 shadow backend maps positive HWHEEL to button 6, negative
                # to 7. Assert that backend's wire mapping, not Windows UI motion.
                expected={'scroll-down':4,'scroll-up':5,'scroll-left':6,'scroll-right':7}[name]
                assert len(buttons)>=2 and len(buttons)%2==0 and buttons==[(k,expected) for _ in range(len(buttons)//2) for k in (4,5)],(name,buttons)
                assert abs(meta['matrix'][0]-case['before']['matrix'][0])<.01,(name,'Scroll changed zoom')
            elif name in ('drag','cancel','background','rotate','inactive'):
                assert buttons==[(4,1),(5,1)],(name,buttons)
                releases=[e for e in case['events'] if e['type']==5 and e['button']==1]
                assert (releases[-1]['x'],releases[-1]['y'])==(case['held']['x'],case['held']['y']),(name,'Release coordinate mismatch')
                assert not desktop.pointer()['mask']&256,(name,'Left still held')
            elif name=='bounds':
                assert case['pointer_after']['x']==2559 and case['pointer_after']['y']==1599,(name,case['pointer_after'])
            elif name=='hardware-edge':
                assert case['pointer_after']['x']>case['center_pointer']['x']+100,(name,case)
                assert meta['matrix'][12]<case['before']['matrix'][12]-10,(name,case)
            elif name=='hardware-stop':assert case['pointer_after']==case['stopped_pointer'],(name,case)
            elif name=='mode-return':
                same_viewport(case['before'],meta)
                assert not buttons, ('Returning in pan mode sent a remote click',case)
                assert connections()==[connection]
            if name!='portrait':assert meta['device_events']>case['before']['device_events'],(name,'No OS pointer events')
            (output/(name+'.json')).write_text(json.dumps(case,indent=2)+'\n')
            if name in ('follow','bounds','rotate'):screenshot(name)
        elif stage=='returned':
            assert meta['sessions']==1 and meta['connected'] and meta['device_events']>100,meta
            assert connections()==[connection],('Returning opened a new TCP connection',connections())
            same_viewport(cases['inactive']['before_leaving'],meta)
            returned_pointer=desktop.pointer()
            desktop.events()
            injector.send('tap',**{'from':[center(meta)],'duration':70})
            events=[]
            def returned_click():
                events.extend(desktop.events())
                return len([e for e in events if e['type'] in (4,5)])>=2
            until(returned_click,'Deferred return click did not reach remote desktop',timeout=8)
            clicks=[e for e in events if e['type'] in (4,5)]
            assert [(e['type'],e['button']) for e in clicks]==[(4,1),(5,1)],events
            expected=cases['inactive']['held']
            restored=all((e['x'],e['y'])==(expected['x'],expected['y']) for e in clicks)
            after_click=live_geometry(stage)
            (output/'SESSION_VIEW_PROOF.json').write_text(json.dumps({
                'passed':restored,'before_leaving':cases['inactive']['before_leaving'],
                'returned':meta,'actual_return_clicks':clicks,'original_tcp_connection':connection,
                'remote_before_return_click':returned_pointer,'after_return_click':after_click,
            },indent=2)+'\n')
            assert restored, ('Local cursor reset',expected,clicks)
            screenshot('returned')
        elif stage=='closed':
            assert not desktop.pointer()['mask']&256
            until(lambda:not connections(),'Closing retained the RDP TCP connection')
        else:raise AssertionError(stage)
        android('shell','run-as',package,'touch',f'files/lrdp-gesture-{stage}.ack');stages.add(stage)
    assert driver.poll()==0,'Android driver failed; inspect driver.log'
    assert 'All tests passed!' in (output/'driver.log').read_text()
    assert len(cases)==22 and all('after' in v for v in cases.values()),cases.keys()
    with __import__('zipfile').ZipFile(apk) as archive: native=archive.read('lib/x86_64/liblrdp.so')
    verdict={'passed':True,'native_abi':5,'platform':'Android API36 x86_64 16KiB','physical_device':False,
        'injection':'Android InputManagerGlobal touchscreen + temporary kernel uinput mouse; production Workspace/RemoteSurface; independent X11 events',
        'virtual_mouse':True,'root_required_for_test_mouse':True,
        'apk_sha256':sha(apk),'apk_inputs_sha256':inputs,'library_sha256':hashlib.sha256(native).hexdigest(),
        'cases':list(cases),'stages':sorted(stages),'device_events':meta['device_events'],
        'connection_reused':True,'closed_tcp_released':True,
        'session_view_restored':True,'input_mode_restored':True,'local_pointer_restored':True,
        'source_files_sha256':{p:sha(root/p) for p in ['lib/ui/remote_surface.dart','lib/ui/remote_view.dart',
            'lib/ui/remote_view_memory.dart','lib/ui/workspace_screen.dart','lib/rdp/rdp_session.dart']}}
    (output/'VERDICT.json').write_text(json.dumps(verdict,indent=2)+'\n')
    print('PASS: Android OS gestures through actual RDP, edge follow and held-button lifecycle',flush=True)
