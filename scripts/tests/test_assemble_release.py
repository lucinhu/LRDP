from pathlib import Path
import hashlib
import importlib.util
import tempfile
import unittest
import zipfile

root = Path(__file__).resolve().parents[2]


def load_module():
    spec = importlib.util.spec_from_file_location(
        'assemble_release', root/'scripts/assemble_release.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AssembleReleaseTest(unittest.TestCase):
    def test_sha256_file_matches_hashlib(self):
        assemble = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary)/'artifact.bin'
            payload.write_bytes(b'lrdp')
            self.assertEqual(assemble.sha256_file(payload),
                             hashlib.sha256(b'lrdp').hexdigest())

    def test_verification_zip_embeds_logs_and_metadata(self):
        # The release job writes SHA256SUMS before zipping because the archive
        # contains a copy of it; a missing checksum file used to fail the run.
        assemble = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            dist, logs = base/'dist', base/'logs'
            dist.mkdir()
            logs.mkdir()
            (logs/'analyze.log').write_text('0 issues\n')
            bundle = dist/'BUILD_INFO.json'
            bundle.write_text('{}\n')
            checksums = dist/'SHA256SUMS'
            checksums.write_text(f'{assemble.sha256_file(bundle)}  BUILD_INFO.json\n')
            archive = dist/'lrdp-0.3.0-verification.zip'
            assemble.build_verification_zip(archive, logs, dist, [bundle], checksums)
            with zipfile.ZipFile(archive) as opened:
                names = set(opened.namelist())
            self.assertEqual(names, {'logs/analyze.log', 'metadata/BUILD_INFO.json',
                                     'metadata/SHA256SUMS', 'README.txt'})


if __name__ == '__main__':
    unittest.main()
