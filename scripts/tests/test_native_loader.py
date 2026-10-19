"""Verify that a second bridge image cannot call into the first image's state."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT/'build/native/liblrdp.so'
PROBE = r'''
import ctypes as c,resource,shutil,sys,tempfile
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
with tempfile.TemporaryDirectory(prefix='lrdp-loader-') as d:
    first,second=Path(d)/'first.so',Path(d)/'second.so'
    shutil.copyfile(sys.argv[1],first);shutil.copyfile(sys.argv[1],second)
    # The first image has not initialized its frame registry. A public call
    # accidentally interposed from the second image would access that registry.
    a=c.CDLL(str(first),mode=c.RTLD_GLOBAL)
    b=c.CDLL(str(second))
    b.lrdp_create.restype=c.c_void_p
    b.lrdp_destroy.argtypes=[c.c_void_p]
    b.lrdp_video_ticket.argtypes=[c.c_void_p];b.lrdp_video_ticket.restype=c.c_uint64
    b.lrdp_video_open.argtypes=[c.c_uint64];b.lrdp_video_open.restype=c.c_void_p
    b.lrdp_video_close.argtypes=[c.c_void_p]
    for _ in range(20):
        session=b.lrdp_create();assert session
        ticket=b.lrdp_video_ticket(session);assert ticket
        reader=b.lrdp_video_open(ticket);assert reader
        b.lrdp_destroy(session)
        assert not b.lrdp_video_open(ticket)
        b.lrdp_video_close(reader)
print('PASS: separate bridge images keep independent frame registries')
'''


@unittest.skipUnless(sys.platform.startswith('linux') and LIBRARY.is_file(), 'Requires the native Linux build')
class NativeLoaderTests(unittest.TestCase):
    def test_public_calls_bind_to_their_own_registry(self):
        result = subprocess.run([sys.executable, '-c', PROBE, str(LIBRARY)],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, (result.stdout+result.stderr)[-3000:])
        self.assertIn('PASS:', result.stdout)


if __name__ == '__main__':
    unittest.main()
