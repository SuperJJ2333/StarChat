"""Packaging refuses incomplete final-artifact and source gate identities."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def module():
    path = HERE / 'package_release.py'
    assert path.is_file(), '2214 final-artifact package gate is not implemented'
    spec = importlib.util.spec_from_file_location('package_release', path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class PackageGate(unittest.TestCase):
    def setUp(self):
        base = HERE / 'test-scratch'; base.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / 'final.apk'; self.apk.write_bytes(b'synthetic already-verified APK')
        self.artifact = dict(version='0.4.45', build=2214, mode='standard-arm64-release',
                             source_commit='b' * 40, mobile_manifest_sha256='c' * 64,
                             pubspec_lock_sha256='d' * 64,
                             signer_sha256='75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff',
                             final_apk_bytes=self.apk.stat().st_size,
                             final_apk_sha256=hashlib.sha256(self.apk.read_bytes()).hexdigest())
        self.steps = self.root / 'steps.tsv'
        self.steps.write_text('step\texit_code\nsource-build\t0\napk-rebuild\t0\nsignature-gate\t0\n')
        evidence = self.root / 'evidence.log'; evidence.write_bytes(b'synthetic successful gate')
        self.gates = dict(source_commit='b' * 40, source_manifest_sha256='c' * 64,
                          artifact_sha256=self.artifact['final_apk_sha256'], checks={
                              key: dict(status='pass', path='evidence.log', sha256=hashlib.sha256(evidence.read_bytes()).hexdigest())
                              for key in ('shared_flutter', 'native_android', 'final_apk')})
        self.gate_path = self.root / 'gates.json'

    def validate(self):
        self.gate_path.write_text(json.dumps(self.gates), encoding='utf-8')
        return module().validate_build(self.apk, self.artifact, self.steps, self.gate_path)

    def test_exact_candidate_and_three_hashed_gates_required(self):
        record = self.validate()
        self.assertEqual(record['artifact_sha256'], self.artifact['final_apk_sha256'])
        self.assertEqual(record['build'], 2214)
        for missing in ('shared_flutter', 'native_android', 'final_apk'):
            previous = self.gates['checks'].pop(missing)
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                self.validate()
            self.gates['checks'][missing] = previous

    def test_missing_artifact_identity_signer_drift_or_failed_step_is_refused(self):
        module()
        for key, bad in [('final_apk_sha256', None), ('final_apk_bytes', 0),
                         ('signer_sha256', 'e' * 64), ('build', 2213), ('source_commit', '0' * 40)]:
            before = self.artifact[key]; self.artifact[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate()
            self.artifact[key] = before
        self.steps.write_text('step\texit_code\nsource-build\t1\n')
        with self.assertRaises(ValueError): self.validate()

    def test_gate_unknown_status_wrong_source_or_evidence_drift_is_refused(self):
        module()
        self.gates['checks']['native_android']['status'] = 'pending'
        with self.assertRaises(ValueError): self.validate()
        self.gates['checks']['native_android']['status'] = 'pass'
        self.gates['source_manifest_sha256'] = 'e' * 64
        with self.assertRaises(ValueError): self.validate()
        self.gates['source_manifest_sha256'] = 'c' * 64
        (self.root / 'evidence.log').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.validate()


if __name__ == '__main__':
    unittest.main()
