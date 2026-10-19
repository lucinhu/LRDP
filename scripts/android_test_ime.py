"""Test IME exclusively for allowlisted owned AVDs; never part of the client APK."""
from pathlib import Path
import os
import shlex
import subprocess
import time
import zipfile
from android_test_device import DEVICES


class TestIme:
    package = 'dev.lrdp.fixture.ime'
    component = package+'/.FixtureIme'

    def __init__(self, sdk, adb, output, *, device='api36'):
        self.adb = adb
        DEVICES[device].verify(self.run)
        self.previous = self.run('shell', 'settings', 'get', 'secure', 'default_input_method').stdout.strip()
        self.enabled = self.run('shell', 'settings', 'get', 'secure', 'enabled_input_methods').stdout.strip()
        self.hard = self.run('shell', 'settings', 'get', 'secure', 'show_ime_with_hard_keyboard').stdout.strip()
        root = Path(__file__).resolve().parent.parent
        source = root/'native/tests/android_ime'
        folder = output/'ime-fixture';folder.mkdir(parents=True, exist_ok=True)
        classes = folder/'classes';classes.mkdir(exist_ok=True)
        dex = folder/'dex';dex.mkdir(exist_ok=True)
        kit = sdk/'build-tools/36.0.0';platform = sdk/'platforms/android-36/android.jar'
        env = dict(os.environ, JAVA_HOME='/usr/lib/jvm/java-17-openjdk', LRDP_FIXTURE_KEYSTORE_PASSWORD='android')
        with (folder/'build.log').open('w') as log:
            def command(parts): subprocess.run(list(map(str, parts)), env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            command([Path(env['JAVA_HOME'])/'bin/javac', '--release', '8', '-cp', platform, '-d', classes, source/'FixtureIme.java'])
            command([kit/'d8', '--min-api', '24', '--lib', platform, '--output', dex, *classes.rglob('*.class')])
            command([kit/'aapt2', 'compile', '--dir', source/'res', '-o', folder/'resources.zip'])
            command([kit/'aapt2', 'link', '-I', platform, '--manifest', source/'AndroidManifest.xml',
                '-o', folder/'raw.apk', folder/'resources.zip'])
            with zipfile.ZipFile(folder/'raw.apk', 'a') as archive: archive.write(dex/'classes.dex', 'classes.dex')
            command([kit/'zipalign', '-f', '4', folder/'raw.apk', folder/'aligned.apk'])
            command([kit/'apksigner', 'sign', '--ks', Path.home()/'.android/debug.keystore',
                '--ks-pass', 'env:LRDP_FIXTURE_KEYSTORE_PASSWORD', '--key-pass', 'env:LRDP_FIXTURE_KEYSTORE_PASSWORD',
                '--out', folder/'ime.apk', folder/'aligned.apk'])
        self.run('install', '-r', str(folder/'ime.apk'))
        try:
            # Incremental installation can return before the IME service has
            # processed its package broadcast. Wait for actual registration.
            deadline = time.monotonic() + 15
            while self.component not in self.run('shell', 'ime', 'list', '-a', '-s').stdout.splitlines():
                if time.monotonic() >= deadline:
                    raise RuntimeError('Installed test IME was not registered by Android')
                time.sleep(.1)
            self.run('shell', 'ime', 'enable', self.component)
            self.run('shell', 'ime', 'set', self.component)
            self.run('shell', 'settings', 'put', 'secure', 'show_ime_with_hard_keyboard', '1')
        except BaseException:
            self.close(); raise

    def run(self, *parts, check=True):
        command = ['shell', shlex.join(parts[1:])] if parts[0] == 'shell' else list(parts)
        return subprocess.run(self.adb+command, capture_output=True, text=True, check=check, timeout=30)

    def send(self, operation, text=''):
        result = self.run('shell', 'am', 'broadcast', '--receiver-foreground', '-a', 'dev.lrdp.fixture.IME',
            '--es', 'operation', operation, '--es', 'text', text)
        assert 'result=1' in result.stdout, 'Test IME has no active input connection: '+result.stdout

    def close(self):
        if self.previous and self.previous != 'null': self.run('shell', 'ime', 'set', self.previous, check=False)
        self.run('uninstall', self.package, check=False)
        for name, value in [('enabled_input_methods', self.enabled), ('show_ime_with_hard_keyboard', self.hard)]:
            self.run('shell', 'settings', 'delete' if value == 'null' else 'put', 'secure', name,
                *([] if value == 'null' else [value]), check=False)
