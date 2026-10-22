from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


class AppImageLauncherTest(unittest.TestCase):
    def check_launcher(self, symlink):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(prefix='lrdp launcher ') as temporary:
            folder = Path(temporary)/'application folder'
            folder.mkdir()
            launcher = folder/'AppRun'
            shutil.copyfile(root/'scripts/appimage/apprun.sh', launcher)
            launcher.chmod(0o755)
            gtk = folder/'AppRun.gtk'
            gtk.write_text(f'#!{sys.executable}\n'
                'import json, os, sys\n'
                'print(json.dumps({"appdir":os.environ["APPDIR"],'
                '"modules":os.environ["OPENSSL_MODULES"],'
                '"home":os.environ.get("HOME"),"args":sys.argv[1:]}))\n')
            gtk.chmod(0o755)
            command = launcher
            if symlink:
                command = Path(temporary)/'launcher link'
                command.symlink_to(launcher)
            args = ['value with spaces', '--literal=$(printf not-executed)']
            result = subprocess.check_output([command, *args], text=True,
                env=dict(os.environ, APPDIR='/stale/appdir', OPENSSL_MODULES='/wrong/provider'))
            value = json.loads(result)
            self.assertEqual(value['appdir'], str(folder))
            self.assertEqual(value['modules'], str(folder/'usr/lib/ossl-modules'))
            self.assertEqual(value['args'], args)
            self.assertEqual(value['home'], os.environ.get('HOME'))

    def test_spaces_and_argument_forwarding(self):
        self.check_launcher(False)

    def test_symlink_uses_the_actual_application_directory(self):
        self.check_launcher(True)
