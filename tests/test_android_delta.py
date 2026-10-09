import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
import zlib

MODULE = Path(__file__).resolve().parents[1] / 'scripts/build_android_delta.py'


class AndroidDeltaTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('android_delta', MODULE)
        self.delta = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.delta)
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / 'docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/delta')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base, self.target, self.patch, self.output = [self.root / n for n in ['base.apk', 'target.apk', 'update.delta', 'output.apk']]
        for path, changed in [(self.base, b'old'), (self.target, b'new')]:
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as apk:
                apk.writestr('unchanged', bytes(range(256)) * 4096)
                apk.writestr('changed', changed)

    def test_exact_streaming_reconstruction(self):
        info = self.delta.build_delta(self.base, self.target, self.patch)
        self.delta.apply_delta(self.base, self.patch, self.output)
        self.assertEqual(self.target.read_bytes(), self.output.read_bytes())
        self.assertGreater(info['copied_bytes'], 1000)
        self.assertLessEqual(self.delta.BUFFER_SIZE, 65536)

    def test_wrong_base_and_truncation_never_publish_output(self):
        self.delta.build_delta(self.base, self.target, self.patch)
        original = self.base.read_bytes()
        self.base.write_bytes(b'bad')
        with self.assertRaises(ValueError):
            self.delta.apply_delta(self.base, self.patch, self.output)
        self.assertFalse(self.output.exists())
        self.base.write_bytes(original)
        self.patch.write_bytes(self.patch.read_bytes()[:-3])
        with self.assertRaises((ValueError, EOFError)):
            self.delta.apply_delta(self.base, self.patch, self.output)
        self.assertFalse(self.output.exists())

    def test_copy_overflow_output_limit_unknown_op_and_trailing_data(self):
        self.delta.build_delta(self.base, self.target, self.patch)
        header = self.patch.read_bytes()[:self.delta.HEADER.size]
        cases = [b'\x00' + struct.pack('>QQ', 2**64 - 1, 8), b'\x01' + struct.pack('>Q', 2**64 - 1), b'\x09']
        for command in cases:
            self.patch.write_bytes(header + zlib.compress(command))
            with self.assertRaises((ValueError, EOFError)):
                self.delta.apply_delta(self.base, self.patch, self.output)
            self.assertFalse(self.output.exists())
        self.delta.build_delta(self.base, self.target, self.patch)
        self.patch.write_bytes(self.patch.read_bytes() + b'extra')
        with self.assertRaises(ValueError):
            self.delta.apply_delta(self.base, self.patch, self.output)

    def test_corrupt_literal_target_hash_and_operation_count(self):
        self.delta.build_delta(self.base, self.target, self.patch)
        raw = self.patch.read_bytes()
        header = list(self.delta.HEADER.unpack(raw[:self.delta.HEADER.size]))
        header[4] = b'\x00' * 32
        self.patch.write_bytes(self.delta.HEADER.pack(*header) + raw[self.delta.HEADER.size:])
        with self.assertRaises(ValueError):
            self.delta.apply_delta(self.base, self.patch, self.output)
        header[5] = 100001
        self.patch.write_bytes(self.delta.HEADER.pack(*header) + raw[self.delta.HEADER.size:])
        with self.assertRaises(ValueError):
            self.delta.apply_delta(self.base, self.patch, self.output)


if __name__ == '__main__':
    unittest.main()
