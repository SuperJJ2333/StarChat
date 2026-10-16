"""Only synthetic filesystem/transport doubles; permanent files are never touched."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import test_execution_gate
from test_release_contract import release

HERE = Path(__file__).resolve().parent


class PermanentGuardBoundaries(unittest.TestCase):
    def test_preflight_rejects_live_settings_dependency_drift_or_absence(self):
        execute = test_execution_gate.executor()
        scratch = HERE/'test-scratch'; scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as name:
            root = Path(name); runtime = root/'runtime'; runtime.mkdir()
            before = release.read_json(HERE/'baseline/hk-live-snapshot.json')
            static = release.read_json(HERE/'baseline/static-baseline.json')
            for filename, value in [('hk-live-snapshot.json', before), ('static-baseline.json', static)]:
                (runtime/filename).write_text(json.dumps(value), encoding='utf-8')
            current = copy.deepcopy(before); current['files'] = static['files']
            execute.compare_baseline('hk', current, root)
            for key in before['settings_dependencies']:
                wrong = copy.deepcopy(current); wrong['settings_dependencies'][key] = '0'*64
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'settings_dependencies'):
                    execute.compare_baseline('hk', wrong, root)
            wrong = copy.deepcopy(current); del wrong['settings_dependencies']
            with self.assertRaisesRegex(ValueError, 'settings_dependencies'):
                execute.compare_baseline('hk', wrong, root)

    def test_preflight_requires_exact_guard_and_probe_hashes(self):
        execute = test_execution_gate.executor()
        with tempfile.TemporaryDirectory(dir=HERE/'test-scratch') as name:
            root = Path(name); runtime = root/'runtime'; runtime.mkdir()
            before = release.read_json(HERE/'baseline/hk-live-snapshot.json')
            static = release.read_json(HERE/'baseline/static-baseline.json')
            for filename, value in [('hk-live-snapshot.json', before), ('static-baseline.json', static)]:
                (runtime/filename).write_text(json.dumps(value), encoding='utf-8')
            current = copy.deepcopy(before); current['files'] = static['files']
            execute.compare_baseline('hk', current, root)
            for key in before['permanent_guards']:
                wrong = copy.deepcopy(current); wrong['permanent_guards'][key] = '0'*64
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'permanent_guards'):
                    execute.compare_baseline('hk', wrong, root)
            wrong = copy.deepcopy(current); del wrong['permanent_guards']
            with self.assertRaisesRegex(ValueError, 'permanent_guards'):
                execute.compare_baseline('hk', wrong, root)

    def test_before_public_write_rechecks_guards_and_fails_closed_on_read_failure(self):
        frozen = copy.deepcopy(release.FROZEN_HOST)
        frozen['aliases'] = {}; frozen['runtime'] = []
        def expected(path):return frozen['permanent_guards'][Path(path).name]
        with patch.object(release, 'FROZEN_HOST', frozen), patch.object(release.subprocess, 'check_output', side_effect=lambda args, **kw: '' if args[1]=='ps' else '[]'):
            with patch.object(release, 'digest', side_effect=expected):
                release.host_preservation(Path('synthetic-frontend'))
            for bad in ('0'*64, PermissionError('synthetic guard permission denied')):
                if isinstance(bad, Exception): options={'side_effect':bad}; expected_error=PermissionError
                else: options={'return_value':bad}; expected_error=ValueError
                with self.subTest(bad=type(bad).__name__), patch.object(release, 'digest', **options), self.assertRaises(expected_error):
                    release.host_preservation(Path('synthetic-frontend'))


if __name__ == '__main__': unittest.main()
