import ctypes
import importlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sample = importlib.import_module('collect_im_runtime_sample')
TEMP = ROOT / 'docs/verification/artifacts/2026-10-11/im-runtime-bounds/tmp'
TEMP.mkdir(parents=True, exist_ok=True)


class IndependentRuntimeBoundaries(unittest.TestCase):
    def inherited_pipe(self, output, parent_wait, cap, expected_error):
        with tempfile.TemporaryDirectory(dir=TEMP) as folder:
            marker = Path(folder) / 'finished'
            descendant = f"import pathlib,time;time.sleep(1.2);pathlib.Path({str(marker)!r}).write_text('done')"
            child = (
                'import subprocess,sys,time;'
                f'subprocess.Popen([sys.executable,"-c",{descendant!r}],stdout=sys.stdout,stderr=sys.stderr);'
                f'print({output!r},flush=True);time.sleep({parent_wait})'
            )
            started = time.monotonic()
            result = sample.run_bounded([sys.executable, '-c', child], max_bytes=cap, timeout=.4)
            elapsed = time.monotonic() - started
            deadline = started + 4
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(marker.exists(), 'only the direct child may be terminated')
            self.assertLess(elapsed, 1.1, elapsed)
            self.assertEqual(result.error, expected_error)
            self.assertIsInstance(result.data, bytes)
            return result

    def test_parent_exit_does_not_wait_for_inherited_writer(self):
        result = self.inherited_pipe('ready', 0, 64, 'timeout')
        self.assertEqual(result.data.strip(), b'ready')
        self.assertFalse(result.byte_limit_reached)

    def test_byte_cap_does_not_wait_for_inherited_writer(self):
        result = self.inherited_pipe('X' * 10000, 10, 64, None)
        self.assertEqual(result.data, b'X' * 64)
        self.assertTrue(result.byte_limit_reached)

    def test_eof_before_owned_child_exit_still_obeys_deadline(self):
        started = time.monotonic()
        result = sample.run_bounded(
            [sys.executable, '-c', 'import os,time;os.close(1);os.close(2);time.sleep(10)'],
            max_bytes=64, timeout=.2)
        self.assertLess(time.monotonic() - started, 1.1)
        self.assertEqual(result.error, 'timeout')
        self.assertEqual(result.data, b'')

    def test_read_error_is_fixed_enum_and_owned_child_is_reaped(self):
        started = time.monotonic()
        with mock.patch.object(sample, '_NonBlockingPipe', side_effect=OSError('RAW_SECRET_URL')):
            result = sample.run_bounded([sys.executable, '-c', 'import time;time.sleep(10)'], max_bytes=64, timeout=.2)
        self.assertLess(time.monotonic() - started, 1.1)
        self.assertEqual(result.error, 'read_failed')
        self.assertNotIn('RAW_SECRET_URL', repr(result))

    def test_cleanup_timeout_is_explicit_missing_data_not_zero_success(self):
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired('RAW_SECRET_URL', 2)
        with mock.patch.object(sample.subprocess, 'Popen', return_value=process), mock.patch.object(sample, '_NonBlockingPipe'):
            result = sample.run_bounded(['owned-test-only'], max_bytes=64, timeout=0)
        process.kill.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=2)
        process.stdout.close.assert_called_once_with()
        self.assertEqual(result.error, 'cleanup_timeout')
        self.assertEqual(result.data, b'')
        self.assertNotIn('RAW_SECRET_URL', repr(result))
        output = sample.collect_sample(runner=lambda *args, **kwargs: result)
        self.assertTrue(all(row['logs'] == {'error': 'cleanup_timeout', 'summary': None} for row in output['services']))

    @unittest.skipUnless(os.name == 'nt', 'Windows ABI assertion')
    def test_windows_peek_uses_pointer_width_handle_and_win32_bool(self):
        from ctypes import wintypes
        process = subprocess.Popen([sys.executable, '-c', 'pass'], stdout=subprocess.PIPE, bufsize=0)
        try:
            reader = sample._NonBlockingPipe(process.stdout)
            self.assertIs(reader.peek.argtypes[0], wintypes.HANDLE)
            self.assertEqual(ctypes.sizeof(reader.peek.argtypes[0]), ctypes.sizeof(ctypes.c_void_p))
            self.assertEqual(ctypes.sizeof(ctypes.c_void_p), 8)
            self.assertEqual(wintypes.HANDLE(0x100000001).value, 0x100000001)
            self.assertIs(reader.peek.restype, wintypes.BOOL)
        finally:
            process.wait(timeout=2)
            process.stdout.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)