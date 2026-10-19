import importlib.util
from pathlib import Path
import unittest
import io
import zipfile

spec = importlib.util.spec_from_file_location('apk', Path(__file__).parents[1] / 'check_android_apk.py')
apk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apk)


def segment(kind, start, end, flags=6):
    return {'type': kind, 'start': start, 'end': end, 'flags': flags, 'offset': start, 'align': 16384}


class RelroTests(unittest.TestCase):
    def test_shared_load_writable_bytes_cannot_be_protected(self):
        with self.assertRaisesRegex(ValueError, 'overlaps writable'):
            apk.verify_segments([segment(1, 0x4000, 0x8000), segment(0x6474e552, 0x4000, 0x5000, 4)])

    def test_relro_only_load_and_separate_writable_page_are_safe(self):
        apk.verify_segments([segment(1, 0x4680, 0x5000), segment(0x6474e552, 0x4680, 0x5000, 4),
                             segment(1, 0x8000, 0x9000)])

    def test_shared_load_with_aligned_boundary_is_safe(self):
        apk.verify_segments([segment(1, 0x4000, 0x9000), segment(0x6474e552, 0x4000, 0x8000, 4)])

    def test_lld_relro_padding_past_the_load_end_is_safe(self):
        apk.verify_segments([segment(1, 0x51c0, 0x5428), segment(0x6474e552, 0x51c0, 0x6000, 4),
                             segment(1, 0x9428, 0x9429)])

    def test_load_alignment_is_checked_independently(self):
        load = segment(1, 0x4000, 0x8000)
        load['align'] = 4096
        with self.assertRaisesRegex(ValueError, 'not page aligned'):
            apk.verify_segments([load])


class EntrypointTests(unittest.TestCase):
    def archive(self, entries):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            for name, value in entries.items(): archive.writestr(name, value)
        return zipfile.ZipFile(data)

    def test_release_rejects_debug_kernel(self):
        with self.archive({'assets/flutter_assets/kernel_blob.bin': b'package:lrdp/main.dart'}) as archive:
            with self.assertRaisesRegex(ValueError, 'debug kernel'):
                apk.verify_entrypoint(archive, ['arm64-v8a'], release=True)

    def test_release_rejects_integration_aot_even_with_main_import(self):
        with self.archive({'lib/arm64-v8a/libapp.so': b'package:lrdp/main.dart\0integration_test/connection_test.dart'}) as archive:
            with self.assertRaisesRegex(ValueError, 'production entrypoint'):
                apk.verify_entrypoint(archive, ['arm64-v8a'], release=True)

    def test_every_aot_abi_must_identify_main(self):
        with self.archive({'lib/arm64-v8a/libapp.so': b'package:lrdp/main.dart',
                           'lib/x86_64/libapp.so': b'unrelated entrypoint'}) as archive:
            with self.assertRaisesRegex(ValueError, 'production entrypoint'):
                apk.verify_entrypoint(archive, ['arm64-v8a', 'x86_64'], release=True)


if __name__ == '__main__':
    unittest.main()
