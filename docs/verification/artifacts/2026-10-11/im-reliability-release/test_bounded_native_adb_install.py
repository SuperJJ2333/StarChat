"""Host-only safety checks; no real ADB process is started."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('bounded_install', HERE / 'bounded_native_adb_install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class BoundedInstallTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(dir=HERE)
        self.addCleanup(self.folder.cleanup)
        self.apk = Path(self.folder.name) / 'final.apk'
        self.apk.write_bytes(b'synthetic fixture; never installed')
        self.argv = patch.object(installer.sys, 'argv', ['installer', str(self.apk)])
        self.argv.start()
        self.addCleanup(self.argv.stop)

    @staticmethod
    def result(stdout='', code=0):
        return subprocess.CompletedProcess([], code, stdout, '')

    def test_existing_or_retained_package_cannot_be_replaced(self):
        with patch.object(installer.subprocess, 'run', side_effect=[self.result('device\n'), self.result('package:' + installer.PACKAGE + '\n')]) as run:
            with self.assertRaisesRegex(RuntimeError, 'refuse replacement'):
                installer.main()
        self.assertEqual(len(run.call_args_list), 2)
        self.assertFalse(any('install' in c.args[0] for c in run.call_args_list))

    def test_success_uses_only_owned_device_and_bounded_non_streaming(self):
        with patch.object(installer.subprocess, 'run', side_effect=[self.result('device\n'), self.result(), self.result('Success\n')]) as run:
            self.assertEqual(installer.main(), 0)
        for call in run.call_args_list:
            self.assertEqual(call.args[0][1:3], ['-s', 'emulator-5558'])
        install = run.call_args_list[-1]
        self.assertEqual(install.args[0][3:5], ['install', '--no-streaming'])
        self.assertEqual(install.kwargs['timeout'], 180)

    def test_install_timeout_propagates_without_assuming_rollback(self):
        with patch.object(installer.subprocess, 'run', side_effect=[self.result('device\n'), self.result(), subprocess.TimeoutExpired('owned-adb', 180)]) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                installer.main()
        self.assertEqual(len(run.call_args_list), 3)
        self.assertFalse(any('uninstall' in c.args[0] for c in run.call_args_list))

    def test_offline_device_never_queries_or_installs_package(self):
        with patch.object(installer.subprocess, 'run', return_value=self.result('offline\n')) as run:
            with self.assertRaisesRegex(RuntimeError, 'unavailable'):
                installer.main()
        self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()
