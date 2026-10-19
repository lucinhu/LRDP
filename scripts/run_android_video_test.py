#!/usr/bin/env python3
"""Actual Android native texture/CPU recovery pixels on an owned AVD.

Uses Debug integration code, shell-only ADB 5038/emulator-5556, private X/RDP,
and OS screenshots. No personal desktop/device or public RDP host is accessed.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse,base64,ctypes as c,hashlib,io,json,math,os,shutil,socket,subprocess,tempfile,time,zipfile
from PIL import Image
from rdp_test_desktop import Desktop
from android_test_device import DEVICES, add_device_argument, screenshot_mapping

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fail-gpu',action='store_true');parser.add_argument('--reuse-apk',action='store_true')
parser.add_argument('--build-only',action='store_true',help='Build the integration APK without contacting a device')
parser.add_argument('--runtime-dir',type=Path,help='Separate evidence/build directory under this workspace build/')
add_device_argument(parser)
args=parser.parse_args()
device=DEVICES[args.device]
parent=(root/args.runtime_dir).resolve() if args.runtime_dir else root/device.runtime('video')
assert parent.is_relative_to(root/'build'),'Evidence must stay under this workspace build/'
parent.mkdir(parents=True,exist_ok=True)
out=parent/('fallback' if args.fail_gpu else 'native');out.mkdir(exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)
sdk=Path('/home/lucinhu/Android/Sdk');adb=[str(sdk/'platform-tools/adb'),'-P','5038','-s','emulator-5556'];package='dev.lrdp.lrdp'
env=dict(os.environ,JAVA_HOME='/usr/lib/jvm/java-17-openjdk',ANDROID_HOME=str(sdk),ANDROID_SDK_ROOT=str(sdk),
 LRDP_OPENSSL_ROOT=str(root/'build/deps/android-openssl'),LRDP_FFMPEG_ROOT=str(root/'build/deps/ffmpeg/android'),
 LRDP_BUILD_JOBS='3',CMAKE_BUILD_PARALLEL_LEVEL='3',ADB_SERVER_SOCKET='tcp:5038',ANDROID_ADB_SERVER_PORT='5038')
env['PATH']=env['JAVA_HOME']+'/bin:/opt/flutter/bin:'+env['PATH']
env['GRADLE_OPTS']='-Dorg.gradle.java.home=/usr/lib/jvm/java-17-openjdk -Dorg.gradle.workers.max=3 -Dorg.gradle.jvmargs=-Xmx2g'
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def android(*parts,check=True,timeout=30):return subprocess.run(adb+list(parts),capture_output=True,text=True,check=check,timeout=timeout)
def stop(p):
 if p.poll() is None:
  p.terminate()
  try:p.wait(timeout=8)
  except subprocess.TimeoutExpired:p.kill();p.wait()
def until(ready,reason,timeout=35):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  if ready():return
  time.sleep(.1)
 raise AssertionError(reason)
def write_private(name,data):
 assert name.startswith('video-') and all(ch.isalnum() or ch in '.-' for ch in name)
 subprocess.run(adb+['shell',"run-as "+package+" sh -c 'cat > files/"+name+"'"],input=data.encode(),capture_output=True,check=True,timeout=25)
def read_private(name):
 result=android('exec-out','run-as',package,'cat','files/'+name,check=False)
 try:return json.loads(result.stdout) if result.returncode==0 and result.stdout.strip() else None
 except json.JSONDecodeError:return None
def screenshot(name):
 data=subprocess.check_output(adb+['exec-out','screencap','-p'],timeout=25)
 assert data.startswith(b'\x89PNG\r\n\x1a\n');(out/(name+'.png')).write_bytes(data)
 return Image.open(io.BytesIO(data)).convert('RGB')
device_evidence=None if args.build_only else device.verify(android)
paths=sorted(set(subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).split(b'\0'))-{b''})
fingerprint=hashlib.sha256(b'LRDP-Android-video-APK-v1\0')
for raw in paths:
 name=raw.decode()
 if name.startswith(('lib/','assets/','android/','native/','packages/')) or name in ('pubspec.yaml','pubspec.lock','integration_test/android_video_test.dart'):
  fingerprint.update(raw+b'\0'+(root/name).read_bytes()+b'\0')
fingerprint.update(subprocess.check_output(['git','-C','third_party/FreeRDP','rev-parse','HEAD'],cwd=root))
for folder in ('build/deps/android-openssl/x86_64/lib','build/deps/ffmpeg/android/x86_64/lib'):
 for library in sorted((root/folder).glob('*.a')):
  fingerprint.update(library.name.encode()+sha(library).encode())
inputs=fingerprint.hexdigest();apk=parent/'video-integration-x86_64.apk';build_info=parent/'APK_BUILD.json'
if args.reuse_apk:
 cached=json.loads(build_info.read_text());assert cached['inputs']==inputs and cached['sha256']==sha(apk),'APK inputs changed; rebuild it'
else:
 definitions=base64.b64encode(b'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false').decode()
 with (parent/'build.log').open('w') as log:
  subprocess.run([str(root/'android/gradlew'),'--no-daemon','--max-workers=3','-Dorg.gradle.jvmargs=-Xmx2g',':app:assembleDebug',
   '-Ptarget-platform=android-x64',f'-Ptarget={root/"integration_test/android_video_test.dart"}',f'-Pdart-defines={definitions}'],
   cwd=root/'android',env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 shutil.copy2(root/'build/app/outputs/apk/debug/app-debug.apk',apk)
 build_info.write_text(json.dumps({'inputs':inputs,'sha256':sha(apk)},indent=2)+'\n')
subprocess.run(['python3',str(root/'scripts/check_android_apk.py'),str(apk),'--abi','x86_64','--integration'],env=env,check=True)
if args.build_only:
 print('Built integration APK:',apk,flush=True)
 raise SystemExit(0)
view=root/'build/android-sdk-view'
for relative in ('build-tools/36.0.0','platforms/android-36','platform-tools','emulator','cmdline-tools','ndk','cmake','licenses'):
 destination=view/relative;destination.parent.mkdir(parents=True,exist_ok=True)
 if not destination.exists() and (sdk/relative).exists():destination.symlink_to(sdk/relative,target_is_directory=True)
drive_env=dict(env,ANDROID_HOME=str(view),ANDROID_SDK_ROOT=str(view))
with tempfile.TemporaryDirectory(prefix='lrdp-android-video-') as temporary,ExitStack() as cleanup:
 private=Path(temporary)
 display=next(n for n in range(101,201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
 server_env=dict(env,DISPLAY=f':{display}',XDG_CONFIG_HOME=str(private/'config'))
 log=cleanup.enter_context((out/'display.log').open('w'))
 xvnc=subprocess.Popen(['Xvnc',f':{display}','-geometry','1280x800','-depth','24','-SecurityTypes','None','-noreset',
  '-rfbport','-1','-rfbunixpath',str(private/'vnc.sock'),'-rfbunixmode','0600','-nolisten','tcp'],env=server_env,stdout=log,stderr=subprocess.STDOUT)
 cleanup.callback(stop,xvnc);until(lambda:Path(f'/tmp/.X11-unix/X{display}').exists(),'Private X did not start')
 desktop=Desktop(f':{display}');cleanup.callback(desktop.close)
 # Asymmetric colored markers prove channel order, orientation and scaling.
 for x,y,rgb in [(32,32,0xd34120),(1184,704,0x2550c6)]:
  window=desktop.fn('XCreateSimpleWindow',c.c_ulong,c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_uint,c.c_ulong,c.c_ulong)(desktop.display,desktop.root,x,y,64,64,0,0,rgb)
  desktop.fn('XMapWindow',c.c_int,c.c_void_p,c.c_ulong)(desktop.display,window)
 desktop.sync()
 def color(rgb):subprocess.run(['xsetroot','-solid',rgb],env=server_env,check=True)
 color('#182d28')
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 log=cleanup.enter_context((out/'server.log').open('w'))
 server=subprocess.Popen(['freerdp-shadow-cli3','/bind-address:127.0.0.1',f'/port:{port}','/sec:tls','-auth','+may-view','+may-interact',
  '+gfx-avc420','-gfx-avc444','/log-level:WARN'],env=server_env,stdout=log,stderr=subprocess.STDOUT);cleanup.callback(stop,server)
 until(lambda:any(line.split()[1]==f'0100007F:{port:04X}' and line.split()[3]=='0A' for line in Path('/proc/net/tcp').read_text().splitlines()[1:]),'Private RDP did not listen')
 android('reverse',f'tcp:{port}',f'tcp:{port}');cleanup.callback(android,'reverse','--remove',f'tcp:{port}',check=False)
 android('shell','am','force-stop',package)
 installed=android('install','-r','-t',str(apk),timeout=60,check=False)
 if 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' in installed.stdout+installed.stderr:
  android('uninstall',package)
  installed=android('install','-r','-t',str(apk),timeout=60)
 assert 'Success' in installed.stdout,installed.stdout+installed.stderr
 android('shell','pm','clear',package)
 android('shell','run-as',package,'mkdir','-p','files')
 write_private('video-fixture.json',json.dumps({'port':port,'fallback':args.fail_gpu}))
 for name in ('window_animation_scale','transition_animation_scale','animator_duration_scale'):android('shell','settings','put','global',name,'0')
 android('shell','wm','size','720x1600');android('shell','wm','density','280');android('shell','wm','dismiss-keyguard')
 android('shell','settings','put','system','accelerometer_rotation','0');android('shell','settings','put','system','user_rotation','0')
 cleanup.callback(android,'shell','settings','put','system','user_rotation','0',check=False)
 log=cleanup.enter_context((out/'driver.log').open('w'))
 driver=subprocess.Popen(['flutter','drive','--no-pub','--keep-app-running','-d','emulator-5556','--target','integration_test/android_video_test.dart',
  '--driver','test_driver/android_runtime.dart','--use-application-binary',str(apk)],env=drive_env,cwd=root,stdout=log,stderr=subprocess.STDOUT)
 cleanup.callback(stop,driver);cleanup.callback(android,'shell','am','force-stop',package,check=False)
 seen=[];cases=[];deadline=time.monotonic()+600
 while driver.poll() is None and time.monotonic()<deadline:
  meta=read_private('video-stage.json')
  if meta and meta['stage'] not in seen:
   name=meta['stage'];(out/(name+'.json')).write_text(json.dumps(meta,indent=2)+'\n')
   if name=='background':
    android('shell','input','keyevent','KEYCODE_HOME')
    until(lambda:read_private('video-background.json') is not None,'No background GPU observation')
    background=read_private('video-background.json');assert background['stable'],background
    (out/'background-state.json').write_text(json.dumps(background,indent=2)+'\n')
    android('shell','am','send-trim-memory',package,'BACKGROUND',check=False)
    android('shell','am','start','--activity-reorder-to-front','--activity-single-top','-n',package+'/.MainActivity')
   elif name=='rotate':
    android('shell','settings','put','system','user_rotation','1')
    until(lambda:screenshot('rotation-wait').width>screenshot('rotation-wait').height,'Android did not rotate')
   else:
    expected=[(meta['background'],meta['rgb'])]+list(zip(meta['cursor'],[[0,0,0],[255,255,255],meta['rgb'],[255-v for v in meta['rgb']]]))
    for point,rgb in zip(meta['orientation'],[[211,65,32],[37,80,198]]):
     if 0<=point[0]<meta['view'][0] and 0<=point[1]<meta['view'][1]:expected.append((point,rgb))
    def pixels_match():
     frame=screenshot(name)
     # Old SurfaceFlinger screenshots retain the physical display resolution
     # after `wm size`; Flutter reports coordinates in its overridden view.
     # Use WindowManager's whole logical display, since a landscape view can
     # exclude a navigation bar at the side. View width alone is insufficient.
     scale,mapping=screenshot_mapping(android,frame.size)
     (out/(name+'-display.json')).write_text(json.dumps(mapping,indent=2)+'\n')
     observations=[]
     for point,rgb in expected:
      sample=[math.floor((coordinate+.5)*scale) for coordinate in point]
      observations.append({'point':point,'sample':sample,'scale':scale,
       'expected':rgb,'actual':frame.getpixel(tuple(sample))})
     (out/(name+'-pixels.json')).write_text(json.dumps(observations,indent=2)+'\n')
     return all(max(abs(a-b) for a,b in zip(value['actual'],value['expected']))<=5 for value in observations)
    until(pixels_match,'Android color/orientation/XOR mismatch at '+name,15)
   if name=='base':color('#8a3bc1')
   elif name=='hidden':color('#2a8465')
   seen.append(name);cases.append(meta);write_private('video-'+name+'.ack','1')
   print('PASS Android video:',name,flush=True)
  time.sleep(.1)
 assert driver.wait(timeout=10)==0,'Android video test failed: '+str(out/'driver.log')
 result=read_private('video-result.json');assert result and result['passed'],result
 assert result['native_texture'] != args.fail_gpu and result['reconnections']==3
 with zipfile.ZipFile(apk) as archive:native_sha=hashlib.sha256(archive.read('lib/x86_64/liblrdp.so')).hexdigest()
 result.update(apk_sha256=sha(apk),library_sha256=native_sha,platform=device.platform+' owned emulator; system screenshots',device=device_evidence,
  stages=cases,root_used=False,physical_device_tested=False)
 (out/'VERDICT.json').write_text(json.dumps(result,indent=2)+'\n')
 print('PASS Android '+('GPU failure recovery' if args.fail_gpu else 'native Surface/EGL rendering')+', pixels, XOR, surface lifecycle, rotation and reconnect cleanup',flush=True)
