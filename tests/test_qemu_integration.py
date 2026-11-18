"""Real file-only acquisition -> QEMU conversion tests; no OS disk or VM access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECOVERY = ROOT / 'storage-recovery'


@unittest.skipUnless(os.environ.get('QEMU_IMG_TEST_EXE'), 'real qemu-img path not configured')
class QemuPipelineTests(unittest.TestCase):
    def pipeline(self, size):
        with tempfile.TemporaryDirectory(prefix='edgebox-qemu-e2e-') as directory:
            folder = Path(directory)
            source = folder / 'synthetic.bin'
            # Different data at each end and each 4 MiB boundary catches offsets,
            # partial final chunks, and zero-block conversion errors.
            data = bytearray(size)
            for offset in range(0, size, 4 * 1024 * 1024):
                marker = hashlib.sha256(str(offset).encode()).digest()
                data[offset:offset+len(marker)] = marker[:size-offset]
            data[-512:] = bytes(range(256)) * 2
            source.write_bytes(data)
            def command(*args):
                result = subprocess.run([sys.executable, '-B', *map(str, args)],
                    capture_output=True, text=True, encoding='utf-8', timeout=90)
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads(result.stdout)
            manifest = command(RECOVERY / 'offline_image.py', 'fixture-copy',
                '--source', source, '--destination', folder, '--name', 'sample')
            self.assertEqual(manifest['Sha256'], hashlib.sha256(data).hexdigest())
            converted = command(RECOVERY / 'convert_image.py', '--raw', folder/'sample.raw',
                '--output', folder/'sample.vhdx', '--qemu-img', os.environ['QEMU_IMG_TEST_EXE'],
                '--allow-fixture', '--timeout', '60')
            self.assertEqual(converted['VirtualSize'], size)
            self.assertEqual(converted['SourceSha256'], manifest['Sha256'])
            self.assertTrue(all(converted['Verification'].values()))
            self.assertFalse(converted['BootTested'])
            # Independently export the generated VHDX with QEMU and hash the RAW.
            exported = folder/'exported.raw'
            result = subprocess.run([os.environ['QEMU_IMG_TEST_EXE'], 'convert', '-f', 'vhdx',
                '-O', 'raw', str(folder/'sample.vhdx'), str(exported)], capture_output=True,
                text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(exported.stat().st_size, size)
            self.assertEqual(hashlib.sha256(exported.read_bytes()).hexdigest(), manifest['Sha256'])

    def test_unaligned_megabyte_size(self):
        self.pipeline(1024 * 1024 + 512)

    def test_multiple_copy_chunks(self):
        self.pipeline(17 * 1024 * 1024)


if __name__ == '__main__':
    unittest.main()
