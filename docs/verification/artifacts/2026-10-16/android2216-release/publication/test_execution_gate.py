"""Synthetic files and transport doubles only; never opens SSH or AWS."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
import test_package_gate as package_tests

HERE = Path(__file__).resolve().parent


def executor():
    path = HERE/'execute_release.py'
    if not path.is_file(): raise AssertionError('bounded execution gate is not implemented')
    spec = importlib.util.spec_from_file_location('execute_release_test', path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


class ExecutionGate(unittest.TestCase):
    def setUp(self):
        package_tests.PackageGate.setUp(self)
        self.pkg = package_tests.module()
        self.source = self.root/'source'
        mobile = self.source/'apps/mobile_flutter'; mobile.mkdir(parents=True)
        (mobile/'pubspec.yaml').write_text('version: 0.4.47+2216\n', encoding='utf-8')
        (mobile/'pubspec.lock').write_text('synthetic lock\n', encoding='utf-8')
        self.manifest = self.root/'mobile-inputs.json'
        self.pkg.write_json(self.manifest, {'files':[{'path':p.relative_to(self.source).as_posix(),
            'sha256':self.pkg.digest(p)} for p in sorted(mobile.iterdir())]})
        self.artifact['mobile_manifest_sha256'] = self.pkg.digest(self.manifest)
        self.artifact['pubspec_lock_sha256'] = self.pkg.digest(mobile/'pubspec.lock')
        self.gates['source_manifest_sha256'] = self.artifact['mobile_manifest_sha256']
        self.gates['pubspec_lock_sha256'] = self.artifact['pubspec_lock_sha256']
        self.receipt = self.root/'artifact.json'; self.pkg.write_json(self.receipt, self.artifact)
        self.pkg.write_json(self.gate_path, self.gates)
        self.output = self.root/'package'
        self.args = SimpleNamespace(apk=self.apk, artifact=self.receipt, steps=self.steps,
            gates=self.gate_path, source_root=self.source, source_manifest=self.manifest,
            output=self.output, signing_confirmed_by='synthetic test fixture; not real APK proof')

    def prepare(self):
        self.pkg.create_package(self.args)
        self.freeze = self.pkg.read_json(self.output/'freeze-manifest.json')
        report = self.root/'review.md'; report.write_text('synthetic test review', encoding='utf-8')
        self.review = self.root/'review.json'
        self.pkg.write_json(self.review, {'freeze_sha256':self.pkg.digest(self.output/'freeze-manifest.json'),
            'source_commit':self.freeze['source_commit'], 'artifact_sha256':self.freeze['artifact_sha256'],
            'runtime_sha256':self.freeze['runtime_sha256'], 'operation_id':'test-20261012-123456',
            'checks':{k:{'status':'pass','path':'review.md','sha256':self.pkg.digest(report)}
                      for k in ('spec_domain','quality_security')},
            'authorized_operations':list(executor().OPERATIONS)})

    def test_package_exact_two_file_backfill_and_all_hashes(self):
        self.prepare()
        result = executor().validate_package(self.output)
        self.assertEqual(result['artifact_sha256'], self.artifact['final_apk_sha256'])
        backfill = self.pkg.read_json(self.output/'source-backfill/plan.json')
        self.assertEqual(set(backfill['files']), {'frontend/download.html','frontend/downloads/android-release.json'})
        self.assertEqual(len(backfill['preserved']), 5)
        before = self.pkg.read_json(self.output/'runtime/bucket-policy-before.json')
        after = self.pkg.read_json(self.output/'runtime/prepared-2216/bucket-policy-target.json')
        self.assertEqual(before, after)
        self.assertEqual((self.output/'runtime/bucket-policy-before.json').read_bytes(),
                         (self.output/'runtime/prepared-2216/bucket-policy-target.json').read_bytes())

    def test_missing_identity_or_source_drift_has_no_output(self):
        self.artifact.pop('final_apk_sha256'); self.pkg.write_json(self.receipt, self.artifact)
        with self.assertRaises(ValueError): self.pkg.create_package(self.args)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob('.2216-package-*')), [])

    def test_source_drift_refused_before_output(self):
        (self.source/'apps/mobile_flutter/pubspec.lock').write_text('drift', encoding='utf-8')
        with self.assertRaises(ValueError): self.pkg.create_package(self.args)
        self.assertFalse(self.output.exists())

    def test_default_plan_never_calls_transport_or_creates_execution(self):
        self.prepare(); calls=[]
        result=executor().run(self.output, 'runtime', 'test-20261012-123456', runner=calls.append)
        self.assertEqual(result['status'], 'PLAN_ONLY')
        self.assertEqual(calls, [])
        self.assertFalse((self.output/'execution').exists())

    def test_missing_review_bad_identity_and_changed_package_never_call_transport(self):
        self.prepare(); calls=[]; execute=executor()
        with self.assertRaises(ValueError):
            execute.run(self.output, 'runtime', 'test-20261012-123456', execute=True, runner=calls.append)
        review=self.pkg.read_json(self.review); review['artifact_sha256']='f'*64; self.pkg.write_json(self.review,review)
        with self.assertRaises(ValueError):
            execute.run(self.output,'runtime','test-20261012-123456',execute=True,review_path=self.review,runner=calls.append)
        (self.output/'runtime/settings_2216.py').write_text('drift',encoding='utf-8')
        with self.assertRaises(ValueError):
            execute.run(self.output,'runtime','test-20261012-123456',execute=True,review_path=self.review,runner=calls.append)
        self.assertEqual(calls,[]); self.assertFalse((self.output/'execution').exists())

    def test_out_of_order_mutation_refused_without_transport(self):
        self.prepare(); calls=[]
        for mode in ('upload','assemble','hk-install','cdn-install','hk-switch','publish'):
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                executor().run(self.output,mode,'test-20261012-123456',execute=True,review_path=self.review,runner=calls.append)
        self.assertEqual(calls,[])

    def test_fresh_baseline_drift_blocks_first_write(self):
        self.prepare(); calls=[]
        def remote(host, code, **kwargs):
            calls.append((host,code)); return {'unexpected':'drift'}
        with self.assertRaises(ValueError):
            executor().run(self.output,'runtime','test-20261012-123456',execute=True,review_path=self.review,runner=remote)
        self.assertEqual(len(calls),1)
        self.assertIn('checked_at_utc',calls[0][1])
        self.assertFalse((self.output/'execution/test-20261012-123456/runtime.json').exists())

    def test_live_cdn_pending_blocks_alias_before_hk_mutation(self):
        self.prepare(); execute=executor(); calls=[]
        execution=self.output/'execution/test-20261012-123456'; execution.mkdir(parents=True)
        binding={'freeze_sha256':self.pkg.digest(self.output/'freeze-manifest.json'),'status':'PASS'}
        for mode in ('runtime','upload','assemble','hk-install','cdn-install'):
            self.pkg.write_json(execution/(mode+'.json'),binding)
        def remote(host,code,**kwargs):
            calls.append(host); return {'cloudfront':'complete','status':'InProgress'}
        with self.assertRaises(ValueError):
            execute.run(self.output,'hk-switch','test-20261012-123456',execute=True,review_path=self.review,runner=remote)
        self.assertEqual(calls,['sg'])

    def test_uncertain_mutation_is_recorded_and_cannot_be_replayed(self):
        self.prepare(); execute=executor(); calls=[]
        execution=self.output/'execution/test-20261012-123456'; execution.mkdir(parents=True)
        self.pkg.write_json(execution/'runtime.json',{'freeze_sha256':self.pkg.digest(self.output/'freeze-manifest.json'),'status':'PASS'})
        def remote(host,code,**kwargs):
            calls.append(host); raise TimeoutError('synthetic interrupted stream')
        with self.assertRaises(TimeoutError):
            execute.run(self.output,'upload','test-20261012-123456',execute=True,review_path=self.review,runner=remote)
        self.assertTrue((execution/'outcome-unknown.json').is_file())
        count=len(calls)
        with self.assertRaises(ValueError):
            execute.run(self.output,'upload','test-20261012-123456',execute=True,review_path=self.review,runner=remote)
        self.assertEqual(len(calls),count)

    def test_real_local_stream_receiver_and_archive_extraction(self):
        self.prepare(); execute=executor(); paths=execute.stages('test-20261012-123456')
        sandbox=self.root/'remote-sandbox'; sandbox.mkdir()
        def remote(host,code,*,stream_path=None,timeout=600):
            if 'checked_at_utc' in code:
                result=self.pkg.read_json(self.output/'runtime'/(host+'-live-snapshot.json'))
                if host=='hk': result['files']=self.pkg.read_json(self.output/'runtime/static-baseline.json')['files']
                return result
            # Actual receiver and extraction Python, on private local files. No
            # network, service, cloud or production payload is executed here.
            code=code.replace(paths[host],(sandbox/host).as_posix())
            with open(stream_path,'rb') if stream_path else open(__file__,'rb') as stream:
                result=subprocess.run([sys.executable,'-c',code],stdin=stream,capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            return json.loads(result.stdout)
        result=execute.run(self.output,'runtime','test-20261012-123456',execute=True,review_path=self.review,runner=remote)
        self.assertEqual(result['status'],'PASS')
        for host in ('hk','sg'):
            for name,sha in self.freeze['runtime_files'].items():
                self.assertEqual(self.pkg.digest(sandbox/host/name),sha)
        with self.assertRaises(ValueError):
            execute.run(self.output,'runtime','test-20261012-123456',execute=True,review_path=self.review,runner=remote)

    def test_unknown_publication_allows_readonly_inspect_without_publish_receipt(self):
        self.prepare(); execute=executor(); calls=[]
        execution=self.output/'execution/test-20261012-123456'; execution.mkdir(parents=True)
        self.pkg.write_json(execution/'runtime.json',{'freeze_sha256':self.pkg.digest(self.output/'freeze-manifest.json'),'status':'PASS'})
        self.pkg.write_json(execution/'outcome-unknown.json',{'operation':'publish'})
        def remote(host,code,**kwargs): calls.append(host); return {'settings':'synthetic partial state'}
        result=execute.run(self.output,'inspect','test-20261012-123456',execute=True,review_path=self.review,runner=remote)
        self.assertEqual(result['status'],'PASS'); self.assertEqual(calls,['hk'])
        self.assertTrue((execution/'outcome-unknown.json').exists())

    def test_guarded_remote_programs_compile_and_verify_before_import(self):
        self.prepare(); execute=executor()
        code=execute.guarded_command('/private/stage',self.freeze,['python3','/private/stage/release_2216.py','check'])
        compile(code,'guarded runtime','exec')
        self.assertLess(code.index('remote runtime drift'),code.index('subprocess.run'))
        self.assertIn('unfrozen bytecode',code)

    def test_changed_review_evidence_and_operation_id_refused_before_transport(self):
        self.prepare(); calls=[]
        (self.root/'review.md').write_text('drift',encoding='utf-8')
        with self.assertRaises(ValueError):
            executor().run(self.output,'runtime','test-20261012-123456',execute=True,review_path=self.review,runner=calls.append)
        with self.assertRaises(ValueError):
            executor().run(self.output,'runtime','../escape',execute=True,review_path=self.review,runner=calls.append)
        self.assertEqual(calls,[])


if __name__ == '__main__': unittest.main()
