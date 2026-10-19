#!/usr/bin/env python3
"""ClipboardManager/FileProvider image test on the allowlisted disposable AVD."""
from pathlib import Path
import base64
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
from android_test_device import DEVICES, add_device_argument

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
add_device_argument(parser)
parser.add_argument('--reuse-apk',action='store_true')
args=parser.parse_args()
out=root/'build/image-clipboard'/('android-os' if args.device=='api36' else 'android-os-'+args.device)
out.mkdir(parents=True,exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)
sdk=Path('/home/lucinhu/Android/Sdk')
adb=[str(sdk/'platform-tools/adb'),'-P','5038','-s','emulator-5556']
package='dev.lrdp.lrdp'
def android(*parts,check=True,timeout=30):
    return subprocess.run(adb+list(parts),capture_output=True,text=True,check=check,timeout=timeout)
device=DEVICES[args.device].verify(android)
env=dict(os.environ,JAVA_HOME='/usr/lib/jvm/java-17-openjdk',ANDROID_SDK_ROOT=str(sdk),
    LRDP_BUILD_JOBS='3',CMAKE_BUILD_PARALLEL_LEVEL='3',
    LRDP_OPENSSL_ROOT=str(root/'build/deps/android-openssl'),LRDP_FFMPEG_ROOT=str(root/'build/deps/ffmpeg/android'))
env['PATH']=env['JAVA_HOME']+'/bin:/opt/flutter/bin:'+env['PATH']
definition=base64.b64encode(b'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false').decode()
def apk_inputs():
    digest=hashlib.sha256(b'LRDP-Android-clipboard-APK-v1\0')
    names=sorted(set(subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).split(b'\0'))-{b''})
    for raw in names:
        name=raw.decode()
        if name.startswith(('lib/','assets/','android/','packages/','native/src/','native/include/','native/cmake/')) or name in (
            'pubspec.yaml','pubspec.lock','native/CMakeLists.txt','integration_test/clipboard_image_test.dart'):
            digest.update(raw+b'\0'+(root/name).read_bytes()+b'\0')
    digest.update(subprocess.check_output(['git','-C','third_party/FreeRDP','rev-parse','HEAD'],cwd=root))
    for folder in ['build/deps/ffmpeg/android/x86_64/lib','build/deps/android-openssl/x86_64/lib']:
        for library in sorted((root/folder).glob('*.a')):
            digest.update(library.name.encode()+hashlib.sha256(library.read_bytes()).digest())
    return digest.hexdigest()
inputs=apk_inputs()
apk=out/'clipboard-integration-x86_64.apk'
if args.reuse_apk:
    cached=json.loads((out/'APK_BUILD.json').read_text())
    assert cached['inputs']==inputs and cached['sha256']==hashlib.sha256(apk.read_bytes()).hexdigest(),'APK inputs changed; rebuild'
else:
    with (out/'build.log').open('w') as log:
        subprocess.run([str(root/'android/gradlew'),'--no-daemon','--max-workers=3','-Dorg.gradle.jvmargs=-Xmx2g',
            '-Dorg.gradle.java.home='+env['JAVA_HOME'],':app:assembleDebug','-Ptarget-platform=android-x64',
            '-Ptarget='+str(root/'integration_test/clipboard_image_test.dart'),'-Pdart-defines='+definition],
            cwd=root/'android',env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    assert inputs==apk_inputs(),'Inputs changed during the integration build'
    shutil.copy2(root/'build/app/outputs/apk/debug/app-debug.apk',apk)
    (out/'APK_BUILD.json').write_text(json.dumps({'inputs':inputs,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest()},indent=2)+'\n')
subprocess.run(['python3',str(root/'scripts/check_android_apk.py'),str(apk),'--abi','x86_64',
    '--integration','--build-mode','debug'],env=env,check=True)
try:
    android('uninstall',package,check=False)
    android('install','-t',str(apk),timeout=90)
    android('shell','input','keyevent','224')
    android('shell','input','keyevent','82')
    android('shell','am','start','-W','-n',package+'/.MainActivity',timeout=90)
    end=time.monotonic()+120
    report=None
    while time.monotonic()<end:
        response=android('exec-out','run-as',package,'cat','files/lrdp-image-result.json',check=False)
        if response.returncode==0 and response.stdout.strip():
            try:
                report=json.loads(response.stdout);break
            except json.JSONDecodeError:
                # Old adbd/run-as can return diagnostics on stdout with status 0.
                (out/'last-result-read.txt').write_text(response.stdout)
        time.sleep(.3)
    assert report and report['passed'],'No passing image test result'
    report.update(device=device,apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest(),
        scope='real OS image clipboard and private content URI; no remote server or physical phone')
    (out/'VERDICT.json').write_text(json.dumps(report,indent=2)+'\n')
finally:
    (out/'logcat.log').write_text(android('logcat','-d','-s','flutter:V','AndroidRuntime:E',check=False).stdout)
    android('shell','am','force-stop',package,check=False)
    android('uninstall',package,check=False)
