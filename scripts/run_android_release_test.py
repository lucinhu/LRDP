#!/usr/bin/env python3
"""Exercise an unmodified main Release APK through Android system UI and input.

Only explicitly allowlisted owned AVDs on ADB 5038 / emulator-5556 are accepted.
No test entrypoint, run-as, root, extra app permission or private data seeding.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import ctypes as c
import hashlib
import io
import json
import os
import re
import secrets
import shlex
import select
import socket
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
from PIL import Image
from rdp_test_desktop import Desktop
from android_test_ime import TestIme
from android_test_device import DEVICES, add_device_argument

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('apk',type=Path)
parser.add_argument('--runtime-dir',type=Path,help='Separate evidence directory under this workspace build/')
parser.add_argument('--font-scale',type=float,choices=(1.0,1.4,2.0),default=1.0,
                    help='System text scale on the owned AVD; restored after testing')
parser.add_argument('--small-phone',action='store_true',
                    help='Use a 320x568 logical phone display on the owned AVD; restored afterward')
parser.add_argument('--verify-ime-control',action='store_true',
                    help='Verify real remote gestures while the IME stays visible in both input modes (API36)')
parser.add_argument('--verify-appearance',action='store_true',
                    help='Verify system/manual appearance and persisted frame-rate selection on API36')
parser.add_argument('--verify-session-ui',action='store_true',
                    help='Verify languages and full screen/floating tools through actual OS input on API36')
add_device_argument(parser)
args=parser.parse_args()
device=DEVICES[args.device]
if args.verify_ime_control and device.api!=36:
    parser.error('--verify-ime-control currently requires the owned API36 profile')
if args.verify_appearance and device.api!=36:
    parser.error('--verify-appearance requires the owned API36 profile')
if args.verify_session_ui and device.api!=36:
    parser.error('--verify-session-ui requires the owned API36 profile')
if args.small_phone and device.api!=36:
    parser.error('--small-phone currently requires the owned API36 profile for IME inset measurement')
sdk=Path(os.environ.get('ANDROID_SDK_ROOT',str(Path.home()/'Android/Sdk')))
adb=[str(sdk/'platform-tools/adb'),'-P','5038','-s','emulator-5556']
package='dev.lrdp.lrdp'
out=(root/args.runtime_dir).resolve() if args.runtime_dir else root/device.runtime('main-release')
assert out.is_relative_to(root/'build'),'Evidence must stay under this workspace build/'
out.mkdir(parents=True,exist_ok=True)
(out/'VERDICT.json').unlink(missing_ok=True)
secret=secrets.token_urlsafe(18)
translations=[json.loads((root/f'assets/l10n/{locale}.json').read_text()) for locale in ('en','zh-TW')]


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def android(*parts,check=True,timeout=25):
    return subprocess.run(adb+list(parts),capture_output=True,text=True,check=check,timeout=timeout)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()


def save_json(name,value):
    data=json.dumps(value,ensure_ascii=False,indent=2)
    assert secret not in data,'Secret must not enter evidence'
    (out/(name+'.json')).write_text(data+'\n')


def capture(name):
    data=subprocess.check_output(adb+['exec-out','screencap','-p'],timeout=25)
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    (out/(name+'.png')).write_bytes(data)
    return Image.open(io.BytesIO(data)).convert('RGB')


def visible_ime_bounds():
    output=android('shell','dumpsys','window').stdout
    rectangles=re.findall(r'InsetsSource[^\n]*?type=ime frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\][^\n]*?\bvisible=true',output)
    values=[list(map(int,rectangle)) for rectangle in rectangles]
    return max(values,key=lambda b:(b[2]-b[0])*(b[3]-b[1])) if values else None


class Input:
    def __init__(self,log):
        self.p=subprocess.Popen(adb+['shell','env','CLASSPATH=/data/local/tmp/lrdp-release-input.dex',
            'app_process','/system/bin','TouchInjector'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=log,text=True,bufsize=1)
        self.reply('ready')

    def reply(self,key):
        assert select.select([self.p.stdout],[],[],20)[0],'OS input helper did not respond'
        line=self.p.stdout.readline()
        assert line and json.loads(line).get(key),'OS input dispatch failed'

    def send(self,action,**values):
        self.p.stdin.write(json.dumps({'action':action,**values})+'\n');self.p.stdin.flush();self.reply('ok')

    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try:self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:stop(self.p)


class UI:
    def __init__(self,input):self.input=input;self.legacy_field_lookups=0;self.fullscreen_hint_dismissals=0

    def nodes(self):
        destination='/proc/self/fd/1' if device.api < 26 else '/dev/stdout'
        result=android('exec-out','uiautomator','dump','--compressed',destination,check=False,timeout=25)
        text=result.stdout
        assert secret not in text,'Password is exposed in accessibility output'
        if '<hierarchy' not in text:return []
        xml=text[text.index('<?xml') if '<?xml' in text else text.index('<hierarchy'):]
        xml=xml[:xml.rindex('</hierarchy>')+len('</hierarchy>')]
        nodes=list(ET.fromstring(xml).iter('node'))
        # Android's first immersive entry shows a system-owned education sheet
        # above LRDP. Acknowledge it as a user would; never bypass RDP trust UI.
        if any('Viewing full screen' in self.label(node) for node in nodes):
            button=next((node for node in nodes if node.get('text')=='Got it'),None)
            if button is not None:
                self.tap(button);self.fullscreen_hint_dismissals+=1
                return []
        return nodes

    @staticmethod
    def label(node):return '\n'.join(node.get(key,'') for key in ('text','content-desc','hint'))

    @staticmethod
    def bounds(node):
        values=[int(x) for x in re.findall(r'-?\d+',node.get('bounds',''))]
        return values if len(values)==4 else [0,0,0,0]

    def find(self,label,field=False):
        nodes=self.nodes()
        labels={label,*(catalog.get(label,label) for catalog in translations)}
        matches=[node for node in nodes if any(value in self.label(node) for value in labels)
            and (not field or node.get('class')=='android.widget.EditText')]
        matches=[n for n in matches if (b:=self.bounds(n))[2]>b[0] and b[3]>b[1]]
        if field and not matches and device.api < 28:
            # Flutter does not expose field hints to old Android accessibility
            # APIs. Anchor the known form by its visible route, role structure
            # and password flag; all text still enters through OS key events.
            fields=sorted((n for n in nodes if n.get('class')=='android.widget.EditText'
                and (b:=self.bounds(n))[2]>b[0] and b[3]>b[1]),key=lambda n:self.bounds(n)[1])
            profile={'电脑地址':0,'显示名称':1,'用户名':2,'域':3,'密码':4}
            if (label in profile and len(fields)==5 and fields[-1].get('password')=='true'
                and any('添加远程电脑' in self.label(n) for n in nodes)):
                matches=[fields[profile[label]]]
            elif label in ('用户名','域（选填）','密码') and len(fields)==3 and fields[-1].get('password')=='true' and any('连接到 ' in self.label(n) for n in nodes):
                matches=[fields[{'用户名':0,'域（选填）':1,'密码':2}[label]]]
            elif len(fields)==1 and (
                (label=='文字输入' and any('发送文字' in self.label(n) for n in nodes)) or
                (label in ('键盘模拟','键盘模拟 · 输入即发送') and any('显示键盘' in self.label(n) for n in nodes))):
                matches=fields
            if matches:self.legacy_field_lookups+=1
        exact=[n for n in matches if any(n.get(key,'').strip() in labels for key in ('text','content-desc','hint'))]
        if exact:matches=exact
        return min(matches,key=lambda n:(self.bounds(n)[2]-self.bounds(n)[0])*(self.bounds(n)[3]-self.bounds(n)[1])) if matches else None

    def tap(self,node,x_fraction=.5):
        x1,y1,x2,y2=self.bounds(node)
        self.input.send('tap',**{'from':[[x1+(x2-x1)*x_fraction,(y1+y2)/2]],'duration':70})

    def enter(self,label,value):
        node=self.find(label,field=True)
        assert node is not None,'Missing field: '+label
        self.tap(node)
        until(lambda:(current:=self.find(label,field=True)) is not None and current.get('focused')=='true',
              'Field did not receive focus: '+label)
        self.input.send('text',value=value)
        if node.get('password')!='true':
            until(lambda:(current:=self.find(label,field=True)) is not None and current.get('text')==value,
                  'Field did not receive its expected text: '+label)
        android('shell','input','keyevent','KEYCODE_BACK')

    def dump(self,name):
        # Only retain already-checked, password-redacted accessibility data.
        save_json(name,[n.attrib for n in self.nodes()])


assert args.apk.is_file()
assert args.apk.resolve().is_relative_to(root/'build'), 'Use a locally built APK from this workspace'
device_evidence=device.verify(android)
focus=android('shell','dumpsys','window').stdout
assert 'Application Not Responding' not in '\n'.join(l for l in focus.splitlines() if 'mCurrentFocus=' in l),'Resolve OS startup ANR before testing the app'
subprocess.run(['python3',str(root/'scripts/check_android_apk.py'),str(args.apk),'--abi','x86_64','--build-mode','release'],check=True)

with tempfile.TemporaryDirectory(prefix='lrdp-main-release-') as temporary,ExitStack() as cleanup:
    private=Path(temporary)
    rotation_before={name:android('shell','settings','get','system',name).stdout.strip()
                     for name in ('accelerometer_rotation','user_rotation')}
    rotation_mode=android('shell','wm','user-rotation',check=False)
    rotation_mode_before=rotation_mode.stdout.strip() if rotation_mode.returncode==0 else None
    def restore_rotation():
        if rotation_mode_before is not None:
            parts=['free'] if rotation_mode_before=='free' else ['lock',rotation_before['user_rotation']]
            android('shell','wm','user-rotation',*parts,check=False)
        for name,previous in rotation_before.items():
            android('shell','settings','delete' if previous=='null' else 'put','system',name,
                    *([] if previous=='null' else [previous]),check=False)
    cleanup.callback(restore_rotation)
    font_before=android('shell','settings','get','system','font_scale').stdout.strip()
    def restore_font():
        android('shell','settings','delete' if font_before=='null' else 'put','system','font_scale',
                *([] if font_before=='null' else [font_before]),check=False)
    cleanup.callback(restore_font)
    android('shell','settings','put','system','font_scale',str(args.font_scale))
    assert float(android('shell','settings','get','system','font_scale').stdout.strip())==args.font_scale
    display_before={name:android('shell','wm',name).stdout for name in ('size','density')}
    if args.small_phone:
        def restore_display():
            for name,output in display_before.items():
                override=re.search(r'Override '+name+r':\s*(\S+)',output)
                android('shell','wm',name,override[1] if override else 'reset',check=False)
        cleanup.callback(restore_display)
        android('shell','wm','size','720x1280');android('shell','wm','density','360')
        # Updating an unchanged user_rotation setting need not override the
        # orientation chosen by the sensor. Explicitly lock this owned display.
        android('shell','wm','user-rotation','lock','0')
    env=dict(os.environ,DISPLAY=':'+str(next(n for n in range(101,201) if not Path(f'/tmp/.X11-unix/X{n}').exists())),XDG_CONFIG_HOME=str(private/'config'))
    log=cleanup.enter_context((out/'display.log').open('w'))
    desktop_process=subprocess.Popen(['Xvnc',env['DISPLAY'],'-geometry','1280x800','-depth','24','-SecurityTypes','None',
        '-noreset','-rfbport','-1','-rfbunixpath',str(private/'vnc.sock'),'-rfbunixmode','0600','-nolisten','tcp'],env=env,stdout=log,stderr=subprocess.STDOUT)
    cleanup.callback(stop,desktop_process)
    def until(predicate,reason,timeout=40):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            if 'desktop' in globals():desktop.pump()
            if predicate():return
            time.sleep(.12)
        capture('failure')
        raise AssertionError(reason)
    until(lambda:Path('/tmp/.X11-unix/X'+env['DISPLAY'][1:]).exists(),'Private X display did not start')
    subprocess.run(['xsetroot','-solid','#182d28'],env=env,check=True)
    desktop=Desktop(env['DISPLAY']);cleanup.callback(desktop.close);desktop.movable_window()
    desktop.position=(440,280)
    desktop.fn('XMoveWindow',c.c_int,c.c_void_p,c.c_ulong,c.c_int,c.c_int)(desktop.display,desktop.window,*desktop.position)
    desktop.sync()
    digest=subprocess.run(['openssl','dgst','-md4','-provider','legacy'],input=secret.encode('utf-16le'),capture_output=True,check=True).stdout.decode().strip().split()[-1]
    sam=private/'SAM';sam.write_text('lrdptest:::'+digest+':\n');sam.chmod(0o600)
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    log=cleanup.enter_context((out/'rdp-server.log').open('w'))
    server=subprocess.Popen(['freerdp-shadow-cli3','/bind-address:127.0.0.1',f'/port:{port}','/sec:nla',f'/sam-file:{sam}',
        '+may-view','+may-interact','+gfx-avc420','-gfx-avc444','/log-level:WARN'],env=env,stdout=log,stderr=subprocess.STDOUT);cleanup.callback(stop,server)
    until(lambda:any(l.split()[1]==f'0100007F:{port:04X}' and l.split()[3]=='0A' for l in Path('/proc/net/tcp').read_text().splitlines()[1:]),'RDP peer did not listen')
    android('reverse',f'tcp:{port}',f'tcp:{port}');cleanup.callback(android,'reverse','--remove',f'tcp:{port}',check=False)
    android('shell','am','force-stop',package)
    android('install','-r',str(args.apk),timeout=60)
    android('shell','pm','clear',package)
    cleanup.callback(android,'shell','pm','clear',package,check=False)
    cleanup.callback(android,'shell','am','force-stop',package,check=False)
    package_info=android('shell','dumpsys','package',package).stdout
    flag_lines=[l.strip() for l in package_info.splitlines() if 'flags=[' in l or 'pkgFlags=[' in l]
    assert flag_lines and all('DEBUGGABLE' not in l for l in flag_lines),flag_lines
    assert android('shell','run-as',package,'id',check=False).returncode!=0,'Release unexpectedly permits run-as'
    installed=android('shell','pm','path',package).stdout.strip().removeprefix('package:')
    checksum=android('shell','sha256sum',installed,check=False)
    if checksum.returncode==0:
        installed_sha=checksum.stdout.split()[0]
        installed_hash_probe='device sha256sum'
    else:
        # Android 7 lacks sha256sum. The install APK is shell-readable code,
        # independent of the application's protected credential/data directory.
        installed_bytes=subprocess.check_output(adb+['exec-out','cat',installed],timeout=60)
        installed_sha=hashlib.sha256(installed_bytes).hexdigest()
        installed_hash_probe='host SHA256 of shell-readable installed APK bytes'
    assert installed_sha==sha(args.apk)
    java=dict(os.environ,JAVA_HOME='/usr/lib/jvm/java-17-openjdk')
    classes=private/'classes';classes.mkdir();dex=private/'dex';dex.mkdir()
    subprocess.run([java['JAVA_HOME']+'/bin/javac','--release','8','-cp',str(sdk/'platforms/android-36/android.jar'),'-d',str(classes),str(root/'native/tests/android_gestures/TouchInjector.java')],check=True)
    subprocess.run([str(sdk/'build-tools/36.0.0/d8'),'--lib',str(sdk/'platforms/android-36/android.jar'),'--output',str(dex),*[str(p) for p in classes.glob('*.class')]],env=java,check=True)
    android('push',str(dex/'classes.dex'),'/data/local/tmp/lrdp-release-input.dex');cleanup.callback(android,'shell','rm','-f','/data/local/tmp/lrdp-release-input.dex',check=False)
    injector=Input(cleanup.enter_context((out/'input-helper.log').open('w')));cleanup.callback(injector.close)
    ui=UI(injector)
    def find(label,field=False,scroll=False,reverse=False):
        node=ui.find(label,field)
        if node is None and label in ('返回电脑列表（保持连接）','键盘','触控板','触屏','更多','退出全屏','全屏'):
            collapsed=ui.find('展开会话工具')
            if collapsed is not None:
                ui.tap(collapsed)
                until(lambda:ui.find(label,field) is not None,'Floating action unavailable: '+label)
                node=ui.find(label,field)
        if node is None and scroll:
            for _ in range(8):
                scrollables=[n for n in ui.nodes() if n.get('scrollable')=='true'
                    and n.get('class') not in ('android.widget.HorizontalScrollView','android.widget.EditText')
                    and (b:=ui.bounds(n))[2]>b[0] and b[3]>b[1]]
                if scrollables:
                    left,top,right,bottom=ui.bounds(min(scrollables,key=lambda n:(ui.bounds(n)[2]-ui.bounds(n)[0])*(ui.bounds(n)[3]-ui.bounds(n)[1])))
                else:
                    image=capture('scroll-search');left,top,right,bottom=0,0,image.width,image.height
                x=(left+right)/2
                start,end=(.2,.8) if reverse else (.8,.2)
                injector.send('swipe',**{'from':[[x,top+(bottom-top)*start]],'to':[[x,top+(bottom-top)*end]],'duration':350})
                node=ui.find(label,field)
                if node is not None:break
        assert node is not None,'Missing UI control: '+label
        return node
    def tap(label,scroll=False):ui.tap(find(label,scroll=scroll))
    def open_profile(label):
        # A large-text card's centre can lie underneath the floating Add button.
        # Its visible left portion is also the actual card tap target.
        ui.tap(find(label,scroll=True),x_fraction=.15)
    def launch():
        try:
            android('shell','am','start','-W','-n',package+'/.MainActivity',timeout=30)
        except subprocess.CalledProcessError as error:
            save_json('activity-launch-failure',{'returncode':error.returncode,
                      'stdout':error.stdout,'stderr':error.stderr})
            raise
        if args.small_phone:
            # The owned API36 image can restore a task's landscape lock during
            # Activity launch. Set the test orientation after that transition.
            android('shell','wm','user-rotation','lock','0')
            until(lambda:(image:=capture('app-orientation')).width<image.height,'App did not enter portrait')
    def connection():
        return [tuple(l.split()[i] for i in (1,2,9)) for l in Path('/proc/net/tcp').read_text().splitlines()[1:]
            if l.split()[1]==f'0100007F:{port:04X}' and l.split()[3]=='01']
    if args.small_phone:
        until(lambda:(image:=capture('initial-orientation')).width<image.height,'Small phone did not enter portrait')
    launch();until(lambda:ui.find('添加电脑') is not None,'Workspace accessibility controls unavailable',60)
    session_ui_cases=[]
    def choose_language(name):
        tap('设置');tap('语言');tap(name)
        tap('电脑')
    # Choose the interaction suite's language through customer UI, rather than
    # seeding preferences or depending on the AVD's system locale.
    if args.verify_session_ui:
        for language,name,heading in [('zh-TW','繁體中文','我的電腦'),('en','English','My computers'),('zh-CN','简体中文','我的电脑')]:
            choose_language(name)
            until(lambda:any(heading in ui.label(node) for node in ui.nodes()),'Language did not switch: '+language)
            capture('language-'+language)
            session_ui_cases.append({'name':'Actual UI language switch '+language})
    else:
        choose_language('简体中文')
    appearance_cases=[]
    if args.verify_appearance:
        previous=android('shell','cmd','uimode','night').stdout
        match=re.search(r'Night mode:\s*(auto|no|yes|custom)',previous)
        assert match,previous
        cleanup.callback(android,'shell','cmd','uimode','night',match[1],check=False)
        tap('设置');until(lambda:ui.find('主题模式') is not None,'Appearance settings did not open')
        def brightness(name,dark):
            def check():
                image=capture(name)
                return (sum(image.getpixel((4,image.height//2)))/3<100)==dark
            until(check,'Appearance brightness did not follow '+name)
        android('shell','cmd','uimode','night','no');brightness('settings-system-light',False)
        # Android's supplied primary tone must actually appear in the rendered
        # app, proving the native palette reaches Material (not just a toggle).
        palette=android('shell','cmd','overlay','lookup','android','android:color/system_accent1_600').stdout.strip()
        primary=re.findall(r'#[0-9a-fA-F]{8}',palette)
        assert primary,palette
        rgb=tuple(bytes.fromhex(primary[-1][3:]))
        image=capture('settings-system-palette')
        assert sum(1 for pixel in image.getdata() if pixel==rgb)>20,('System primary not rendered',rgb)
        android('shell','cmd','uimode','night','yes');brightness('settings-system-dark',True)
        tap('跟随系统');tap('浅色');brightness('settings-manual-light',False)
        tap('浅色');tap('跟随系统');brightness('settings-auto-restored',True)
        tap('自动（跟随屏幕）',scroll=True);tap('120 帧/秒',scroll=True)
        android('shell','am','force-stop',package);launch()
        until(lambda:ui.find('添加电脑') is not None,'App did not restart after preference save')
        tap('设置');find('120 帧/秒',scroll=True)
        brightness('settings-preferences-restored',True)
        tap('120 帧/秒',scroll=True);tap('自动（跟随屏幕）',scroll=True)
        tap('电脑');until(lambda:ui.find('添加电脑') is not None,'Workspace did not return')
        appearance_cases=[{'name':'System palette rendered from actual Android resource','primary_rgb':rgb},
            {'name':'System light/dark, manual override and auto restore'},
            {'name':'120 fps preference survives process restart; auto restored','physical_high_refresh_screen':False}]
        print('PASS: actual Android system palette/brightness, manual override and frame-rate persistence',flush=True)
    capture('workspace');ui.dump('workspace-ui');tap('添加电脑')
    until(lambda:ui.find('电脑地址',True) is not None,'Profile editor accessibility fields unavailable')
    ui.dump('editor-open');print('Main Release profile editor opened',flush=True)
    ui.enter('电脑地址',f'127.0.0.1:{port}');ui.enter('显示名称','Release OS test');ui.enter('用户名','lrdptest')
    if ui.find('密码',True) is None:find('密码',field=True,scroll=True)
    ui.enter('密码',secret)
    tap('记住密码',scroll=True)
    ui.dump('profile-filled');tap('保存并连接',scroll=True)
    until(lambda:ui.find('确认远程电脑的身份') is not None,'Certificate prompt did not open',60)
    print('Actual NLA peer certificate prompt displayed',flush=True)
    capture('certificate');tap('在此设备记住这个指纹',scroll=True);tap('指纹匹配，继续')
    until(lambda:ui.find('远程桌面。') is not None and len(connection())==1,'Main Release did not receive a real desktop',60)
    surface=ui.find('远程桌面。');bounds=ui.bounds(surface)
    assert bounds[2]>bounds[0] and bounds[3]>bounds[1]
    first_connection=connection()[0]
    native_presentations=[]
    def native_render_ready():
        pid=android('shell','pidof',package).stdout.strip()
        if not pid:return False
        output=android('logcat','-d','--pid='+pid,'-s','LRDP-video:I').stdout
        native_presentations[:]=re.findall(r'Native frame (\d+)x(\d+)',output)
        return ('1280','800') in native_presentations
    until(native_render_ready,'Main Release did not present a native GPU frame')
    capture('connected');ui.dump('connected-ui');print('Main AOT received actual NLA desktop',flush=True)
    if args.verify_session_ui:
        image=capture('session-fullscreen')
        assert bounds==[0,0,image.width,image.height],('Remote surface does not fill the screen',bounds,image.size)
        tap('收起会话工具');collapsed=find('展开会话工具');old_bounds=ui.bounds(collapsed)
        center=[(old_bounds[0]+old_bounds[2])/2,(old_bounds[1]+old_bounds[3])/2]
        injector.send('swipe',**{'from':[center],'to':[[image.width*.2,image.height*.6]],'duration':450})
        until(lambda:(node:=ui.find('展开会话工具')) is not None and ui.bounds(node)!=old_bounds,'Floating control did not move')
        moved=ui.bounds(find('展开会话工具'));ui.tap(find('展开会话工具'))
        find('收起会话工具');capture('session-tools-moved')
        tap('退出全屏')
        until(lambda:ui.bounds(find('远程桌面。'))!=bounds,'Exit full screen kept the same viewport')
        tap('全屏')
        until(lambda:ui.bounds(find('远程桌面。'))==bounds,'Full screen did not restore the viewport')
        tap('收起会话工具');collapsed=find('展开会话工具');current=ui.bounds(collapsed)
        injector.send('swipe',**{'from':[[(current[0]+current[2])/2,(current[1]+current[3])/2]],
            'to':[[image.width-20,40]],'duration':450})
        android('shell','wm','user-rotation','lock','1')
        until(lambda:(rotated:=capture('session-tools-landscape')).width>rotated.height,'Landscape did not apply')
        rotated=capture('session-tools-landscape');floating=ui.bounds(find('展开会话工具'))
        assert 0<=floating[0]<floating[2]<=rotated.width and 0<=floating[1]<floating[3]<=rotated.height
        android('shell','wm','user-rotation','lock','0')
        until(lambda:(portrait:=capture('session-tools-portrait')).width<portrait.height,'Portrait did not restore')
        tap('展开会话工具')
        assert connection()==[first_connection]
        session_ui_cases.append({'name':'Full-screen viewport, draggable/collapsible tools and orientation keep the same TCP session',
            'fullscreen_bounds':bounds,'moved_collapsed_bounds':moved,'rotated_collapsed_bounds':floating})
    def point(x,y):
        left,top,right,bottom=bounds;scale=min((right-left)/1280,(bottom-top)/800)
        return [(left+right)/2+(x-640)*scale,(top+bottom)/2+(y-400)*scale]
    def pump_until(predicate,reason):
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            desktop.pump()
            if predicate():return
            time.sleep(.04)
        capture('failure')
        save_json('input-failure',{'reason':reason,'events':desktop.events[-64:],'keys':desktop.keys[-64:],
                                 'pointer':desktop.pointer(),'window':desktop.geometry()})
        raise AssertionError(reason)
    cases=list(appearance_cases)+session_ui_cases
    def clicks(expected,action,name):
        desktop.pump();start=len(desktop.events);action()
        pump_until(lambda:len([e for e in desktop.events[start:] if e['type'] in (4,5)])>=2,name+' missing')
        events=[e for e in desktop.events[start:] if e['type'] in (4,5)]
        assert [(e['type'],e['button']) for e in events]==[(4,expected),(5,expected)],(name,events)
        assert not desktop.pointer()['mask']&0x700,(name,'button still held')
        cases.append({'name':name,'events':events});print('PASS OS input:',name,flush=True);return events
    clicks(1,lambda:injector.send('tap',**{'from':[point(640,400)],'duration':70}),'trackpad tap')
    tap('触控板')
    until(lambda:ui.find('触屏') is not None,'Direct-touch mode did not paint')
    events=clicks(1,lambda:injector.send('tap',**{'from':[point(650,420)],'duration':70}),'direct tap')
    assert all(abs(e['x']-650)<=1 and abs(e['y']-420)<=1 for e in events),events
    time.sleep(.6);desktop.pump();start=len(desktop.events)
    desktop.detect_double_clicks=True
    injector.send('drag',**{'from':[point(500,295)],'to':[point(640,375)],'duration':400,'hold':True})
    pump_until(lambda:desktop.dragging and desktop.pointer()['mask']&256
        and abs(desktop.geometry()[0]-580)<=2 and abs(desktop.geometry()[1]-360)<=2,
        'Main Release drag did not reach the target while holding the button')
    held=desktop.pointer();moved=desktop.geometry();assert abs(moved[0]-580)<=2 and abs(moved[1]-360)<=2,moved
    injector.send('up');pump_until(lambda:not desktop.dragging and not desktop.pointer()['mask']&256,'Main Release drag did not release')
    assert [(e['type'],e['button']) for e in desktop.events[start:] if e['type'] in (4,5)]==[(4,1),(5,1)]
    assert desktop.double_clicks==0,'Drag was interpreted as a titlebar double click'
    cases.append({'name':'window drag without double click/release','held':held,'geometry':moved,'double_clicks':desktop.double_clicks})
    time.sleep(.4)
    clicks(1,lambda:injector.send('tap',**{'from':[point(660,450)],'duration':70}),'tap after drag')
    assert desktop.geometry()==moved,'Window kept dragging after release'
    time.sleep(.4)
    clicks(3,lambda:injector.send('tap',**{'from':[point(620,450),point(700,450)],'duration':70}),'two-finger right click')
    desktop.pump();start=len(desktop.events)
    injector.send('swipe',**{'from':[point(480,300),point(800,300)],'to':[point(480,700),point(800,700)],'duration':450})
    pump_until(lambda:any(e['type']==5 and e['button']==4 for e in desktop.events[start:]),'Two-finger scroll missing')
    wheel=[e for e in desktop.events[start:] if e['type'] in (4,5)]
    assert wheel and [(e['type'],e['button']) for e in wheel]==[(k,4) for _ in range(len(wheel)//2) for k in (4,5)],wheel
    cases.append({'name':'two-finger scroll','events':wheel})
    ime=TestIme(sdk,adb,out,device=args.device);cleanup.callback(ime.close)
    tap('键盘')
    until(lambda:ui.find('输入模式：键盘模拟') is not None,'New connections must default to keyboard simulation')
    cases.append({'name':'Default input mode is keyboard simulation; local input box is hidden'})
    tap('输入模式：键盘模拟');tap('文字输入')
    until(lambda:ui.find('文字输入',field=True) is not None,'Mobile text composer did not open')
    def check_ime_control(keys):
        mode='keys' if keys else 'text'
        until(lambda:visible_ime_bounds() is not None,'IME did not open for remote control')
        rectangle=ui.bounds(find('远程桌面。'))
        left,top,right,bottom=rectangle;scale=min((right-left)/1280,(bottom-top)/800)
        assert scale>0,'No remote viewport remains above the IME'
        def at(x,y):return [(left+right)/2+(x-640)*scale,(top+bottom)/2+(y-400)*scale]
        desktop.pump();event_start=len(desktop.events);key_start=len(desktop.keys)
        for button,points in ((1,[at(660,450)]),(3,[at(620,450),at(700,450)])):
            start=len(desktop.events)
            injector.send('tap',**{'from':points,'duration':70})
            pump_until(lambda:any(e['type']==5 and e['button']==button for e in desktop.events[start:]),'IME-open remote tap missing')
            assert [(e['type'],e['button']) for e in desktop.events[start:] if e['type'] in (4,5)]==[(4,button),(5,button)]
            assert visible_ime_bounds() is not None,'Remote tap hid the IME'
            time.sleep(.4)
        start=len(desktop.events)
        injector.send('swipe',**{'from':[at(480,100),at(800,100)],'to':[at(480,750),at(800,750)],'duration':450})
        pump_until(lambda:any(e['type']==5 and e['button']==4 for e in desktop.events[start:]),'IME-open scroll missing')
        assert visible_ime_bounds() is not None,'Remote scroll hid the IME'
        x,y,_,_=desktop.geometry()
        injector.send('drag',**{'from':[at(x+60,y+15)],'to':[at(x+130,y+55)],'duration':400,'hold':True})
        try:
            pump_until(lambda:desktop.dragging and desktop.pointer()['mask']&256
                       and abs(desktop.geometry()[0]-(x+70))<=2 and abs(desktop.geometry()[1]-(y+40))<=2,
                       'IME-open held drag did not move the remote window')
            held=desktop.geometry()
        finally:injector.send('up')
        pump_until(lambda:not desktop.dragging and not desktop.pointer()['mask']&0x700,'IME-open drag did not release')
        assert visible_ime_bounds() is not None,'Remote drag hid the IME'
        if keys:
            assert all(n.get('class')!='android.widget.EditText' for n in ui.nodes()),'Simulation mode exposes an input box'
            ime.send('commit','b');ime.send('delete')
            pump_until(lambda:len([e for e in desktop.keys[key_start:] if e['type']==2 and e['text']])>=2,'IME stopped sending after remote gestures')
            assert [e['text'] for e in desktop.keys[key_start:] if e['type']==2 and e['text']]==['b','\b']
        else:
            ime.send('compose','a')
            until(lambda:ui.find('a',field=True) is not None,'Composer stopped receiving after remote gestures')
            ime.send('compose','');ime.send('finish')
            desktop.pump();assert len(desktop.keys)==key_start,'Local text draft was sent without approval'
        assert visible_ime_bounds() is not None,'IME closed after continuing input'
        if keys:
            android('shell','input','keyevent','KEYCODE_BACK')
            until(lambda:visible_ime_bounds() is None,'System Back did not hide the keyboard')
            tap('显示键盘')
            until(lambda:visible_ime_bounds() is not None,'Show keyboard did not reopen the hidden input client')
            ime.send('finish')
        capture('keyboard-control-'+mode)
        cases.append({'name':'IME remains open during real remote taps right-click scroll and continued input '+mode,
                      'viewport_bounds':rectangle,'ime_bounds':visible_ime_bounds(),
                      'input_box_visible':not keys,'held_window_geometry':held,
                      'keyboard_reopened_after_system_back':keys,
                      'input_connection_verified_after_reopen':keys,
                      'release_pointer_mask':desktop.pointer()['mask'],
                      'events':desktop.events[event_start:],'keys':desktop.keys[key_start:]})
    if args.verify_ime_control:check_ime_control(False)
    tap('输入模式：文字输入');tap('键盘模拟')
    until(lambda:ui.find('显示键盘') is not None,'IME keyboard mode did not open')
    assert all(n.get('class')!='android.widget.EditText' for n in ui.nodes()),'Simulation mode exposes an input box'
    if args.verify_ime_control:check_ime_control(True)
    desktop.pump();key_start=len(desktop.keys)
    ime.send('compose','a');ime.send('finish');ime.send('commit','A1!');ime.send('delete');ime.send('enter')
    def typed():return [e['text'] for e in desktop.keys[key_start:] if e['type']==2 and e['text']]
    pump_until(lambda:len(typed())>=6,'Android IME keys did not reach remote X11')
    assert typed()==['a','A','1','!','\b','\r'],desktop.keys[key_start:]
    cases.append({'name':'actual Android InputConnection composition/commit/Backspace/Enter to RDP scan codes',
        'typed':typed(),'events':desktop.keys[key_start:],'keyboard':'isolated test IME, no app permission'})
    capture('keyboard-simulation')
    if device.api >= 36:
        desktop.pump();modifier_start=len(desktop.keys)
        tap('Ctrl');ime.send('commit',' ')
        pump_until(lambda:any(e['type']==2 and e['symbol']==32 and e['state']&4 for e in desktop.keys[modifier_start:]),
                   'Latched Ctrl did not combine with actual IME Space')
        tap('Ctrl');tap('Shift')
        surface=ui.bounds(find('远程桌面。'))
        desktop.pump();shift_touch_start=len(desktop.events)
        wx,wy,ww,wh=desktop.geometry();scale=min((surface[2]-surface[0])/1280,(surface[3]-surface[1])/800)
        target=[(surface[0]+surface[2])/2+(wx+ww/2-640)*scale,
                (surface[1]+surface[3])/2+(wy+wh/2-400)*scale]
        injector.send('tap',**{'from':[target],'duration':70})
        pump_until(lambda:any(e['type']==5 and e['button']==1 and e['state']&1 for e in desktop.events[shift_touch_start:]),
                   'Shift+remote touch did not reach the remote desktop with the modifier held')
        assert desktop.pointer()['mask']&1,'Remote touch released latched Shift'
        assert visible_ime_bounds() is not None,'Shift+remote touch hid the IME'
        ime.send('commit','A');ime.send('commit','b')
        pump_until(lambda:len([e for e in desktop.keys[modifier_start:] if e['type']==2 and e['text'] in ('A','B')])==2,
                   'Latched Shift did not survive uppercase IME input')
        assert all(e['state']&1 for e in desktop.keys[modifier_start:] if e['type']==2 and e['text'] in ('A','B'))
        assert len([e for e in desktop.keys[modifier_start:] if e['type']==2 and e['symbol']==65505])==1
        capture('sticky-shift-held');tap('Shift');ime.send('commit','c')
        pump_until(lambda:any(e['type']==2 and e['text']=='c' and not e['state']&1 for e in desktop.keys[modifier_start:]),
                   'Shift was not released by toggling its button')
        if ui.find('展开特殊按键') is not None:tap('展开特殊按键')
        def special_key(label):
            def exact():
                node=ui.find(label)
                return node if node is not None and label in ui.label(node).splitlines() else None
            node=exact()
            for _ in range(18):
                if node is not None:break
                floor=ui.bounds(find('Ctrl'))[1];ceiling=ui.bounds(find('输入模式：键盘模拟'))[1]
                panes=[n for n in ui.nodes() if n.get('scrollable')=='true' and
                       (b:=ui.bounds(n))[2]-b[0]>2*(b[3]-b[1]) and b[1]>=floor and b[3]<=ceiling]
                assert panes,'Special-key horizontal scroll area unavailable'
                left,top,right,bottom=ui.bounds(max(panes,key=lambda n:ui.bounds(n)[1]))
                injector.send('swipe',**{'from':[[left+(right-left)*.8,(top+bottom)/2]],
                                       'to':[[left+(right-left)*.2,(top+bottom)/2]],'duration':220})
                node=exact()
            assert node is not None,'Special key unavailable: '+label
            ui.tap(node)
        special_key('F1');special_key('F12')
        pump_until(lambda:len([e for e in desktop.keys[modifier_start:] if e['type']==2 and e['symbol'] in (65470,65481)])==2,
                   'Android function key buttons did not reach the remote desktop')
        tap('Alt');pump_until(lambda:desktop.pointer()['mask']&8,'Alt was not held remotely')
        tap('收起键盘');pump_until(lambda:not desktop.pointer()['mask']&(1|4|8|64),'Closing the keyboard retained a remote modifier')
        tap('键盘');until(lambda:ui.find('显示键盘') is not None,'Keyboard simulation mode did not survive closing')
        modifier_events=desktop.keys[modifier_start:]
        assert sorted(e['symbol'] for e in modifier_events if e['type']==2)==sorted(e['symbol'] for e in modifier_events if e['type']==3),modifier_events
        assert visible_ime_bounds() is not None,'Special keys hid the IME'
        cases.append({'name':'Latched Ctrl+IME Space, sticky Shift, F1/F12 and Alt release on close via actual Android OS input',
                      'events':modifier_events,'function_keys':[1,12],'held_alt_released_on_close':True,'remote_tap_while_shift_held':True,
                      'no_visible_simulation_input_box':all(n.get('class')!='android.widget.EditText' for n in ui.nodes())})
    if args.small_phone and args.font_scale==2.0:
        key_count=len(desktop.keys)
        ime.send('compose','中文');ime.send('finish')
        error='此内容无法模拟为按键'
        def ime_rectangle():
            # UIAutomator's active application tree omits the separate IME
            # window. Read its visible WindowManager inset instead.
            output=android('shell','dumpsys','window').stdout
            rectangles=re.findall(r'InsetsSource[^\n]*?type=ime frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\][^\n]*?\bvisible=true',output)
            values=[list(map(int,rectangle)) for rectangle in rectangles]
            return max(values,key=lambda b:(b[2]-b[0])*(b[3]-b[1])) if values else None
        for rotation,name in ((0,'portrait'),(1,'landscape')):
            android('shell','wm','user-rotation','lock',str(rotation))
            until(lambda:((image:=capture('layout-probe')).width>image.height)==bool(rotation),'Display rotation did not settle')
            # The system can hide its IME on the forced configuration change.
            # Tap the real field to reopen it before measuring the tight layout.
            ui.tap(find('显示键盘',scroll=True,reverse=True))
            try:
                until(lambda:(rectangle:=ime_rectangle()) is not None and rectangle[3]-rectangle[1]>=360,
                      'Small-phone test IME did not occupy at least 160dp at 360dpi')
            except AssertionError:
                save_json('ime-layout-failure',{'orientation':name,'ime_bounds':ime_rectangle(),
                          'window':android('shell','dumpsys','window').stdout.replace(secret,'<redacted>'),
                          'input_method':android('shell','dumpsys','input_method').stdout.replace(secret,'<redacted>')})
                ui.dump('ime-layout-failure-ui')
                raise
            ime_bounds=ime_rectangle()
            assert ime_bounds[3]-ime_bounds[1]>=360,'Small-phone test IME must occupy at least 160dp at 360dpi'
            ime.send('finish')
            # Choose both modes with the real IME still open, including the
            # short landscape viewport; menu focus must not move its targets.
            tap('输入模式：键盘模拟',scroll=True)
            assert ime_rectangle() is not None,'Opening the mode menu hid the IME'
            menu_bounds=ui.bounds(find('文字输入'))
            assert menu_bounds[3]<=ime_bounds[1],'Text mode is covered by the system IME'
            capture('mode-menu-'+name)
            tap('文字输入')
            until(lambda:ui.find('文字输入',field=True) is not None,'Text mode was not selected')
            until(lambda:ime_rectangle() is not None,'Mode selection hid the IME')
            tap('输入模式：文字输入',scroll=True)
            assert ime_rectangle() is not None,'Opening the mode menu hid the IME'
            assert ui.bounds(find('键盘模拟'))[3]<=ime_bounds[1],'Keyboard mode is covered by the system IME'
            tap('键盘模拟')
            until(lambda:ui.find('显示键盘') is not None,'Keyboard mode was not selected')
            until(lambda:ime_rectangle() is not None,'Mode selection hid the IME')
            ime.send('compose','中文');ime.send('finish')
            # Reveal the complete last paragraph, rather than accepting a
            # partially clipped accessibility node as a visual reading check.
            for _ in range(2):
                panes=[n for n in ui.nodes() if n.get('class')=='android.widget.ScrollView'
                       and n.get('package')==package and (b:=ui.bounds(n))[2]>b[0] and b[3]>b[1]]
                if not panes:break
                left,top,right,bottom=ui.bounds(min(panes,key=lambda n:ui.bounds(n)[3]-ui.bounds(n)[1]))
                injector.send('swipe',**{'from':[[(left+right)/2,top+(bottom-top)*.8]],
                                       'to':[[(left+right)/2,top+(bottom-top)*.2]],'duration':350})
            node=find(error,scroll=True);ui.dump('keyboard-error-'+name)
            viewport=ui.bounds(find('远程桌面。'))
            assert viewport[3]-viewport[1]>=80,'Large keyboard hint covered the remote touch area'
            capture('keyboard-error-'+name)
            close=find('收起键盘',scroll=True,reverse=True)
            desktop.pump();assert len(desktop.keys)==key_count,'Unsupported Chinese composition emitted remote keys'
            cases.append({'name':'200% small-phone keyboard error and close reachable '+name,
                          'error_bounds':ui.bounds(node),'close_bounds':ui.bounds(close),
                          'remote_viewport_bounds':viewport,
                          'ime_bounds':ime_bounds,'ime_bounds_source':'WindowManager visible IME inset (includes navigation inset)',
                          'ime_min_height_dp':160,'field_tapped_after_rotation':True,
                          'input_connection_verified_after_rotation':True,
                          'both_modes_selected_with_ime_visible':True,'remote_keys_emitted':0})
        ui.tap(close)
        android('shell','wm','user-rotation','lock','0')
        until(lambda:ui.find('返回电脑列表（保持连接）') is not None,'Phone header did not return after closing the IME')
    else:tap('收起键盘')
    assert connection()==[first_connection]
    tap('返回电脑列表（保持连接）')
    until(lambda:ui.find('Release OS test') is not None,'Did not return to list')
    assert connection()==[first_connection]
    open_profile('Release OS test');until(lambda:ui.find('远程桌面。') is not None,'Did not return to active session')
    assert connection()==[first_connection]
    cases.append({'name':'return to original TCP session','tcp':first_connection})
    capture('session-returned')
    android('shell','am','force-stop',package);pump_until(lambda:not connection(),'App process stop retained TCP')
    launch();until(lambda:ui.find('Release OS test') is not None,'Saved profile did not survive restart')
    open_profile('Release OS test')
    until(lambda:ui.find('远程桌面。') is not None and len(connection())==1,'Keystore credentials/pin did not reconnect after process restart',60)
    assert ui.find('确认远程电脑的身份') is None and ui.find('连接到 Release OS test') is None
    assert connection()[0]!=first_connection
    cases.append({'name':'Keystore password and pin reused for actual NLA after process restart','tcp':connection()[0]})
    capture('reconnected')
    # A different private peer verifies actual UTF-16 clipboard bytes. X11's
    # shadow server has no CLIPRDR implementation, so it cannot cover this path.
    flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','freerdp-server3','freerdp3','winpr3'],text=True))
    paste_binary=private/'paste_fixture'
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations',
        str(root/'native/tests/paste_fixture.c'),'-o',str(paste_binary),*flags],check=True)
    cert,key=private/'paste.crt',private/'paste.key'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-noenc','-days','1','-subj','/CN=localhost',
        '-keyout',str(key),'-out',str(cert)],capture_output=True,check=True)
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));paste_port=sock.getsockname()[1]
    android('reverse',f'tcp:{paste_port}',f'tcp:{paste_port}');cleanup.callback(android,'reverse','--remove',f'tcp:{paste_port}',check=False)
    def paste_peer(name,mode="normal"):
        log=cleanup.enter_context((out/(name+'.log')).open('w'))
        peer=subprocess.Popen([str(paste_binary),str(paste_port),str(cert),str(key),mode,'300000','120000'],
            env=env,stdout=log,stderr=subprocess.STDOUT);cleanup.callback(stop,peer)
        until(lambda:any(l.split()[1]==f'0100007F:{paste_port:04X}' and l.split()[3]=='0A' for l in Path('/proc/net/tcp').read_text().splitlines()[1:]),'Clipboard peer did not listen')
        return peer,log
    peer,log=paste_peer('paste-certificate-probe')
    tap('返回电脑列表（保持连接）');tap('添加电脑')
    until(lambda:ui.find('电脑地址',True) is not None,'Clipboard profile editor did not open')
    ui.enter('电脑地址',f'127.0.0.1:{paste_port}');ui.enter('显示名称','Chinese IME test');ui.enter('用户名','test')
    find('密码',field=True,scroll=True);ui.enter('密码',secret)
    tap('连接偏好',scroll=True);tap('网络级身份验证（NLA）',scroll=True);tap('保存并连接',scroll=True)
    until(lambda:ui.find('确认远程电脑的身份') is not None,'Clipboard certificate prompt did not open',60)
    # The finite fixture handles one TLS attempt. The deliberately untrusted
    # certificate probe closes that attempt before the user's UI approval.
    stop(peer);peer,log=paste_peer('unicode-confirmed',mode='unicode')
    tap('在此设备记住这个指纹',scroll=True);tap('指纹匹配，继续')
    until(lambda:ui.find('键盘') is not None,'Clipboard session did not connect',60)
    tap('键盘')
    if ui.find('输入模式：键盘模拟') is not None:
        tap('输入模式：键盘模拟');tap('文字输入')
    until(lambda:ui.find('文字输入',field=True) is not None,'Explicit text composer did not open')
    direct_text='LRDP 中文输入验证 你好 😀'
    ime.send('compose','zhong')
    time.sleep(.3)
    assert 'PASS: direct Chinese UTF-16 input complete' not in (out/'unicode-confirmed.log').read_text()
    ime.send('compose',direct_text)
    until(lambda:ui.find(direct_text,field=True) is not None,'Android IME did not put Chinese candidates in the composer')
    capture('chinese-direct-composed');tap('发送文字')
    until(lambda:'PASS: direct Chinese UTF-16 input complete' in (out/'unicode-confirmed.log').read_text(),
          'Chinese Unicode key events did not arrive at the independent TLS peer',20)
    until(lambda:ui.find(direct_text,field=True) is None,'Sent Chinese text was not cleared')
    capture('chinese-direct-sent');android('shell','am','force-stop',package)
    assert peer.wait(timeout=15)==0,'Direct Chinese wire verification failed'
    log.flush();direct_report=next(json.loads(l) for l in (out/'unicode-confirmed.log').read_text().splitlines() if l.startswith('{"mode"'))
    assert direct_report=={'mode':'unicode','passed':True,'unicode_events':len(direct_text.encode('utf-16-le')),
                          'keys':0,'data':0,'publications':0},direct_report
    cases.append({'name':'Explicit Send commits Android Chinese composition as paired Unicode key events without clipboard or Ctrl+V',
                  'text':direct_text,'wire':direct_report,'provisional_pinyin_sent':False})
    peer,log=paste_peer('paste-confirmed')
    launch();open_profile('Chinese IME test')
    until(lambda:ui.find('键盘') is not None or ui.find('连接到 Chinese IME test') is not None,
          'Clipboard reconnect did not show a session or temporary login',30)
    # This secondary profile intentionally does not remember the password.
    # Complete its real login dialog instead of seeding credentials or waiting.
    if ui.find('连接到 Chinese IME test') is not None:
        ui.enter('密码',secret);tap('连接')
    until(lambda:ui.find('键盘') is not None,'Clipboard session did not reconnect',60)
    tap('键盘');until(lambda:ui.find('文字输入',field=True) is not None,'Chinese text composer did not reopen')
    tap('输入模式：文字输入');tap('粘贴输入')
    tap('收起键盘');tap('键盘')
    until(lambda:ui.find('输入模式：粘贴输入') is not None,'Text transfer mode was not preserved after reopening the composer')
    ime.send('compose','zhong')
    time.sleep(.3)
    arrow=ui.find('发送文字');assert arrow is not None and arrow.get('enabled')=='true','Explicit Send must remain available for IME composition'
    ime.send('compose','LRDP 中文输入验证 你好')
    until(lambda:ui.find('LRDP 中文输入验证 你好',field=True) is not None,'Android IME did not put Chinese candidates in the composer')
    capture('chinese-ime-committed');tap('发送文字')
    until(lambda:ui.find('LRDP 中文输入验证 你好',field=True) is None,'Confirmed Chinese text was not cleared',15)
    capture('chinese-ime-sent');android('shell','am','force-stop',package)
    assert peer.wait(timeout=15)==0,'Clipboard wire verification failed'
    log.flush();paste_report=next(json.loads(l) for l in (out/'paste-confirmed.log').read_text().splitlines() if l.startswith('{"mode"'))
    assert paste_report=={'mode':'normal','passed':True,'keys':4,'data':1,'publications':1},paste_report
    cases.append({'name':'Explicit Send commits Android IME Chinese composition to confirmed CLIPRDR UTF-16 and Ctrl+V',
        'text':'LRDP 中文输入验证 你好','wire':paste_report,'provisional_pinyin_sent':False,'input_mode_preserved_after_close':True})
    desktop.pump();save_json('events',desktop.events)
    assert android('shell','id','-u').stdout.strip()=='2000'
    import zipfile
    with zipfile.ZipFile(args.apk) as z:native=z.read('lib/x86_64/liblrdp.so');aot=z.read('lib/x86_64/libapp.so')
    save_json('VERDICT',{'passed':True,'native_abi':5,'apk_sha256':sha(args.apk),'library_sha256':hashlib.sha256(native).hexdigest(),
        'aot_sha256':hashlib.sha256(aot).hexdigest(),'platform':device.platform,'device':device_evidence,'entrypoint':'lib/main.dart Release AOT',
        'debuggable':False,'run_as_denied':True,'root_used':False,'extra_app_permissions':False,'private_state_seeded':False,
        'credentials_via':'OS input helper stdin, random ephemeral secret, actual Keystore and NLA',
        'installed_apk_hash_probe':installed_hash_probe,
        'uiautomator_output':'/proc/self/fd/1' if device.api < 26 else '/dev/stdout',
        'legacy_field_lookups':ui.legacy_field_lookups,
        'system_font_scale':args.font_scale,'previous_system_font_scale':font_before,
        'small_phone':args.small_phone,'ime_control_verified':args.verify_ime_control,
        'session_ui_verified':args.verify_session_ui,
        'system_fullscreen_hint_dismissals':ui.fullscreen_hint_dismissals,
        'keyboard_simulation_input_box_visible':False,'display_before':display_before,
        'rotation_before':rotation_before,'rotation_mode_before':rotation_mode_before,
        'native_surface_presented':True,'native_presentations':native_presentations,
        'bounds':bounds,'cases':cases,'physical_device':False})
    print('PASS: actual main Release, OS UI/profile/certificate, NLA/Keystore restart, touch taps/drag/right/scroll and session reuse',flush=True)
